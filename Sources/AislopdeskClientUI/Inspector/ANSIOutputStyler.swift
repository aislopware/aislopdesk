// ANSIOutputStyler — renders a command Block's RAW captured VT bytes into a COLOURED `AttributedString`
// for the inspector output pane (the "block output has no colour, just white text" report).
//
// It is the colour-preserving sibling of `BlockOutputSanitizer.plainText` (which strips ALL SGR for the
// clipboard). Here the SGR runs are HONOURED — foreground/background/bold/italic/underline — mapped to the
// ACTIVE terminal theme's 16-colour ANSI palette (plus xterm-256 and 24-bit truecolour), so a selected
// block reads with the same colours the user saw in the terminal. Everything else (cursor motion, erases,
// OSC titles/hyperlinks, C0 controls) is stripped LINEARLY: the host-captured bytes are already the
// on-screen stream for the command, so a linear strip reproduces what was shown closely enough for review.
//
// Like the sanitizer it is a deliberately SMALL, robust VT skimmer — NOT a terminal emulator — and NEVER
// traps on a malformed / truncated sequence (an unterminated CSI/OSC at end-of-buffer consumes to the end;
// every index advance is bounds-checked). A trailing zsh PROMPT_EOL_MARK (a reverse-video `%`/`#` + pad) is
// dropped, matching the plain-text sanitizer so the coloured view has no stray trailing `%` either.

#if canImport(SwiftUI)
import Foundation
import SwiftUI

extension UInt32 {
    /// Parses a 6-hex-digit RGB string (no `#`, as the theme palette stores it, e.g. `"E06C75"`) into a
    /// 24-bit value. Any malformed / short string falls back to white so a bad palette entry never traps.
    init(hex6 string: String) {
        self = UInt32(string, radix: 16).map { $0 & 0xFFFFFF } ?? 0xFFFFFF
    }
}

enum ANSIOutputStyler {
    /// The mutable SGR state accumulated as the skimmer walks the byte stream. Colours are stored as the
    /// SOURCE form (palette index vs. explicit RGB) and resolved to a concrete `Color` only at run-flush,
    /// so bold-brightening and reverse-video swap see the final palette.
    private struct SGRState: Equatable {
        var fgIndex: Int? // 0…15 ANSI palette slot
        var fgRGB: UInt32? // explicit xterm-256 / truecolour foreground (wins over `fgIndex`)
        var bgIndex: Int?
        var bgRGB: UInt32?
        var bold = false
        var italic = false
        var underline = false
        var reverse = false
    }

