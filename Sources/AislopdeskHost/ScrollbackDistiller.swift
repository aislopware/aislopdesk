import Foundation

// MARK: - ScrollbackDistiller (raw cold-reattach scrollback → clean transcript)

/// Distills a RAW scrollback byte stream (the concatenated host→client PTY output the host replays to
/// a FRESH terminal on COLD reattach) into a CLEAN transcript.
///
/// The transient in-line line-editor churn that lives between the OSC-133 `B` (command-input start)
/// and `C` (output start) marks — tab-completion menus, zsh-autosuggestions ghost text, syntax-
/// highlight repaints, per-keystroke `\r`-redraws — is DROPPED and replaced by the single authoritative
/// committed command line (the `133;E` preexec command text). Everything else passes through VERBATIM:
/// the prompt (`A`→`B`), the command OUTPUT (`C`→`D`, colours intact), and any bytes outside the marks.
///
/// ## Why
/// The scrollback ring (``ReplayBuffer``) stores the raw wire bytes. Those B→C editing bytes are only
/// visually correct against the LIVE terminal's cursor + geometry: a completion menu is drawn BELOW the
/// line, then erased with cursor-RELATIVE motion (`\r`, cursor-up, `ESC[J`). Replayed LINEARLY into a
/// fresh empty terminal the erase lands on the wrong rows and menu/suggestion fragments survive as
/// garbage. Collapsing B→C to the committed command removes the churn while keeping full history AND the
/// live output formatting — exactly what a coding tool's scrollback wants.
///
/// PURE + `nonisolated`, so it runs off any actor and is headlessly unit-testable. It MIRRORS
/// ``CommandBlockSegmenter``'s OSC-133 detection (the marks + the `133;E` unescape are byte-identical) —
/// the codebase's "mirror, don't share" convention for these small VT machines — but emits a byte
/// stream rather than block metadata.
///
/// ## Safety / fallback
/// When NO `133;E` command text was seen for a B→C span (a non-zsh shell, an older shim, or a dropped
/// `E`), that span is passed through VERBATIM — the distiller NEVER invents a command line. The worst
/// case is therefore "no cleaner than the raw replay", never lost output. A pathologically large editing
/// span (huge paste) overflows a buffer cap and also falls back to verbatim passthrough for that span.
///
/// This is a display-only transform of the COLD-reattach scrollback copy; the live byte stream and the
/// un-acked resume tail are untouched (byte-exact resume is preserved — see ``ReplayBuffer/replay(after:)``).
enum ScrollbackDistiller {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let backslash: UInt8 = 0x5C
    private static let rightBracket: UInt8 = 0x5D
    private static let semicolon: UInt8 = 0x3B

    /// Payload cap for a single OSC sequence (mirrors the segmenter's general 4096 cap) — an OSC that
    /// exceeds it is discarded to its terminator so a never-terminated OSC can't grow unbounded.
    private static let oscCap = 4096
    /// Cap on the buffered B→C editing span used ONLY for the no-`E` verbatim fallback. Beyond this the
    /// span is flushed and passed through (a giant editing span won't collapse cleanly anyway).
    private static let inputSpanCap = 256 * 1024

    /// Parser state — the minimal OSC-aware skimmer. CSI / 2-byte escapes are NOT tracked as distinct
    /// states: they can never be confused with an OSC start (which requires the exact `ESC` `]`
    /// adjacency), so in a passthrough phase they flow through byte-by-byte and in a suppressed phase
    /// they are buffered/dropped byte-by-byte — no final-byte parsing needed.
    private enum State {
        case ground
        case afterEsc // last byte was ESC — decide OSC vs. other escape on the next byte
        case osc // inside an OSC string (after `ESC ]`)
        case oscEsc // inside an OSC, last byte was ESC — looking for `\` (ST)
        case oscDiscard // OSC over the cap — swallow to the terminator
        case oscDiscardEsc
    }

    /// How the current B→C command-input span is being handled.
    private enum InputMode {
        case buffering // accumulating raw bytes for the no-`E` verbatim fallback
        case passthrough // span overflowed the cap — emit raw directly (fallback)
    }

