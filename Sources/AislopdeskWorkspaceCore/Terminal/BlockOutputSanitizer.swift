import Foundation

// MARK: - BlockOutputSanitizer (raw VT bytes → clipboard plain text)

/// Turns a Block's RAW captured VT output bytes (control sequences preserved on the wire) into PLAIN
/// TEXT suitable for the clipboard (WB2): it strips the terminal control sequences (CSI / SGR colour
/// runs, OSC, single-char C0/C1 controls) and keeps the PRINTABLE characters + newlines + tabs.
///
/// This is a deliberately SMALL, robust VT skimmer — not a full terminal emulator. It does not try to
/// interpret cursor motion / clears (the host's captured output is already the on-screen byte stream for
/// the command, so a linear strip reproduces what the user saw closely enough for a copy). It is built to
/// NEVER trap on a malformed / truncated sequence: an unterminated CSI/OSC at end-of-buffer simply
/// consumes to the end, and every index advance is bounds-checked.
///
/// PURE + `nonisolated` so it runs off any actor and is headlessly unit-testable (the WB2 brief's ask:
/// colour runs stripped, text preserved, malformed sequences don't trap).
public enum BlockOutputSanitizer {
    /// Strips VT control sequences from `bytes` and decodes the surviving printable run as UTF-8 (lossy:
    /// an invalid byte becomes U+FFFD — the clipboard text is best-effort, never a throw). Newlines (`\n`,
    /// and a `\r\n` collapsed to `\n`) and tabs are preserved; a bare `\r` (carriage return without a
    /// following `\n`) is dropped (it is overwrite-cursor motion, not a line the user wants pasted).
    public static func plainText(from bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }
        let input = [UInt8](bytes)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        let n = input.count
        // Reverse-video (SGR 7) tracking so a trailing zsh PROMPT_EOL_MARK can be dropped. zsh prints a
        // reverse-video `%` (or `#` for root) padded with spaces + a bare CR when the command's last output
        // line lacks a trailing newline — it lands INSIDE the captured C→D bytes and, once the SGR is
        // stripped, would otherwise survive as a bare trailing "%". `eolMark` remembers the `out` offset of
        // a reverse-video `%`/`#` that is followed only by pad whitespace; it is chopped after the scan.
        var reverseOn = false
        var eolMark: Int?
        while i < n {
            let byte = input[i]
            switch byte {
            case 0x1B: // ESC — start of an escape sequence
                let end = skipEscapeSequence(input, from: i)
                if let effect = sgrReverseEffect(input, from: i, upTo: end) { reverseOn = effect }
                i = end
            case 0x0A: // LF — keep (a real newline)
                out.append(0x0A)
                eolMark = nil // real content follows/precedes → not a trailing EOL mark
                i += 1
            case 0x09: // HT — keep (a tab; meaningful whitespace in pasted output)
                out.append(0x09)
                i += 1
            case 0x0D: // CR — collapse `\r\n` → `\n`; drop a lone `\r` (overwrite motion)
                if i + 1 < n, input[i + 1] == 0x0A {
                    out.append(0x0A)
                    eolMark = nil
                    i += 2
                } else {
                    i += 1 // lone CR terminates the EOL mark's pad — leave any pending mark intact
                }
            case 0x00...0x08,
                 0x0B,
                 0x0C,
                 0x0E...0x1F,
                 0x7F:
                // Other C0 controls + DEL — drop (BS/VT/FF/SI/SO/etc. are formatting noise for a paste).
                i += 1
            case 0x23,
                 0x25: // '#' / '%' — candidate zsh EOL mark iff currently reverse-video
                eolMark = reverseOn ? out.count : nil
                out.append(byte)
                i += 1
            case 0x20: // space — pad after the EOL mark; keep it AND any pending mark candidate
                out.append(byte)
                i += 1
            default:
                // Printable ASCII or a UTF-8 continuation/lead byte (≥ 0x80) — keep verbatim; the final
                // lossy UTF-8 decode reassembles multi-byte scalars (and replaces any broken ones). Any
                // ordinary printable invalidates a pending EOL-mark candidate.
                eolMark = nil
                out.append(byte)
                i += 1
            }
        }
        // Chop a trailing zsh PROMPT_EOL_MARK: the reverse-video `%`/`#` at `eolMark` plus the pad
        // whitespace after it (everything from the mark to end-of-buffer is `%`/`#` + spaces by construction).
        if let eolMark { out.removeLast(out.count - eolMark) }
        // LOSSY by design: a clipboard paste is best-effort — a broken UTF-8 byte in the captured output
        // becomes U+FFFD rather than dropping the whole copy. `String(decoding:as:)` is the non-failable
        // lossy initializer; the failable `String(bytes:encoding:)` the lint rule prefers would return nil
        // on any invalid byte and lose the paste, which is the wrong trade-off here.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out, as: UTF8.self)
    }

    /// Returns the index PAST the escape sequence beginning at `start` (where `input[start] == ESC`).
    /// Handles the three shapes the host's captured output can contain:
    ///   • CSI `ESC [ … <final 0x40–0x7E>` (SGR colours, cursor ops, erases) — skip to the final byte;
    ///   • OSC `ESC ] … (BEL | ESC \\)` (title / hyperlink / clipboard) — skip to the terminator;
    ///   • a SHORT two-byte escape `ESC <byte>` (e.g. `ESC ( B` charset, `ESC =` keypad) — skip both.
    /// An UNTERMINATED sequence at end-of-buffer consumes to the end (never reads past `n`).
    private static func skipEscapeSequence(_ input: [UInt8], from start: Int) -> Int {
        let n = input.count
        let next = start + 1
        guard next < n else { return n } // a trailing bare ESC — consume it
        switch input[next] {
        case 0x5B: // '[' — CSI: parameter/intermediate bytes (0x20–0x3F) then a final (0x40–0x7E)
            var j = next + 1
            while j < n {
                let b = input[j]
                if (0x40...0x7E).contains(b) { return j + 1 } // final byte ends the CSI
                j += 1
            }
            return n // unterminated CSI — consumed to the end
        case 0x5D: // ']' — OSC: runs until BEL (0x07) or ST (ESC '\\')
            var j = next + 1
            while j < n {
                if input[j] == 0x07 { return j + 1 } // BEL terminator
                if input[j] == 0x1B, j + 1 < n, input[j + 1] == 0x5C { return j + 2 } // ST = ESC '\'
                j += 1
            }
            return n // unterminated OSC — consumed to the end
        default:
            // A short escape (charset select `ESC ( X`, keypad `ESC =`, etc.). Most are two bytes; the
            // charset-designator forms are three (`ESC ( B`). Skip the introducer; if the next byte is a
            // charset-designation introducer ('(' ')' '*' '+'), skip its argument too. Bounds-checked.
            let intro = input[next]
            if intro == 0x28 || intro == 0x29 || intro == 0x2A || intro == 0x2B, next + 1 < n {
                return next + 2 // ESC ( B  → 3 bytes total
            }
            return next + 1 // ESC X → 2 bytes total
        }
    }

    /// Interprets the escape sequence `input[start..<end]` (where `input[start] == ESC`) as an SGR and
    /// returns its effect on the reverse-video (standout) state, used ONLY to detect a zsh EOL mark:
    ///   • `true`  — the SGR turns reverse-video ON (a `7` parameter);
    ///   • `false` — the SGR turns it OFF (a `0`/empty reset, or an explicit `27`);
    ///   • `nil`   — not an SGR, or an SGR that doesn't touch reverse-video (leave the state unchanged).
    /// Only a CSI ending in `m` is an SGR; parameters are `;`-separated decimal runs between `ESC [` and `m`.
    private static func sgrReverseEffect(_ input: [UInt8], from start: Int, upTo end: Int) -> Bool? {
        guard end - start >= 3, input[start + 1] == 0x5B, input[end - 1] == 0x6D else { return nil } // `ESC [ … m`
        // Empty params (`ESC [ m`) == `ESC [ 0 m` == a full reset → reverse OFF.
        guard end - 1 > start + 2 else { return false }
        var result: Bool?
        var value = 0
        var sawDigit = false
        func commit() {
            if !sawDigit { result = false } // an empty field is a `0` reset → reverse OFF
            else if value == 7 { result = true }
            else if value == 0 || value == 27 { result = false }
            sawDigit = false
            value = 0
        }
        for j in (start + 2)..<(end - 1) {
            let b = input[j]
            if b == 0x3B { // ';' — parameter separator
                commit()
            } else if (0x30...0x39).contains(b) { // '0'…'9'
                value = value * 10 + Int(b - 0x30)
                sawDigit = true
            } else {
                return nil // an intermediate byte (e.g. `ESC [ ? … m`) — not a plain SGR we interpret
            }
        }
        commit()
        return result
    }
}
