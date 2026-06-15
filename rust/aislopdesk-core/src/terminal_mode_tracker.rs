//! Incremental host→client OUTPUT-stream sniffer that tracks the terminal mode
//! ([`TerminalMode::ShellPrompt`] vs [`TerminalMode::AltScreen`]) and emits OSC 133
//! command-boundary events.
//!
//! The canonical `TerminalModeTracker` logic and single source of truth; the native Swift
//! shell's `TerminalModeTracker` (`Sources/AislopdeskClaudeCode/TerminalModeTracker.swift`)
//! tracks this (golden parity). A future Android client that shows an input affordance over
//! the remote terminal reuses this to switch input behaviour by mode, computed from the same
//! post-transport, pre-renderer byte stream.
//!
//! ## Why a hand-rolled mini-parser (not a full VT parser)
//! libghostty's surface is opaque — there is no parsed grid or alt-screen action to read. So
//! this sniffs the byte stream for the handful of markers it needs (DECSET/DECRST 1049/47/1047
//! plus OSC 133 A/B/C/D) and treats everything else as opaque content; it deliberately does NOT
//! model the screen.
//!
//! ## Streaming-safe
//! A true byte-at-a-time state machine: state persists across chunks, so any split (mid-`ESC`,
//! mid-CSI, mid-OSC, mid-terminator) yields identical events to the whole stream. The CSI /
//! OSC payload buffers are capped ([`TerminalModeTracker::CSI_CAP`] / [`Self::OSC_CAP`]); an
//! overlong sequence is abandoned and the parser resyncs, so a hostile stream can never wedge
//! it or make it buffer unboundedly.
//!
//! ## Documented differences from the Swift shell (output-identical)
//! - **No `memchr` fast path.** The Swift shell skims the `.ground` / `.stringConsume` states
//!   with `memchr` to route only `ESC` / `BEL` through `step()` — a pure performance
//!   optimization that *never replaces a transition* (its `TerminalModeTrackerFastPathTests`
//!   chunking-invariance + differential oracle pin it to the per-byte path). This core runs
//!   the per-byte path directly: byte- and behaviour-identical, just not micro-optimized.
//! - **`String::from_utf8_lossy`.** The Swift shell decodes the CSI params / OSC payload with
//!   the lossy `String(decoding:as: UTF8.self)` (invalid bytes → U+FFFD), matched here so a
//!   non-UTF-8 marker body classifies identically.

/// Which screen the host's terminal is presenting, derived from the output byte stream. The
/// Swift shell's `TerminalMode` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalMode {
    /// Main screen — a shell prompt / inline content (external input box runs in shell mode).
    ShellPrompt,
    /// Alternate screen — a fullscreen TUI (vim, btop, …) (external input box runs in TUI mode).
    AltScreen,
}

/// An event emitted by [`TerminalModeTracker`] as it parses the output stream. The Swift
/// shell's `TerminalModeEvent` mirrors this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalModeEvent {
    /// The terminal entered the alternate screen (`ESC[?1049h`, or legacy `?47h` / `?1047h`).
    EnteredAltScreen,
    /// The terminal left the alternate screen (`ESC[?1049l`, or legacy `?47l` / `?1047l`).
    ExitedAltScreen,
    /// OSC 133;A — prompt start (shell integration).
    PromptStart,
    /// OSC 133;B — command start / prompt end.
    CommandStart,
    /// OSC 133;C — command output begins.
    CommandStarted,
    /// OSC 133;D[;exit] — command finished, with an optional decoded exit code.
    CommandFinished {
        /// The decoded exit code, or `None` when absent / unparsable.
        exit_code: Option<i64>,
    },
}