    /// Distills `bytes`. Returns the cleaned byte stream (never longer in the common case; a rare no-`E`
    /// span is byte-for-byte the input). Empty input → empty output.
    static func distill(_ bytes: Data) -> Data {
        guard !bytes.isEmpty else { return Data() }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var state = State.ground
        var pending: [UInt8] = [] // the in-progress escape/OSC sequence (from ESC), decided at its end
        var oscPayload: [UInt8] = [] // just the OSC body (between `ESC ]` and the terminator)

        // Command-input (B→C) suppression state.
        var suppress = false
        var inputMode = InputMode.buffering
        var inputBuffer: [UInt8] = [] // raw B→C bytes retained for the no-`E` fallback
        var command: [UInt8]? // the `133;E` committed command line for the current span

        // Emits a NORMAL (non-escape) content byte honoring the current phase.
        func emitContent(_ b: UInt8) {
            if !suppress {
                out.append(b)
            } else if inputMode == .passthrough {
                out.append(b)
            } else {
                inputBuffer.append(b)
                if inputBuffer.count > inputSpanCap {
                    // Overflow the fallback cap → flush what we have and passthrough the rest of the span.
                    out.append(contentsOf: inputBuffer)
                    inputBuffer.removeAll(keepingCapacity: true)
                    inputMode = .passthrough
                }
            }
        }

        // Emits (or buffers) a completed NON-133 escape/OSC sequence held in `pending`, honoring phase.
        func emitPending() {
            if pending.isEmpty { return }
            if !suppress {
                out.append(contentsOf: pending)
            } else if inputMode == .passthrough {
                out.append(contentsOf: pending)
            } else {
                inputBuffer.append(contentsOf: pending)
                if inputBuffer.count > inputSpanCap {
                    out.append(contentsOf: inputBuffer)
                    inputBuffer.removeAll(keepingCapacity: true)
                    inputMode = .passthrough
                }
            }
            pending.removeAll(keepingCapacity: true)
        }

        // Acts on a completed OSC (payload in `oscPayload`, full raw bytes in `pending`). A `133` mark is
        // CONSUMED (drives the phase, never emitted — it is zero-width). Any other OSC is emitted verbatim.
        func finishOSC() {
            defer {
                pending.removeAll(keepingCapacity: true)
                oscPayload.removeAll(keepingCapacity: true)
            }
            // Split the payload into `;`-separated fields (as the segmenter does). A non-133 OSC (or a
            // payload with no `;`) is emitted verbatim in a passthrough phase.
            guard let sep = oscPayload.firstIndex(of: semicolon) else {
                emitPending()
                return
            }
            let ps = oscPayload[oscPayload.startIndex..<sep]
            guard ps.elementsEqual([0x31, 0x33, 0x33]) else { // "133"?
                emitPending()
                return
            }
            let mark = oscPayload[oscPayload.index(after: sep)...].first
            switch mark {
            case 0x41: // 'A' — prompt start → idle (end any command span defensively).
                suppress = false
            case 0x42: // 'B' — command-input start (or a prompt REDRAW re-firing B).
                suppress = true
                inputMode = .buffering
                inputBuffer.removeAll(keepingCapacity: true)
                command = nil
            case 0x45: // 'E' — explicit committed command line (aislopdesk extension).
                command = Self.parseCommandField(oscPayload, afterFirstSemicolon: sep)
                // Tolerate an `E` that arrives without a preceding `B` (mid-stream join): start suppressing.
                if !suppress {
                    suppress = true
                    inputMode = .buffering
                    inputBuffer.removeAll(keepingCapacity: true)
                }
            case 0x43: // 'C' — output start: close the command span.
                if suppress {
                    if inputMode == .buffering {
                        if let command, !command.isEmpty {
                            out.append(contentsOf: command)
                            out.append(0x0D) // CR
                            out.append(0x0A) // LF
                        } else {
                            // No committed command text — fall back to the raw B→C bytes verbatim.
                            out.append(contentsOf: inputBuffer)
                        }
                    }
                    inputBuffer.removeAll(keepingCapacity: true)
                    command = nil
                    suppress = false
                }
            case 0x44: // 'D' — command finished → idle.
                suppress = false
            default:
                break // some other 133 subcommand — not a phase mark; drop the (zero-width) mark.
            }
        }

        for b in bytes {
            switch state {
            case .ground:
                if b == esc {
                    pending = [esc]
                    state = .afterEsc
                } else {
                    emitContent(b)
                }

            case .afterEsc:
                pending.append(b)
                switch b {
                case rightBracket: // `ESC ]` — OSC begins.
                    state = .osc
                    oscPayload.removeAll(keepingCapacity: true)
                case esc: // consecutive ESC — flush the first, keep this one as the new introducer.
                    pending.removeLast()
                    emitPending()
                    pending = [esc]
                // stay in .afterEsc
                default: // CSI (`ESC [`) or a short escape — not an OSC; flush it and resume ground.
                    emitPending()
                    state = .ground
                }

            case .osc:
                switch b {
                case bel: // BEL terminator.
                    pending.append(b)
                    finishOSC()
                    state = .ground
                case esc:
                    pending.append(b)
                    state = .oscEsc
                default:
                    pending.append(b)
                    oscPayload.append(b)
                    if oscPayload.count > oscCap {
                        oscPayload.removeAll(keepingCapacity: true)
                        pending.removeAll(keepingCapacity: true)
                        state = .oscDiscard
                    }
                }

            case .oscEsc:
                if b == backslash { // ST = `ESC \` terminator.
                    pending.append(b)
                    finishOSC()
                    state = .ground
                } else {
                    // ESC not followed by `\`: the OSC is terminated by the bare ESC; that ESC starts a
                    // new escape. Finish the OSC (without the trailing ESC), then reprocess from .afterEsc.
                    finishOSC()
                    pending = [esc]
                    state = .afterEsc
                    // Reprocess `b` in the .afterEsc arm.
                    pending.append(b)
                    switch b {
                    case rightBracket:
                        state = .osc
                        oscPayload.removeAll(keepingCapacity: true)
                    case esc:
                        pending.removeLast()
                        emitPending()
                        pending = [esc]
                    default:
                        emitPending()
                        state = .ground
                    }
                }

            case .oscDiscard:
                switch b {
                case bel: state = .ground
                case esc: state = .oscDiscardEsc
                default: break // discarded over-cap payload byte
                }

            case .oscDiscardEsc:
                if b == backslash {
                    state = .ground
                } else {
                    pending = [esc]
                    state = .afterEsc
                    pending.append(b)
                    switch b {
                    case rightBracket:
                        state = .osc
                        oscPayload.removeAll(keepingCapacity: true)
                    case esc:
                        pending.removeLast()
                        emitPending()
                        pending = [esc]
                    default:
                        emitPending()
                        state = .ground
                    }
                }
            }
        }

        // End of stream: flush any dangling escape (unterminated CSI/OSC) honoring phase — a trailing
        // partial sequence is emitted (pass) / buffered (suppress) rather than trapped or dropped.
        if !pending.isEmpty { emitPending() }
        // A never-closed B→C span (no `C` at end-of-buffer) in the buffering fallback: emit its raw bytes
        // so no output is lost (it is the tail of the live command line being edited when the ring ended).
        if suppress, inputMode == .buffering, !inputBuffer.isEmpty {
            out.append(contentsOf: inputBuffer)
        }
        return Data(out)
    }

