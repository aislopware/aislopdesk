//! The byte-at-a-time transition table and OSC dispatch for [`HostOutputSniffer`].
//!
//! Holds `observe` (the chunk entry point), `step` (the canonical 8-state machine), and
//! `finish_osc` (the Ps-prefix dispatch) plus the small UTF-8/exit/duration helpers.

use super::{HostOutputSniffer, State};
use crate::terminal::{CommandStatus, WireMessage};

impl HostOutputSniffer {
    /// Observes a chunk of the OUTBOUND byte stream and returns the CONTROL messages
    /// (`Title` / `Bell` / `CommandStatus` / `Notification`) detected in it, **in byte
    /// order**. Does NOT modify or consume the bytes — the caller forwards the original chunk
    /// unchanged.
    ///
    /// `now_ms` is the caller's monotonic clock in milliseconds, used to stamp the OSC 133
    /// C→D duration: the value seen when a `C` marker completes is the start, and the value
    /// seen when the matching `D` completes yields `duration = now_ms - start` (saturating,
    /// clamped to `u32`). It is otherwise ignored. The Swift shell's `@discardableResult
    /// observe(_:)` mirrors this (the result may be ignored).
    pub fn observe(&mut self, bytes: &[u8], now_ms: u64) -> Vec<WireMessage> {
        let mut messages = Vec::new();
        for &byte in bytes {
            self.step(byte, now_ms, &mut messages);
        }
        messages
    }

    /// One byte through the state machine — the canonical transition table. `now_ms` is
    /// threaded through only so [`finish_osc`](Self::finish_osc) can stamp a C/D duration.
    /// The Swift shell's `step(_:into:)` matches this exactly.
    fn step(&mut self, byte: u8, now_ms: u64, messages: &mut Vec<WireMessage>) {
        match self.state {
            State::Ground => match byte {
                Self::ESC => self.state = State::Escape,
                // A BEL in ground state is a real terminal bell (NOT an OSC terminator).
                Self::BEL => messages.push(WireMessage::Bell),
                _ => {} // opaque content byte — ignore.
            },

            State::Escape => match byte {
                Self::RIGHT_BRACKET => {
                    self.state = State::Osc;
                    self.osc_buffer.clear();
                }
                // DCS/SOS/PM/APC introduce a STRING sequence whose body a conformant terminal
                // swallows to its ST/BEL terminator WITHOUT ringing a bell or changing the
                // title — anti-spoof of an embedded BEL / `ESC]2;…` / `ESC]133;…`.
                Self::DCS | Self::SOS | Self::PM | Self::APC => self.state = State::StringConsume,
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                Self::ESC => self.state = State::Escape,
                // Some other escape (CSI `ESC[`, a 2-byte / nF escape). Not an OSC; back to
                // ground.
                _ => self.state = State::Ground,
            },

            State::Osc => match byte {
                // BEL terminates the OSC string — emit a title / status / notification if it
                // is one, and CRUCIALLY do NOT emit a Bell (this BEL is a terminator).
                Self::BEL => {
                    self.finish_osc(now_ms, messages);
                    self.state = State::Ground;
                }
                // Possible start of an `ST` terminator (`ESC \`).
                Self::ESC => self.state = State::OscEscape,
                _ => {
                    self.osc_buffer.push(byte);
                    if self.osc_buffer.len() > Self::OSC_CAP {
                        // Overlong — abandon WITHOUT emitting. Do NOT drop to ground (we are
                        // still INSIDE the OSC; its real terminator has not arrived). Switch
                        // to OscDiscard to swallow the rest, terminator included.
                        self.osc_buffer.clear();
                        self.state = State::OscDiscard;
                    }
                }
            },

            State::OscDiscard => match byte {
                Self::BEL => self.state = State::Ground,
                Self::ESC => self.state = State::OscDiscardEscape,
                _ => {} // discarded payload byte
            },

            State::OscDiscardEscape => {
                if byte == Self::BACKSLASH {
                    self.state = State::Ground; // `ESC \` = ST terminator of the discarded OSC.
                } else {
                    // The `ESC` was not an ST terminator — it may introduce a NEW sequence.
                    // Re-enter escape and re-classify this byte (no payload to finish — the
                    // OSC was discarded).
                    self.state = State::Escape;
                    self.step(byte, now_ms, messages);
                }
            }

            State::StringConsume => match byte {
                Self::BEL => self.state = State::Ground,
                Self::ESC => self.state = State::StringConsumeEscape,
                _ => {} // opaque string-body byte — swallow.
            },

            State::StringConsumeEscape => match byte {
                Self::BACKSLASH => self.state = State::Ground, // `ESC \` = ST terminator.
                Self::ESC => self.state = State::StringConsumeEscape, // another ESC — keep waiting.
                _ => self.state = State::StringConsume, // a lone ESC inside the body — swallow + continue.
            },

            State::OscEscape => {
                // Either way the OSC ends here (`ESC \` = ST, or a stray ESC terminates it).
                self.finish_osc(now_ms, messages);
                if byte == Self::BACKSLASH {
                    self.state = State::Ground; // clean ST terminator.
                } else {
                    // The `ESC` was not an ST terminator — it may itself introduce a NEW
                    // sequence, so re-enter escape (NOT ground) and re-classify this byte as
                    // that sequence's introducer.
                    self.state = State::Escape;
                    self.step(byte, now_ms, messages);
                }
            }
        }
    }

