//! The host-side outbound-PTY output sniffer — a byte-at-a-time terminal-output state machine.
//!
//! The canonical `HostOutputSniffer` logic; the native Swift shell keeps a copy
//! (`Sources/AislopdeskHost/HostOutputSniffer.swift`) that tracks this (golden parity).
//!
//! It scans the OUTBOUND PTY byte stream (host → client) for the three inline host→client
//! CONTROL messages and emits them as [`crate::terminal::WireMessage`] values, in byte
//! order, without ever consuming/altering the stream (the caller forwards the original
//! bytes UNCHANGED):
//!
//! - [`WireMessage::Title`] — OSC 0 / OSC 2 (`ESC ] 0;… <term>` / `ESC ] 2;… <term>`).
//! - [`WireMessage::Bell`] — a standalone ground-state `BEL` (never an OSC/string terminator).
//! - [`WireMessage::CommandStatus`] — OSC 133 `C` (running) / `D[;exit]` (idle, with the
//!   host-measured C→D duration in milliseconds).
//! - [`WireMessage::Notification`] — OSC 9 (iTerm2/ConEmu) and OSC 777 (urxvt/ConEmu `notify`).
//!
//! ## Provenance
//! [`HostOutputSniffer::step`] is the canonical 8-state transition table
//! (`.ground` / `.escape` / `.osc` / `.oscEscape` / `.oscDiscard` /
//! `.oscDiscardEscape` / `.stringConsume` / `.stringConsumeEscape`), including the
//! DCS/SOS/PM/APC string-swallowing anti-spoof, the cap-bounded OSC buffer, the stray-ESC
//! re-entry fix, and [`HostOutputSniffer::finish_osc`]'s Ps-prefix dispatch with the
//! 256-byte command cap. The Swift shell's `HostOutputSniffer` implements the same table.
//!
//! ## Streaming-safe
//! A true byte-at-a-time machine: state persists across chunks, so any split (mid-ESC,
//! mid-OSC, mid-terminator) yields identical messages to the whole stream. The OSC payload
//! buffer is capped ([`HostOutputSniffer::OSC_CAP`]); over-cap / string-sequence bodies are
//! swallowed without buffering, so a hostile stream can never wedge the sniffer or make it
//! buffer unboundedly.
//!
//! ## Documented differences from the Swift shell (output-identical)
//! - **No `NSLock`.** The Swift shell's type is `@unchecked Sendable` and guards its mutable
//!   state with a lock so it can be captured in a `@Sendable` closure; in practice `observe` is
//!   only ever called from the single serial `PTYReadLoop` queue. This core is `&mut self`
//!   (single-owner) and drops the lock entirely.
//! - **No `memchr` fast path.** The Swift shell skims `.ground` / `.oscDiscard` /
//!   `.stringConsume` with `memchr` to route only `ESC`/`BEL` through `step()` — a pure
//!   performance optimization that *never replaces a transition* (Swift's permanent
//!   `testChunkingInvarianceOracle` pins it to the per-byte path). This core runs the
//!   per-byte path directly: byte- and behaviour-identical, just not micro-optimized.
//! - **Clock as a parameter, not an injected closure.** The Swift shell injects a `() -> Date`
//!   clock and measures the OSC 133 C→D duration from it. This core takes the time as
//!   `now_ms: u64` (the caller's monotonic milliseconds) on each [`HostOutputSniffer::observe`]
//!   call: it captures the start ms when the `C` marker is processed and computes
//!   `duration = now_ms - start` (saturating) at `D`, clamped to `u32`; the Swift shell's
//!   `durationMS` does the same. See the crate's golden-vector dumper notes for the
//!   scripted-clock mapping that makes the two agree.

mod machine;
#[cfg(test)]
#[allow(clippy::too_many_lines)]
mod tests;

