import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// WB2 — the PURE VT-strip: raw captured Block output bytes (control sequences preserved on the wire) →
/// clipboard PLAIN TEXT. Colour/SGR runs stripped, OSC stripped, printable text + newlines + tabs kept,
/// and — the safety bar — a malformed / truncated escape sequence never traps (consumes to end).
final class BlockOutputSanitizerTests: XCTestCase {
    private func strip(_ string: String) -> String {
        BlockOutputSanitizer.plainText(from: Data(string.utf8))
    }

    private func strip(_ bytes: [UInt8]) -> String {
        BlockOutputSanitizer.plainText(from: Data(bytes))
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(strip("hello world"), "hello world")
        XCTAssertEqual(strip(""), "")
    }

    func testSGRColourRunsAreStripped() {
        // `\e[31mred\e[0m` (set red, "red", reset) → "red".
        XCTAssertEqual(strip("\u{1B}[31mred\u{1B}[0m"), "red")
        // A 256-colour SGR with multiple params: `\e[38;5;160mX\e[0m`.
        XCTAssertEqual(strip("\u{1B}[38;5;160mX\u{1B}[0m"), "X")
        // Bold + colour + reset around a word, mid-line.
        XCTAssertEqual(strip("a\u{1B}[1;32mb\u{1B}[0mc"), "abc")
    }

    func testCursorAndEraseCSIAreStripped() {
        // Cursor move (`\e[2J` clear, `\e[H` home, `\e[K` erase-line) — all dropped, text survives.
        XCTAssertEqual(strip("\u{1B}[2J\u{1B}[Hdone\u{1B}[K"), "done")
    }

    func testOSCSequencesAreStripped() {
        // OSC 0 (set title) terminated by BEL: `\e]0;my title\a` → dropped.
        XCTAssertEqual(strip("\u{1B}]0;my title\u{07}text"), "text")
        // OSC terminated by ST (ESC '\'): `\e]8;;http://x\e\\link\e]8;;\e\\` (hyperlink) → just "link".
        XCTAssertEqual(strip("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\"), "link")
    }

    func testNewlinesPreservedAndCRLFCollapsed() {
        XCTAssertEqual(strip("line1\nline2"), "line1\nline2")
        XCTAssertEqual(strip("line1\r\nline2"), "line1\nline2", "CRLF collapses to LF")
        XCTAssertEqual(strip("over\rwrite"), "overwrite", "a lone CR (overwrite motion) is dropped")
    }

    func testTabsPreserved() {
        XCTAssertEqual(strip("a\tb\tc"), "a\tb\tc")
    }

    func testOtherC0ControlsDropped() {
        // BS (0x08), VT (0x0B), FF (0x0C), DEL (0x7F) are formatting noise → dropped; printable survives.
        XCTAssertEqual(strip([0x61, 0x08, 0x0B, 0x0C, 0x7F, 0x62]), "ab")
    }

    func testShortEscapesStripped() {
        // Charset designation `\e(B` (3 bytes), keypad `\e=` (2 bytes) — both consumed, text survives.
        XCTAssertEqual(strip("\u{1B}(Btext"), "text")
        XCTAssertEqual(strip("\u{1B}=more"), "more")
    }

    func testMultiByteUTF8Preserved() {
        // A coloured run around a multi-byte scalar (é / emoji) keeps the scalar intact.
        XCTAssertEqual(strip("\u{1B}[33mcafé 🚀\u{1B}[0m"), "café 🚀")
    }

    func testMalformedSequencesDoNotTrap() {
        // Unterminated CSI at end-of-buffer: `text\e[` → keeps "text", consumes the dangling ESC '['.
        XCTAssertEqual(strip("text\u{1B}["), "text")
        // Unterminated OSC at end-of-buffer: `\e]0;no terminator` → all consumed, no trap.
        XCTAssertEqual(strip("\u{1B}]0;no terminator"), "")
        // A bare trailing ESC.
        XCTAssertEqual(strip("hi\u{1B}"), "hi")
        // A CSI with only parameter bytes then EOF (`\e[38;5;`) — consumed, no over-read.
        XCTAssertEqual(strip("x\u{1B}[38;5;"), "x")
    }

    func testInvalidUTF8DoesNotTrap() {
        // A stray 0x80 continuation byte with no lead — the lossy decode replaces it (U+FFFD); never a trap.
        let out = strip([0x61, 0x80, 0x62])
        XCTAssertTrue(out.hasPrefix("a"))
        XCTAssertTrue(out.hasSuffix("b"))
    }

    func testRealisticColouredLsOutput() {
        // A typical `ls --color` line: directory in bold blue, a regular file, a newline.
        let input = "\u{1B}[01;34mdir\u{1B}[0m  file.txt\n"
        XCTAssertEqual(strip(input), "dir  file.txt\n")
    }
}