/// Parser state for the byte-at-a-time machine. The Swift shell's `State` enum mirrors this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Outside any escape sequence (passing through opaque content).
    Ground,
    /// Saw `ESC` (`0x1B`); waiting for the next byte to classify.
    Escape,
    /// Inside a CSI sequence (`ESC[`). Collecting param/intermediate bytes until a final byte
    /// in `0x40..=0x7E`.
    Csi,
    /// Inside an OSC sequence (`ESC]`). Collecting the payload until `BEL` or `ST` (`ESC\`).
    Osc,
    /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the `\` that
    /// completes an `ST` terminator, or a new sequence start.
    OscEscape,
    /// Inside a DCS/SOS/PM/APC string sequence: swallow the body to its ST/BEL terminator,
    /// tracking nothing (an embedded `ESC[?1049h` / `ESC]133;…` must NOT flip the mode).
    StringConsume,
    /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC\`).
    StringConsumeEscape,
}

/// The host→client output-stream terminal-mode tracker. See the module docs for the grammar —
/// the canonical `TerminalModeTracker` (the Swift shell mirrors it).
///
/// Drive it by feeding chunks of the output byte stream to [`consume`](Self::consume); state
/// persists across calls so chunk boundaries are irrelevant to the emitted events.
#[derive(Debug, Clone)]
pub struct TerminalModeTracker {
    mode: TerminalMode,
    state: State,
    /// Accumulated CSI param/intermediate bytes (without the leading `ESC[`). Bounded by
    /// [`Self::CSI_CAP`].
    csi_buffer: Vec<u8>,
    /// Accumulated OSC payload bytes (without the leading `ESC]` or terminator). Bounded by
    /// [`Self::OSC_CAP`].
    osc_buffer: Vec<u8>,
}

impl Default for TerminalModeTracker {
    /// A fresh tracker in [`TerminalMode::ShellPrompt`], ground state, empty buffers.
    /// Equivalent to [`TerminalModeTracker::new`].
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalModeTracker {
    /// Hard cap on the buffered CSI run — the markers tracked are tiny; anything longer is not
    /// ours and is abandoned. The Swift shell's `csiCap` mirrors this.
    const CSI_CAP: usize = 64;
    /// Hard cap on the buffered OSC payload (only the short `133;…` is of interest). The Swift
    /// shell's `oscCap` mirrors this.
    const OSC_CAP: usize = 256;

    const ESC: u8 = 0x1B;
    const BEL: u8 = 0x07;
    const LEFT_BRACKET: u8 = 0x5B; // '['
    const RIGHT_BRACKET: u8 = 0x5D; // ']'
    const BACKSLASH: u8 = 0x5C; // '\'
    const QUESTION: u8 = 0x3F; // '?'
    const SET_FINAL: u8 = 0x68; // 'h'
    const RESET_FINAL: u8 = 0x6C; // 'l'
                                  // String-sequence introducers: DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`.
    const DCS: u8 = 0x50; // 'P'
    const SOS: u8 = 0x58; // 'X'
    const PM: u8 = 0x5E; // '^'
    const APC: u8 = 0x5F; // '_'

    /// Builds a fresh tracker in [`TerminalMode::ShellPrompt`], ground state, empty buffers.
    /// The Swift shell's `TerminalModeTracker()` matches this.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            mode: TerminalMode::ShellPrompt,
            state: State::Ground,
            csi_buffer: Vec::new(),
            osc_buffer: Vec::new(),
        }
    }

    /// The current terminal mode.
    #[must_use]
    pub const fn mode(&self) -> TerminalMode {
        self.mode
    }

    /// Returns the tracker to its initial state ([`TerminalMode::ShellPrompt`], ground, empty
    /// buffers), emitting no events. Call at a SESSION boundary: a reconnect always brings a
    /// fresh host shell, so a mode (or partial-sequence parse state) carried over from the dead
    /// session is a lie. The Swift shell's `reset()` matches this.
    pub fn reset(&mut self) {
        self.state = State::Ground;
        self.mode = TerminalMode::ShellPrompt;
        self.csi_buffer = Vec::new();
        self.osc_buffer = Vec::new();
    }

    /// Feeds a chunk of output bytes and returns the marker events produced by this chunk (in
    /// order). Safe to call with chunks split at any byte boundary. The Swift shell's
    /// `@discardableResult consume(_:)` mirrors this (the result may be ignored).
    pub fn consume(&mut self, bytes: &[u8]) -> Vec<TerminalModeEvent> {
        let mut events = Vec::new();
        for &byte in bytes {
            self.step(byte, &mut events);
        }
        events
    }

    /// One byte through the state machine — the canonical transition table. The Swift shell's
    /// `step(_:into:)` matches this exactly.
    fn step(&mut self, byte: u8, events: &mut Vec<TerminalModeEvent>) {
        match self.state {
            State::Ground => {
                if byte == Self::ESC {
                    self.state = State::Escape;
                }
                // else: opaque content byte — ignore for mode tracking.
            }

            State::Escape => match byte {
                Self::LEFT_BRACKET => {
                    self.state = State::Csi;
                    self.csi_buffer.clear();
                }
                Self::RIGHT_BRACKET => {
                    self.state = State::Osc;
                    self.osc_buffer.clear();
                }
                // A DCS/SOS/PM/APC string body is opaque to a conformant terminal — swallow it
                // to ST/BEL so an embedded `ESC[?1049h` / `ESC]133;…` can't flip the mode.
                Self::DCS | Self::SOS | Self::PM | Self::APC => self.state = State::StringConsume,
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                Self::ESC => self.state = State::Escape,
                // Some other 2-byte / nF escape (e.g. `ESC c`). Not a tracked marker → ground.
                _ => self.state = State::Ground,
            },

            State::Csi => {
                self.csi_buffer.push(byte);
                // Final byte of a CSI is in 0x40..=0x7E; everything before is a param
                // (0x30..=0x3F) or intermediate (0x20..=0x2F) byte.
                if (0x40..=0x7E).contains(&byte) {
                    self.handle_csi(events);
                    self.state = State::Ground;
                } else if self.csi_buffer.len() > Self::CSI_CAP {
                    // Overlong — not one of ours; abandon and resync at ground.
                    self.state = State::Ground;
                }
            }

            State::Osc => match byte {
                Self::BEL => {
                    self.handle_osc(events);
                    self.state = State::Ground;
                }
                // Possible start of an `ST` terminator (`ESC\`).
                Self::ESC => self.state = State::OscEscape,
                _ => {
                    self.osc_buffer.push(byte);
                    if self.osc_buffer.len() > Self::OSC_CAP {
                        self.state = State::Ground;
                    }
                }
            },

            State::OscEscape => {
                // Either way the OSC ends here (`ESC\` = ST, or a stray ESC terminates it).
                self.handle_osc(events);
                if byte == Self::BACKSLASH {
                    self.state = State::Ground; // clean ST terminator.
                } else {
                    // The stray `ESC` may itself introduce a NEW escape sequence — re-enter
                    // `Escape` (NOT `Ground`) and re-classify this byte as that sequence's
                    // introducer (dropping to ground would orphan the ESC and lose the next
                    // marker).
                    self.state = State::Escape;
                    self.step(byte, events);
                }
            }

            State::StringConsume => match byte {
                Self::BEL => self.state = State::Ground,
                Self::ESC => self.state = State::StringConsumeEscape,
                _ => {} // opaque string-body byte.
            },

            State::StringConsumeEscape => match byte {
                Self::BACKSLASH => self.state = State::Ground, // `ESC \` = ST terminator.
                Self::ESC => self.state = State::StringConsumeEscape, // another ESC — keep waiting.
                _ => self.state = State::StringConsume, // a lone ESC inside the body — swallow + continue.
            },
        }
    }

    /// CSI dispatch — DECSET/DECRST private modes 1049 / 47 / 1047 (`?<params>h` / `?<params>l`).
    /// The Swift shell's `handleCSI(_:into:)` mirrors this. The buffer INCLUDES the final byte.
    fn handle_csi(&mut self, events: &mut Vec<TerminalModeEvent>) {
        let buffer = std::mem::take(&mut self.csi_buffer);
        // We only care about `?<n>h` / `?<n>l` (DEC private set/reset).
        let Some(&final_byte) = buffer.last() else {
            return;
        };
        if final_byte != Self::SET_FINAL && final_byte != Self::RESET_FINAL {
            return;
        }
        if buffer.first() != Some(&Self::QUESTION) {
            return;
        }
        // Params between '?' and the final byte, split on ';' (empty subsequences omitted).
        let param_bytes = &buffer[1..buffer.len() - 1];
        // Lossy decode (matches the Swift `String(decoding:as: UTF8.self)`): the buffer can hold
        // arbitrary bytes and the dropped/replaced bytes must agree with the shell.
        let params_str = String::from_utf8_lossy(param_bytes);
        let is_set = final_byte == Self::SET_FINAL;
        for field in params_str.split(';') {
            // `split` keeps empty fields; Swift's `omittingEmptySubsequences: true` + `compactMap`
            // drops them — an empty field parses to `None` here, which the loop skips, so the two
            // agree without an explicit empty filter.
            let Ok(param) = field.parse::<i64>() else {
                continue;
            };
            if param == 1049 || param == 47 || param == 1047 {
                if is_set {
                    if self.mode != TerminalMode::AltScreen {
                        self.mode = TerminalMode::AltScreen;
                        events.push(TerminalModeEvent::EnteredAltScreen);
                    }
                } else if self.mode != TerminalMode::ShellPrompt {
                    self.mode = TerminalMode::ShellPrompt;
                    events.push(TerminalModeEvent::ExitedAltScreen);
                }
                // One alt-screen marker per CSI is enough; the modes are equivalent.
                return;
            }
        }
    }

    /// OSC dispatch — OSC 133 prompt marks (`133;A` / `B` / `C` / `D[;exit]`). The Swift shell's
    /// `handleOSC(_:into:)` mirrors this.
    fn handle_osc(&mut self, events: &mut Vec<TerminalModeEvent>) {
        let buffer = std::mem::take(&mut self.osc_buffer);
        let payload = String::from_utf8_lossy(&buffer);
        // Full split on ';' with EMPTY fields KEPT (Swift `omittingEmptySubsequences: false`).
        let fields: Vec<&str> = payload.split(';').collect();
        if fields.len() < 2 || fields[0] != "133" {
            return;
        }
        match fields[1] {
            "A" => events.push(TerminalModeEvent::PromptStart),
            "B" => events.push(TerminalModeEvent::CommandStart),
            "C" => events.push(TerminalModeEvent::CommandStarted),
            "D" => {
                // `;D` or `;D;<exit>[;...]`. The exit code, if present, is field[2].
                let exit_code = if fields.len() >= 3 {
                    let field = fields[2];
                    // Swift: `fields[2].split(separator: "=").first` (empty omitted) ?? whole field.
                    let raw = field.split('=').find(|s| !s.is_empty()).unwrap_or(field);
                    raw.parse::<i64>().ok()
                } else {
                    None
                };
                events.push(TerminalModeEvent::CommandFinished { exit_code });
            }
            _ => {} // Unknown OSC 133 subcommand — ignore cleanly.
        }
    }
}

