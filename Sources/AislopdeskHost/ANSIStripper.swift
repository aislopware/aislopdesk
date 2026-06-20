import Foundation

/// Pure-Swift ANSI escape-sequence stripper.
///
/// Removes the most common terminal escape sequences from a UTF-8 string,
/// returning plain text suitable for regex matching (the `wait` verb's `--until`
/// predicate). The implementation is a byte-at-a-time state machine — no heap
/// allocation per character, no Foundation regex overhead. Non-destructive in the
/// sense that the caller owns the original string; this returns a new `String`.
///
/// Stripped sequences:
/// - CSI sequences: `ESC [` followed by parameter/intermediate bytes and one final byte.
/// - OSC sequences: `ESC ]` (or `\x9D`) followed by any bytes up to `BEL` / `ST` (`ESC \`).
/// - DCS / SOS / PM / APC sequences: `ESC P/X/^/_` body up to `ST`.
/// - Single-character C1 controls that are sometimes sent as two-byte `ESC x` (`ESC @` … `ESC _`).
/// - Standalone `ESC c` (RIS) and similar two-byte private sequences outside CSI/OSC range.
///
/// Passes through printable ASCII, UTF-8 multi-byte codepoints, tab, newline, carriage
/// return, backspace — the text content an `--until` regex needs.
///
/// No C/unsafe: pure Swift byte scanning.
public enum ANSIStripper {
    /// Returns `input` with all recognised ANSI/VT escape sequences removed.
    public static func strip(_ input: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(input.utf8.count)

        var bytes = Array(input.utf8)
        var i = bytes.startIndex

        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0x1B { // ESC
                let next = bytes.index(after: i)
                guard next < bytes.endIndex else { i = bytes.endIndex
                    break
                }
                let b2 = bytes[next]
                switch b2 {
                case 0x5B: // CSI — 'ESC ['
                    i = skipCSI(bytes: bytes, from: bytes.index(after: next))
                case 0x5D, // OSC — 'ESC ]'
                     0x50, // DCS — 'ESC P'
                     0x58, // SOS — 'ESC X'
                     0x5E, // PM  — 'ESC ^'
                     0x5F: // APC — 'ESC _'
                    i = skipStringCommand(bytes: bytes, from: bytes.index(after: next))
                default:
                    // Two-byte ESC sequence (C1 alias or private): skip both bytes.
                    i = bytes.index(after: next)
                }
            } else if b == 0x9B { // C1 CSI (raw 0x9B byte in a Latin-1 / 8-bit stream;
                // NOTE: in valid UTF-8 streams U+009B encodes as two bytes 0xC2 0x9B —
                // this branch handles raw-byte PTY output that arrives as Data, not
                // already-validated UTF-8 strings.
                i = skipCSI(bytes: bytes, from: bytes.index(after: i))
            } else if b == 0x9D { // C1 OSC (8-bit)
                i = skipStringCommand(bytes: bytes, from: bytes.index(after: i))
            } else {
                out.append(b)
                i = bytes.index(after: i)
            }
        }

        return String(bytes: out, encoding: .utf8) ?? String(out.map { Character(UnicodeScalar($0)) })
    }

    // MARK: - Private helpers

    /// Skips a CSI sequence body. Called immediately AFTER the CSI introducer.
    /// CSI body = zero or more parameter bytes (0x30–0x3F) + intermediate bytes (0x20–0x2F)
    /// + exactly one final byte (0x40–0x7E). Returns the index of the first byte AFTER the sequence.
    private static func skipCSI(bytes: [UInt8], from start: Int) -> Int {
        var i = start
        // Parameter bytes: 0x30–0x3F
        while i < bytes.endIndex, bytes[i] >= 0x30, bytes[i] <= 0x3F { i = bytes.index(after: i) }
        // Intermediate bytes: 0x20–0x2F
        while i < bytes.endIndex, bytes[i] >= 0x20, bytes[i] <= 0x2F { i = bytes.index(after: i) }
        // Final byte: 0x40–0x7E
        if i < bytes.endIndex, bytes[i] >= 0x40, bytes[i] <= 0x7E { i = bytes.index(after: i) }
        return i
    }

    /// Skips an OSC/DCS/SOS/PM/APC string-command body.
    /// Body ends at BEL (0x07) or String Terminator (ST = ESC \\ = 0x1B 0x5C).
    /// Returns the index of the first byte AFTER the terminator.
    private static func skipStringCommand(bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.endIndex {
            let b = bytes[i]
            if b == 0x07 { // BEL terminates OSC
                return bytes.index(after: i)
            }
            if b == 0x1B { // ESC — check for ST (ESC \)
                let next = bytes.index(after: i)
                if next < bytes.endIndex, bytes[next] == 0x5C {
                    return bytes.index(after: next)
                }
                // Malformed: treat ESC without '\' as terminator to avoid runaway skip.
                return next
            }
            if b == 0x9C { // C1 ST (8-bit)
                return bytes.index(after: i)
            }
            i = bytes.index(after: i)
        }
        return i // ran to end of input
    }
}