    /// Extracts + unescapes the `133;E;<escaped>` command field. `afterFirstSemicolon` is the index of
    /// the `;` after `133`; the command field is everything after the SECOND `;`. Byte-identical to
    /// ``CommandBlockSegmenter``'s `unescapeCommand` (each `\xNN` → that byte; every other byte passes).
    private static func parseCommandField(_ payload: [UInt8], afterFirstSemicolon sep: Int) -> [UInt8] {
        let afterMark = payload.index(after: sep) // points at 'E'
        guard let sep2 = payload[afterMark...].firstIndex(of: semicolon) else { return [] }
        let field = payload[payload.index(after: sep2)...]
        return unescapeCommand(Array(field))
    }

    /// Inverts the shim's `\xNN` escaping of `;`, `\`, ESC, BEL, CR, LF. A `\` not followed by `xHH` is
    /// emitted literally (defensive; the shim never produces one). Multi-byte UTF-8 rides through.
    private static func unescapeCommand(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x5C, // '\'
               i + 3 < bytes.count,
               bytes[i + 1] == 0x78, // 'x'
               let hi = hexNibble(bytes[i + 2]),
               let lo = hexNibble(bytes[i + 3])
            {
                out.append(UInt8((hi << 4) | lo))
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private static func hexNibble(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: Int(byte - 0x30)
        case 0x41...0x46: Int(byte - 0x41) + 10
        case 0x61...0x66: Int(byte - 0x61) + 10
        default: nil
        }
    }
}