    /// Fused OSC dispatch on the Ps prefix: OSC 0/2 (title), OSC 133 C/D (command status),
    /// OSC 9 / OSC 777 (notification). Consumes the buffered payload (always cleared on exit,
    /// matching the Swift shell's `defer { oscBuffer.removeAll() }`). The Swift shell's
    /// `finishOSC(into:)` mirrors this.
    fn finish_osc(&mut self, now_ms: u64, messages: &mut Vec<WireMessage>) {
        // Take the buffer out — leaves `self.osc_buffer` empty (the Swift `defer`-clear) and
        // frees `self` for the `last_title` / `start_ms` mutations below.
        let buffer = std::mem::take(&mut self.osc_buffer);

        // Split the Ps prefix at the FIRST ';' — the payload after it may itself contain ';'.
        let Some(sep) = buffer.iter().position(|&b| b == Self::SEMICOLON) else {
            return;
        };
        let ps = Self::utf8_or_empty(&buffer[..sep]);

        match ps.as_str() {
            // Title path — OSC 0 (icon name + window title) and OSC 2 (window title only).
            // OSC 1 is icon-name-ONLY and deliberately ignored.
            "0" | "2" => {
                let title = Self::utf8_or_empty(&buffer[sep + 1..]);
                // Trivial dedup: don't spam an identical title back-to-back.
                if self.last_title.as_deref() == Some(title.as_str()) {
                    return;
                }
                self.last_title = Some(title.clone());
                messages.push(WireMessage::Title(title));
            }

            "133" => {
                // EXACT-PARITY guard: a `133;…` payload of 257..=4096 bytes reaches here in
                // the fused machine (title cap) but was discarded by the old command sniffer's
                // 256-byte cap — reproduce that so those payloads stay ignored.
                if buffer.len() > Self::CMD_OSC_CAP {
                    return;
                }
                let payload = Self::utf8_or_empty(&buffer);
                // Full split on ';' with EMPTY fields KEPT (Swift omittingEmptySubsequences:
                // false). Expected: "133;A" | "133;B" | "133;C" | "133;D" | "133;D;<exit>"
                // (+ extra ;k=v).
                let fields: Vec<&str> = payload.split(';').collect();
                if fields.len() < 2 || fields[0] != "133" {
                    return;
                }
                match fields[1] {
                    // A command began executing — mark RUNNING and start the duration clock.
                    "C" => {
                        self.start_ms = Some(now_ms);
                        messages.push(WireMessage::CommandStatus(CommandStatus::Running));
                    }
                    // A command finished. Ignore a `D` with no matching `C` (the first-prompt
                    // phantom `D;0`) — never emit a 0-duration idle for a command that never ran.
                    "D" => {
                        let Some(started) = self.start_ms else {
                            return;
                        };
                        self.start_ms = None;
                        let exit_code = Self::parse_exit(&fields);
                        let duration_ms = Self::duration_ms(started, now_ms);
                        messages.push(WireMessage::CommandStatus(CommandStatus::Idle {
                            exit_code,
                            duration_ms,
                        }));
                    }
                    _ => {} // A / B / unknown 133 subcommand — not surfaced.
                }
            }

            // OSC 9 — iTerm2/ConEmu "post a notification" (`ESC ] 9 ; <body> ST`). The whole
            // remainder after `9;` is the body; no explicit title.
            "9" => {
                if buffer.len() > Self::NOTIFY_OSC_CAP {
                    return;
                }
                let body = Self::utf8_or_empty(&buffer[sep + 1..]);
                if body.is_empty() {
                    return;
                }
                // OSC 9 is overloaded: `ESC]9;4;<state>;<pct>` is the taskbar PROGRESS-BAR
                // protocol (winget, long builds), NOT a desktop notification — skip the `9;4`
                // progress subtype so it doesn't flood the user with alerts like "4;1;50".
                if body == "4" || body.starts_with("4;") {
                    return;
                }
                messages.push(WireMessage::Notification {
                    title: String::new(),
                    body,
                });
            }

            // OSC 777 — urxvt/ConEmu `ESC ] 777 ; notify ; <title> ; <body> ST`. Only the
            // `notify` subcommand is a desktop notification.
            "777" => {
                if buffer.len() > Self::NOTIFY_OSC_CAP {
                    return;
                }
                let payload = Self::utf8_or_empty(&buffer);
                // maxSplits: 3 → at most 4 fields; the body (field 3) keeps embedded ';'.
                let fields: Vec<&str> = payload.splitn(4, ';').collect();
                if fields.len() < 3 || fields[1] != "notify" {
                    return;
                }
                let title = fields[2].to_owned();
                let body = if fields.len() >= 4 {
                    fields[3].to_owned()
                } else {
                    String::new()
                };
                if title.is_empty() && body.is_empty() {
                    return;
                }
                messages.push(WireMessage::Notification { title, body });
            }

            // Any other Ps (OSC 1 icon, OSC 8 hyperlink, OSC 52 clipboard, OSC 4 palette …)
            // is neither a title, a command mark, nor a notification — skip.
            _ => {}
        }
    }

