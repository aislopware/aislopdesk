import Foundation
import XCTest
@testable import AislopdeskHost

/// The PURE cold-reattach scrollback distiller: raw wire bytes (prompt + B→C editing churn + C→D output)
/// → clean transcript (prompt kept, B→C churn collapsed to the `133;E` committed command, output kept).
final class ScrollbackDistillerTests: XCTestCase {
    // MARK: Mark builders (mirror the shim's OSC-133 wire form)

    /// `ESC ] 133 ; <body> BEL` (BEL terminator).
    private func mark(_ body: String) -> String { "\u{1B}]133;\(body)\u{07}" }
    /// `ESC ] 133 ; <body> ESC \` (ST terminator).
    private func markST(_ body: String) -> String { "\u{1B}]133;\(body)\u{1B}\\" }

    private func distill(_ string: String) -> String {
        String(bytes: ScrollbackDistiller.distill(Data(string.utf8)), encoding: .utf8) ?? ""
    }

    private func distill(_ bytes: [UInt8]) -> String {
        String(bytes: ScrollbackDistiller.distill(Data(bytes)), encoding: .utf8) ?? ""
    }

    // MARK: Baselines

    func testEmptyInput() {
        XCTAssertEqual(ScrollbackDistiller.distill(Data()), Data())
    }

    func testNoMarksPassThroughVerbatim() {
        // A stream with no OSC-133 marks (raw output) is untouched.
        XCTAssertEqual(distill("hello world\n"), "hello world\n")
        XCTAssertEqual(distill("a\u{1B}[31mred\u{1B}[0mb"), "a\u{1B}[31mred\u{1B}[0mb")
    }

    func testNonSemanticOSCPreserved() {
        // An OSC title (OSC 0) is NOT a 133 mark → preserved verbatim.
        XCTAssertEqual(distill("\u{1B}]0;my title\u{07}text"), "\u{1B}]0;my title\u{07}text")
    }

    // MARK: The core collapse

    func testCommandSpanCollapsedToCommittedCommand() {
        // Prompt (A→B) kept; the B→C editing region (here: garbage echo) DROPPED and replaced by the
        // `133;E` command text + CRLF; the C→D output kept verbatim.
        let input =
            "\(mark("A"))~/proj ❯ \(mark("B"))ggii...garbage-echo...\(mark("E;git status"))\(mark("C"))On branch main\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "~/proj ❯ git status\r\nOn branch main\n")
    }