/// Parser state for the byte-at-a-time machine. The Swift shell's `State` enum mirrors this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Outside any escape sequence (opaque content). A `BEL` here is a real terminal bell.
    Ground,
    /// Saw `ESC` (`0x1B`); waiting for the next byte to classify (`]` → OSC, etc.).
    Escape,
    /// Inside an OSC sequence (`ESC ]`). Collecting payload until `BEL` or `ST`.
    Osc,
    /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the `\` that
    /// completes an `ST` terminator (`ESC \`), or a new sequence start.
    OscEscape,
    /// An over-cap OSC is being DISCARDED: still INSIDE the OSC (so its terminator must be
    /// consumed here, not re-parsed as ground), but no longer buffering. Bounded O(n).
    OscDiscard,
    /// Inside a discarded OSC and the previous byte was `ESC` (possible `ST`).
    OscDiscardEscape,
    /// Inside a DCS/SOS/PM/APC string sequence: swallow the body to its ST/BEL terminator,
    /// emitting NOTHING. UNLIKE an OSC, an embedded ESC that is NOT `\` is part of the opaque
    /// string (it does NOT start a new sequence), so this never re-classifies.
    StringConsume,
    /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC \`).
    StringConsumeEscape,
}

/// The FUSED host-side outbound-PTY output sniffer. See the module docs for the full
/// grammar — the canonical `HostOutputSniffer` (the Swift shell mirrors it).
///
/// Drive it by feeding chunks of the outbound byte stream to [`observe`](Self::observe);
/// state persists across calls so chunk boundaries are irrelevant to the emitted messages.
#[derive(Debug, Clone)]
pub struct HostOutputSniffer {
    state: State,
    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator), e.g.
    /// `0;my title` or `133;D;0`. Bounded by [`Self::OSC_CAP`].
    osc_buffer: Vec<u8>,
    /// The last title emitted, for trivial coalescing (don't spam identical titles).
    last_title: Option<String>,
    /// The `now_ms` captured when the foreground command started (set on `133;C`, cleared
    /// on `133;D`); `None` when idle. The Swift shell's `runningSince: Date?` mirrors this.
    start_ms: Option<u64>,
}

impl Default for HostOutputSniffer {
    /// A fresh sniffer in the ground state, no command running, no last title. Equivalent to
    /// [`HostOutputSniffer::new`].
    fn default() -> Self {
        Self::new()
    }
}

impl HostOutputSniffer {
    /// Hard cap on the buffered OSC payload (the title sniffer's cap). A real title is tiny;
    /// anything longer is abandoned and the parser resyncs. The Swift shell's `oscCap` mirrors this.
    const OSC_CAP: usize = 4096;

    /// EXACT-PARITY guard for the 133 path: the old command sniffer capped ITS buffer at
    /// 256, so a `133;…` payload of 257..=4096 bytes never reached its `finishOSC`. The fused
    /// machine buffers up to 4096, so [`finish_osc`](Self::finish_osc) re-imposes 256 on the
    /// 133 branch. The Swift shell's `cmdOscCap` mirrors this.
    const CMD_OSC_CAP: usize = 256;

    /// Payload cap for the OSC 9 / OSC 777 notification path: a real notification line is
    /// short; a multi-kilobyte one is not worth surfacing (and bounds a hostile stream).
    /// The Swift shell's `notifyOscCap` mirrors this.
    const NOTIFY_OSC_CAP: usize = 1024;

    const ESC: u8 = 0x1B;
    const BEL: u8 = 0x07;
    const RIGHT_BRACKET: u8 = 0x5D; // ']'
    const BACKSLASH: u8 = 0x5C; // '\'
    const SEMICOLON: u8 = 0x3B; // ';'
    // String-sequence introducers: DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`.
    const DCS: u8 = 0x50; // 'P'
    const SOS: u8 = 0x58; // 'X'
    const PM: u8 = 0x5E; // '^'
    const APC: u8 = 0x5F; // '_'

    /// Builds a fresh sniffer in the ground state. The Swift shell's `HostOutputSniffer()` matches this.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: State::Ground,
            osc_buffer: Vec::new(),
            last_title: None,
            start_ms: None,
        }
    }
}