    /// Renders `bytes` into a coloured `AttributedString`. `palette` is the active theme's 16 ANSI colours
    /// (index 0–15) as 24-bit RGB; `defaultFg`/`defaultBg` are the terminal fg/bg used for unset/reverse.
    static func attributed(
        from bytes: Data,
        palette: [UInt32],
        defaultFg: UInt32,
        defaultBg: UInt32,
    ) -> AttributedString {
        guard !bytes.isEmpty, palette.count >= 16 else { return AttributedString() }
        let input = [UInt8](bytes)
        let n = input.count
        var result = AttributedString()
        var run: [UInt8] = []
        var state = SGRState()
        // A pending reverse-video `%`/`#` + pad, held OUT of `run` so a TRAILING zsh EOL mark can be
        // discarded at end-of-buffer. `pendingStyle` is the style captured when the candidate opened, used
        // if ordinary content later proves it was NOT a trailing mark and it must be emitted as its own run.
        var pendingEOL: [UInt8] = []
        var pendingStyle = SGRState()

        func flushRun() {
            guard !run.isEmpty else { return }
            // swiftlint:disable:next optional_data_string_conversion
            var piece = AttributedString(String(decoding: run, as: UTF8.self))
            apply(state, to: &piece, palette: palette, defaultFg: defaultFg, defaultBg: defaultBg)
            result.append(piece)
            run.removeAll(keepingCapacity: true)
        }
        // Ordinary content invalidated the trailing-mark hypothesis → emit the buffered `%`/pad as its own
        // run (with the style it had) so nothing is lost. A no-op when there is no pending candidate.
        func commitPendingEOL() {
            guard !pendingEOL.isEmpty else { return }
            // swiftlint:disable:next optional_data_string_conversion
            var piece = AttributedString(String(decoding: pendingEOL, as: UTF8.self))
            apply(pendingStyle, to: &piece, palette: palette, defaultFg: defaultFg, defaultBg: defaultBg)
            result.append(piece)
            pendingEOL.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < n {
            let byte = input[i]
            switch byte {
            case 0x1B: // ESC — an escape sequence: apply if it is an SGR, otherwise strip it. A style change
                // does NOT decide the pending EOL candidate's fate (the `%`+pad straddle the `ESC[0m` reset).
                let end = skipEscapeSequence(input, from: i)
                if let params = sgrParams(input, from: i, upTo: end) {
                    flushRun() // the style change starts a new run
                    applySGR(params, to: &state)
                }
                i = end
            case 0x0A: // LF — a real newline: ordinary content, so the pending candidate was not trailing
                commitPendingEOL()
                run.append(0x0A)
                i += 1
            case 0x09: // HT — keep the tab (ordinary content)
                commitPendingEOL()
                run.append(0x09)
                i += 1
            case 0x0D: // CR — collapse `\r\n` → `\n` (ordinary); a lone `\r` is overwrite motion (drop, and
                // it does NOT invalidate a pending mark — the zsh EOL mark ends in exactly a lone CR).
                if i + 1 < n, input[i + 1] == 0x0A {
                    commitPendingEOL()
                    run.append(0x0A)
                    i += 2
                } else {
                    i += 1
                }
            case 0x00...0x08,
                 0x0B,
                 0x0C,
                 0x0E...0x1F,
                 0x7F:
                i += 1 // other C0 controls + DEL — formatting noise, drop
            case 0x23,
                 0x25: // '#' / '%' — a zsh EOL-mark candidate iff currently reverse-video
                if state.reverse {
                    if pendingEOL.isEmpty { flushRun()
                        pendingStyle = state
                    } // open a candidate
                    pendingEOL.append(byte)
                } else {
                    commitPendingEOL()
                    run.append(byte)
                }
                i += 1
            case 0x20: // space — pad after the candidate (buffer it); otherwise ordinary content
                if pendingEOL.isEmpty { run.append(byte) } else { pendingEOL.append(byte) }
                i += 1
            default: // printable / UTF-8 byte — ordinary content invalidates a pending candidate
                commitPendingEOL()
                run.append(byte)
                i += 1
            }
        }
        // A still-pending candidate at end-of-buffer WAS the trailing mark → discard it (do not commit).
        pendingEOL.removeAll()
        flushRun()
        return result
    }

    // MARK: SGR application

    /// Resolves `state` to concrete attributes on `piece` (foreground/background colour, bold/italic font,
    /// underline). Reverse-video swaps the resolved fg/bg (falling back to the terminal defaults).
    private static func apply(
        _ state: SGRState,
        to piece: inout AttributedString,
        palette: [UInt32],
        defaultFg: UInt32,
        defaultBg: UInt32,
    ) {
        // Foreground: explicit RGB wins; else a palette slot (bold brightens a base 0–7 to 8–15); else default.
        var resolvedFg = defaultFg
        if let rgb = state.fgRGB {
            resolvedFg = rgb
        } else if let idx = boldBrighten(state.fgIndex, bold: state.bold) {
            resolvedFg = palette[idx]
        }
        var resolvedBg: UInt32? = state.bgRGB
        if resolvedBg == nil, let idx = state.bgIndex { resolvedBg = palette[idx] }

        var finalFg = resolvedFg
        var finalBg = resolvedBg
        if state.reverse {
            finalFg = resolvedBg ?? defaultBg
            finalBg = resolvedFg
        }

        piece.foregroundColor = Color(slateHex: finalFg)
        if let bg = finalBg { piece.backgroundColor = Color(slateHex: bg) }
        if state.bold || state.italic {
            var font = Font.system(.callout, design: .monospaced)
            if state.bold { font = font.weight(.bold) }
            if state.italic { font = font.italic() }
            piece.font = font
        }
        if state.underline { piece.underlineStyle = .single }
    }

    /// A base ANSI slot 0–7 rendered BOLD conventionally uses the bright slot 8–15 (matches most terminals).
    private static func boldBrighten(_ index: Int?, bold: Bool) -> Int? {
        guard let index else { return nil }
        if bold, (0...7).contains(index) { return index + 8 }
        return index
    }

    /// Mutates `state` by the SGR parameter list (`ESC [ … m`). Handles the 30/40/90/100 colour ranges, the
    /// `38/48;5;n` (xterm-256) and `38/48;2;r;g;b` (truecolour) extended forms, and the intensity/style toggles.
    private static func applySGR(_ params: [Int], to state: inout SGRState) {
        var k = 0
        while k < params.count {
            let p = params[k]
            switch p {
            case 0: state = SGRState()
            case 1: state.bold = true
            case 3: state.italic = true
            case 4: state.underline = true
            case 7: state.reverse = true
            case 22: state.bold = false
            case 23: state.italic = false
            case 24: state.underline = false
            case 27: state.reverse = false
            case 30...37: state.fgIndex = p - 30
                state.fgRGB = nil
            case 39: state.fgIndex = nil
                state.fgRGB = nil
            case 40...47: state.bgIndex = p - 40
                state.bgRGB = nil
            case 49: state.bgIndex = nil
                state.bgRGB = nil
            case 90...97: state.fgIndex = p - 90 + 8
                state.fgRGB = nil
            case 100...107: state.bgIndex = p - 100 + 8
                state.bgRGB = nil
            case 38,
                 48:
                // Extended colour: `38;5;n` (256) or `38;2;r;g;b` (truecolour). Advance `k` past the args.
                guard k + 1 < params.count else { k = params.count
                    break
                }
                let mode = params[k + 1]
                if mode == 5, k + 2 < params.count {
                    let rgb = xterm256(params[k + 2])
                    if p == 38 { state.fgRGB = rgb
                        state.fgIndex = nil
                    } else { state.bgRGB = rgb
                        state.bgIndex = nil
                    }
                    k += 2
                } else if mode == 2, k + 4 < params.count {
                    let r = UInt32(clamping: params[k + 2]) & 0xFF
                    let g = UInt32(clamping: params[k + 3]) & 0xFF
                    let b = UInt32(clamping: params[k + 4]) & 0xFF
                    let rgb = (r << 16) | (g << 8) | b
                    if p == 38 { state.fgRGB = rgb
                        state.fgIndex = nil
                    } else { state.bgRGB = rgb
                        state.bgIndex = nil
                    }
                    k += 4
                } else {
                    k = params.count // malformed extended run — stop
                }
            default: break // unhandled SGR (dim/blink/etc.) — no visual effect here
            }
            k += 1
        }
    }

    /// Maps an xterm-256 palette index to a 24-bit RGB. 0–15 are the classic ANSI slots (approximated with a
    /// fixed table so the extended range is self-contained); 16–231 are the 6×6×6 colour cube; 232–255 are the
    /// 24-step grayscale ramp. Out-of-range indices clamp to white.
    private static func xterm256(_ index: Int) -> UInt32 {
        switch index {
        case 0...15:
            return ansi16[index]
        case 16...231:
            let v = index - 16
            let r = (v / 36) % 6, g = (v / 6) % 6, b = v % 6
            func channel(_ c: Int) -> UInt32 { c == 0 ? 0 : UInt32(55 + c * 40) }
            return (channel(r) << 16) | (channel(g) << 8) | channel(b)
        case 232...255:
            let level = UInt32(8 + (index - 232) * 10)
            return (level << 16) | (level << 8) | level
        default:
            return 0xFFFFFF
        }
    }

    /// Fixed 16-colour table used ONLY for the xterm-256 low range (`38;5;0…15`) — the truecolour path is
    /// self-contained so it does not depend on the theme palette for the extended-colour cube's base slots.
    private static let ansi16: [UInt32] = [
        0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0,
        0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]

    // MARK: VT skimming (mirrors BlockOutputSanitizer)

    /// Returns the SGR parameter list if `input[start…end]` is a CSI ending in `m` (`ESC [ … m`), else `nil`
    /// (a non-SGR escape — cursor op, OSC, charset — that the caller strips). Empty fields decode to `0`.
    private static func sgrParams(_ input: [UInt8], from start: Int, upTo end: Int) -> [Int]? {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x6D else { return nil }
        // A private-mode CSI (`ESC [ ? … m`) is not a colour SGR — reject if the first param byte is a marker.
        if end - 1 > start + 2, (0x3C...0x3F).contains(input[start + 2]) { return nil }
        var params: [Int] = []
        var value = 0
        var sawDigit = false
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            if b == 0x3B { // ';'
                params.append(sawDigit ? value : 0)
                value = 0
                sawDigit = false
            } else if (0x30...0x39).contains(b) {
                value = value * 10 + Int(b - 0x30)
                sawDigit = true
            } else {
                return nil // intermediate byte — not a plain SGR
            }
        }
        params.append(sawDigit ? value : 0)
        return params
    }

    /// Index PAST the escape sequence at `start` (`input[start] == ESC`): CSI to its final byte, OSC to its
    /// terminator (BEL / ST), or a short 2–3 byte escape. Unterminated at end-of-buffer consumes to the end.
    private static func skipEscapeSequence(_ input: [UInt8], from start: Int) -> Int {
        let n = input.count
        let next = start + 1
        guard next < n else { return n }
        switch input[next] {
        case 0x5B: // '[' CSI
            var j = next + 1
            while j < n {
                if (0x40...0x7E).contains(input[j]) { return j + 1 }
                j += 1
            }
            return n
        case 0x5D: // ']' OSC
            var j = next + 1
            while j < n {
                if input[j] == 0x07 { return j + 1 }
                if input[j] == 0x1B, j + 1 < n, input[j + 1] == 0x5C { return j + 2 }
                j += 1
            }
            return n
        default:
            let intro = input[next]
            if intro == 0x28 || intro == 0x29 || intro == 0x2A || intro == 0x2B, next + 1 < n {
                return next + 2
            }
            return next + 1
        }
    }
}
#endif