    func testTabCompletionMenuDropped() {
        // Simulate a tab-completion interaction inside B→C: the menu is drawn with newlines + cursor
        // motion, then would be cleared. ALL of it is dropped; only the committed command survives.
        let menu = "git ch\n  checkout  cherry  cherry-pick\u{1B}[2A\u{1B}[J"
        let input =
            "\(mark("A"))$ \(mark("B"))\(menu)\(mark("E;git checkout main"))\(mark("C"))Switched to branch 'main'\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ git checkout main\r\nSwitched to branch 'main'\n")
    }

    func testOutputColoursPreserved() {
        // SGR colour runs in the C→D output must survive (unlike in B→C, where they are churn).
        let input =
            "\(mark("A"))$ \(mark("B"))x\(mark("E;ls"))\(mark("C"))\u{1B}[01;34mdir\u{1B}[0m file\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ ls\r\n\u{1B}[01;34mdir\u{1B}[0m file\n")
    }

    func testNonSemanticOSCInOutputPreserved() {
        // A hyperlink OSC (OSC 8) emitted as command OUTPUT is kept.
        let link = "\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\"
        let input = "\(mark("A"))$ \(mark("B"))x\(mark("E;echo"))\(mark("C"))\(link)\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ echo\r\n\(link)\n")
    }

    func testMultipleCommandsCollapsedIndependently() {
        let input =
            "\(mark("A"))$ \(mark("B"))junk1\(mark("E;pwd"))\(mark("C"))/home\n\(mark("D;0"))"
                + "\(mark("A"))$ \(mark("B"))junk2\(mark("E;whoami"))\(mark("C"))root\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ pwd\r\n/home\n$ whoami\r\nroot\n")
    }

    // MARK: Fallback safety (no committed command)

    func testNoExplicitCommandFallsBackToVerbatimSpan() {
        // A B→C span with NO `133;E`: the raw editing bytes pass through verbatim (never lost, never
        // invented). Byte-identical to the pre-distiller replay for a non-shim shell.
        let input = "\(mark("A"))$ \(mark("B"))ls -la\r\n\(mark("C"))total 0\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ ls -la\r\ntotal 0\n")
    }

    func testPromptRedrawResetsInputBuffer() {
        // A re-fired `B` (zle reset-prompt redraw) discards the partial B→C bytes captured so far; the
        // final `E` command is what survives.
        let input =
            "\(mark("A"))$ \(mark("B"))par\(mark("B"))partial-echo\(mark("E;make test"))\(mark("C"))ok\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ make test\r\nok\n")
    }

    // MARK: E unescape (byte-identical to the segmenter)

    func testExplicitCommandUnescaped() {
        // The shim escapes `;`, `\`, ESC, BEL, CR, LF as `\xNN`. `echo a;b` → `echo a\x3bb`.
        let input = "\(mark("A"))$ \(mark("B"))z\(mark("E;echo a\\x3bb"))\(mark("C"))a;b\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "$ echo a;b\r\na;b\n")
    }

    func testExplicitCommandWithSTTerminator() {
        // The mark may be closed by ST (`ESC \`) instead of BEL — both must parse.
        let input =
            "\(markST("A"))$ \(markST("B"))w\(markST("E;date"))\(markST("C"))Mon\n\(markST("D;0"))"
        XCTAssertEqual(distill(input), "$ date\r\nMon\n")
    }

    // MARK: Partial / mid-stream streams (scrollback ring can start mid-history)

    func testStreamStartingMidOutputPassesThrough() {
        // The ring's oldest entry can begin mid-output (line-aligned, but after a prior command's C).
        // With no leading A/B we are in the idle/passthrough phase → verbatim until the next mark cycle.
        let input = "…tail of prior output\n\(mark("A"))$ \(mark("B"))q\(mark("E;id"))\(mark("C"))uid=0\n\(mark("D;0"))"
        XCTAssertEqual(distill(input), "…tail of prior output\n$ id\r\nuid=0\n")
    }

    func testUnterminatedCommandSpanAtEndEmitsRawTail() {
        // A B→C span still open at end-of-buffer (the live command line being edited when the ring ended)
        // with no committed E: emit the raw tail so nothing is lost.
        let input = "\(mark("A"))$ \(mark("B"))half-typed-cmd"
        XCTAssertEqual(distill(input), "$ half-typed-cmd")
    }

    func testMalformedTrailingEscapeDoesNotTrap() {
        // A bare trailing ESC / unterminated OSC must not trap; the partial sequence is flushed.
        XCTAssertEqual(distill("done\u{1B}"), "done\u{1B}")
        XCTAssertEqual(distill("x\u{1B}]0;no-term"), "x\u{1B}]0;no-term")
    }

    func testEmbedded133InTitleDoesNotSegment() {
        // A `133;C`-looking substring INSIDE a non-133 OSC (title) is part of that OSC's payload, not a
        // mark — the whole title is preserved and no phantom collapse happens.
        let input = "\u{1B}]0;prompt 133;C here\u{07}visible"
        XCTAssertEqual(distill(input), "\u{1B}]0;prompt 133;C here\u{07}visible")
    }

    // MARK: Overflow fallback

    func testOversizedInputSpanFallsBackToPassthrough() {
        // A B→C span larger than the fallback cap (256 KiB) overflows → the raw bytes pass through (the
        // giant editing span won't collapse cleanly; never dropped). The C still ends the span.
        let big = String(repeating: "x", count: 300 * 1024)
        let input = "\(mark("A"))$ \(mark("B"))\(big)\(mark("E;huge"))\(mark("C"))out\n\(mark("D;0"))"
        let result = distill(input)
        // The overflowed raw span is present; output follows.
        XCTAssertTrue(result.contains(big), "oversized span should pass through verbatim")
        XCTAssertTrue(result.hasSuffix("out\n"))
    }
}