#[cfg(test)]
#[allow(clippy::too_many_lines)]
mod tests {
    use super::*;

    /// Feeds `bytes` to a fresh tracker in one shot.
    fn consume_whole(bytes: &[u8]) -> (Vec<TerminalModeEvent>, TerminalMode) {
        let mut t = TerminalModeTracker::new();
        let events = t.consume(bytes);
        (events, t.mode())
    }

    /// Feeds `bytes` to a fresh tracker split into chunks of `size`.
    fn consume_chunked(bytes: &[u8], size: usize) -> Vec<TerminalModeEvent> {
        let mut t = TerminalModeTracker::new();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            let end = (i + size).min(bytes.len());
            out.extend(t.consume(&bytes[i..end]));
            i = end;
        }
        out
    }

    use TerminalModeEvent::{
        CommandFinished, CommandStart, CommandStarted, EnteredAltScreen, ExitedAltScreen,
        PromptStart,
    };

    #[test]
    fn alt_screen_enter_exit_1049() {
        let (events, mode) = consume_whole(b"\x1b[?1049h\x1b[?1049l");
        assert_eq!(events, vec![EnteredAltScreen, ExitedAltScreen]);
        assert_eq!(mode, TerminalMode::ShellPrompt);
    }

    #[test]
    fn enter_latches_alt_screen_mode() {
        let (events, mode) = consume_whole(b"\x1b[?1049h");
        assert_eq!(events, vec![EnteredAltScreen]);
        assert_eq!(mode, TerminalMode::AltScreen);
    }

    #[test]
    fn legacy_47_and_1047_modes() {
        assert_eq!(consume_whole(b"\x1b[?47h").0, vec![EnteredAltScreen]);
        assert_eq!(consume_whole(b"\x1b[?1047h").0, vec![EnteredAltScreen]);
        let (events, mode) = consume_whole(b"\x1b[?47h\x1b[?1047l");
        assert_eq!(events, vec![EnteredAltScreen, ExitedAltScreen]);
        assert_eq!(mode, TerminalMode::ShellPrompt);
    }

    #[test]
    fn repeated_enter_does_not_double_fire() {
        let (events, mode) = consume_whole(b"\x1b[?1049h\x1b[?1049h");
        assert_eq!(events, vec![EnteredAltScreen]);
        assert_eq!(mode, TerminalMode::AltScreen);
    }

    #[test]
    fn exit_without_prior_enter_is_noop() {
        let (events, mode) = consume_whole(b"\x1b[?1049l");
        assert_eq!(events, vec![]);
        assert_eq!(mode, TerminalMode::ShellPrompt);
    }

    #[test]
    fn multi_param_first_match_applies() {
        // `?25;1049h` — 25 ignored, 1049 matched.
        let (events, mode) = consume_whole(b"\x1b[?25;1049h");
        assert_eq!(events, vec![EnteredAltScreen]);
        assert_eq!(mode, TerminalMode::AltScreen);
    }

    #[test]
    fn csi_without_question_mark_ignored() {
        // `[1049h` (no '?') is not a DEC private mode.
        assert_eq!(consume_whole(b"\x1b[1049h").0, vec![]);
    }

    #[test]
    fn unknown_private_mode_ignored() {
        assert_eq!(consume_whole(b"\x1b[?25h").0, vec![]);
    }

    #[test]
    fn osc133_full_cycle() {
        let stream = b"\x1b]133;A\x07prompt$ \x1b]133;B\x07ls\n\x1b]133;C\x07out\n\x1b]133;D;0\x07";
        let (events, _) = consume_whole(stream);
        assert_eq!(
            events,
            vec![
                PromptStart,
                CommandStart,
                CommandStarted,
                CommandFinished { exit_code: Some(0) },
            ]
        );
    }

    #[test]
    fn osc133_st_terminator() {
        assert_eq!(consume_whole(b"\x1b]133;A\x1b\\").0, vec![PromptStart]);
    }

    #[test]
    fn osc133_exit_codes() {
        assert_eq!(
            consume_whole(b"\x1b]133;D;130\x07").0,
            vec![CommandFinished {
                exit_code: Some(130)
            }]
        );
        assert_eq!(
            consume_whole(b"\x1b]133;D\x07").0,
            vec![CommandFinished { exit_code: None }]
        );
        // Extra ;k=v fields tolerated; field[2] is the exit code.
        assert_eq!(
            consume_whole(b"\x1b]133;D;0;aid=5\x07").0,
            vec![CommandFinished { exit_code: Some(0) }]
        );
        // `=5` → first non-empty `=`-segment is "5".
        assert_eq!(
            consume_whole(b"\x1b]133;D;=5\x07").0,
            vec![CommandFinished { exit_code: Some(5) }]
        );
        // Lone `=` → no non-empty segment, whole field "=" not an Int → None.
        assert_eq!(
            consume_whole(b"\x1b]133;D;=\x07").0,
            vec![CommandFinished { exit_code: None }]
        );
        // Negative + unparsable.
        assert_eq!(
            consume_whole(b"\x1b]133;D;-1\x07").0,
            vec![CommandFinished {
                exit_code: Some(-1)
            }]
        );
        assert_eq!(
            consume_whole(b"\x1b]133;D;abc\x07").0,
            vec![CommandFinished { exit_code: None }]
        );
    }

    #[test]
    fn osc_non_133_ignored() {
        assert_eq!(consume_whole(b"\x1b]0;a window title\x07").0, vec![]);
        assert_eq!(consume_whole(b"\x1b]133\x07").0, vec![]); // bare 133, no ';'
        assert_eq!(consume_whole(b"\x1b]133;Z\x07").0, vec![]); // unknown subcommand
    }

    #[test]
    fn split_boundary_equivalence() {
        // Every chunk size yields identical events to the whole stream.
        let stream = b"pre\x1b]133;A\x07$ \x1b[?1049hTUI\x1b[?1049l\x1b]133;D;3\x07post".to_vec();
        let whole = consume_whole(&stream).0;
        assert_eq!(
            whole,
            vec![
                PromptStart,
                EnteredAltScreen,
                ExitedAltScreen,
                CommandFinished { exit_code: Some(3) },
            ]
        );
        for size in 1..=stream.len() {
            assert_eq!(consume_chunked(&stream, size), whole, "chunk size {size}");
        }
    }

    #[test]
    fn unterminated_osc_then_alt_screen_not_lost() {
        // `ESC]133` (no terminator) abutting `ESC[?1049h`: the stray ESC ends the OSC and
        // re-enters escape so the alt-screen CSI still fires (oscEscape re-entry).
        let (events, mode) = consume_whole(b"\x1b]133\x1b[?1049h");
        assert_eq!(events, vec![EnteredAltScreen]);
        assert_eq!(mode, TerminalMode::AltScreen);
    }

    #[test]
    fn string_sequences_swallow_embedded_markers() {
        // DCS body with an embedded alt-screen CSI → swallowed (mode unchanged).
        let (events, mode) = consume_whole(b"\x1bP\x1b[?1049h\x1b\\");
        assert_eq!(events, vec![]);
        assert_eq!(mode, TerminalMode::ShellPrompt);
        // APC body with an embedded OSC 133 → swallowed; a REAL marker after still fires.
        let after = consume_whole(b"\x1b_\x1b]133;A\x07\x1b\\\x1b]133;A\x07").0;
        assert_eq!(after, vec![PromptStart]);
        // PM swallowed by BEL, then a real alt-screen enter.
        let pm = consume_whole(b"\x1b^junk\x07\x1b[?1049h").0;
        assert_eq!(pm, vec![EnteredAltScreen]);
    }

    #[test]
    fn double_esc_reclassifies() {
        // `ESC ESC [ ?1049h` — the second ESC re-classifies; the CSI still parses.
        assert_eq!(consume_whole(b"\x1b\x1b[?1049h").0, vec![EnteredAltScreen]);
    }

    #[test]
    fn unknown_two_byte_escape_ignored_then_marker() {
        // `ESC c` (reset) is ignored; the following alt-screen enter still fires.
        assert_eq!(consume_whole(b"\x1bc\x1b[?1049h").0, vec![EnteredAltScreen]);
    }

    #[test]
    fn overlong_csi_abandoned_then_resync() {
        let mut bytes = b"\x1b[?".to_vec();
        bytes.extend_from_slice(&[b'1'; 100]); // > CSI_CAP, no final byte yet
        bytes.extend_from_slice(b"\x1b[?1049h");
        assert_eq!(consume_whole(&bytes).0, vec![EnteredAltScreen]);
    }

    #[test]
    fn overlong_osc_abandoned_then_resync() {
        let mut bytes = b"\x1b]".to_vec();
        bytes.extend_from_slice(&[b'x'; 500]); // > OSC_CAP
        bytes.extend_from_slice(b"\x1b]133;A\x07");
        assert_eq!(consume_whole(&bytes).0, vec![PromptStart]);
    }

    #[test]
    fn content_and_invalid_utf8_pass_through() {
        let mut bytes = "café 🚀\n".as_bytes().to_vec();
        bytes.extend_from_slice(&[0xFF, 0x80, 0xC0]); // raw high-bit content
        bytes.extend_from_slice(b"\x1b[?1049h");
        let (events, mode) = consume_whole(&bytes);
        assert_eq!(events, vec![EnteredAltScreen]);
        assert_eq!(mode, TerminalMode::AltScreen);
    }

    #[test]
    fn reset_clears_mode_and_parse_state() {
        let mut t = TerminalModeTracker::new();
        let _ = t.consume(b"\x1b[?1049h\x1b]133;A"); // alt-screen latched + mid-OSC
        assert_eq!(t.mode(), TerminalMode::AltScreen);
        t.reset();
        assert_eq!(t.mode(), TerminalMode::ShellPrompt);
        // The mid-OSC parse state is gone — a fresh stream parses cleanly.
        assert_eq!(t.consume(b"\x1b]133;A\x07"), vec![PromptStart]);
    }

    #[test]
    fn default_equals_new() {
        let stream = b"\x1b[?1049h";
        assert_eq!(
            TerminalModeTracker::default().consume(stream),
            TerminalModeTracker::new().consume(stream)
        );
    }

    #[test]
    fn empty_chunk_is_noop_and_preserves_state() {
        let mut t = TerminalModeTracker::new();
        assert_eq!(t.consume(b"\x1b[?10"), vec![]); // partial CSI
        assert_eq!(t.consume(b""), vec![]); // empty chunk
        assert_eq!(t.consume(b"49h"), vec![EnteredAltScreen]); // completes across the empty chunk
    }
}