    /// Decodes bytes as strict UTF-8, falling back to the empty string on invalid UTF-8 —
    /// the Rust analogue of Swift's `String(bytes:encoding:.utf8) ?? ""`.
    #[must_use]
    fn utf8_or_empty(bytes: &[u8]) -> String {
        std::str::from_utf8(bytes)
            .map(str::to_owned)
            .unwrap_or_default()
    }

    /// Parses the optional exit code from a `133;D[;<exit>[;k=v…]]` field list (field[2],
    /// tolerating a trailing `=value`), truncated to `i32`. Returns `None` when
    /// absent/unparsable. The Swift shell's `parseExit` mirrors this.
    #[must_use]
    fn parse_exit(fields: &[&str]) -> Option<i32> {
        if fields.len() < 3 {
            return None;
        }
        let field = fields[2];
        // Swift: `fields[2].split(separator: "=").first` (empty subsequences omitted) → the
        // FIRST non-empty `=`-segment; `?? String(fields[2])` keeps the whole field when none.
        let raw = field.split('=').find(|s| !s.is_empty()).unwrap_or(field);
        // Swift `Int(raw)` is 64-bit; `Int32(truncatingIfNeeded:)` wraps to 32 bits (`as i32`).
        raw.parse::<i64>().ok().map(|value| value as i32)
    }

    /// The non-negative C→D duration in milliseconds, saturating at 0 (a non-monotonic clock
    /// or same-instant C/D can never produce a negative) and clamped to [`u32::MAX`]. The
    /// integer-ms analogue of Swift `durationMS(from:to:)` — the dumper scripts the Swift
    /// clock so `(end - start) * 1000` rounded equals `now_ms - start_ms`.
    #[must_use]
    const fn duration_ms(start_ms: u64, now_ms: u64) -> u32 {
        let dur = now_ms.saturating_sub(start_ms);
        if dur >= u32::MAX as u64 {
            u32::MAX
        } else {
            dur as u32
        }
    }
}
