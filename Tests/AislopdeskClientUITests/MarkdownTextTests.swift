// MarkdownTextTests — pins the pure large-document guard that decides rich-Markdown (Textual's
// `StructuredText`) vs the plain-text fallback. The guard exists to dodge Textual issue #23 (crash on
// very large docs), so the thresholds are load-bearing; rendering itself is SwiftUI/JSC and not exercised
// here (the hang-safety / headless discipline — only the allocation-free decision is tested).

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class MarkdownTextTests: XCTestCase {
    func testEmptyIsNotRich() {
        XCTAssertFalse(MarkdownText.shouldRenderRich(""))
    }

    func testSmallMarkdownIsRich() {
        XCTAssertTrue(MarkdownText.shouldRenderRich("# Title\n\nSome **bold** and `code`."))
    }

    func testOversizedByBytesFallsBackToPlain() {
        let huge = String(repeating: "x", count: MarkdownText.maxRichBytes + 1)
        XCTAssertFalse(MarkdownText.shouldRenderRich(huge), "past the byte ceiling ⇒ plain-text guard")
    }

    func testOversizedByLinesFallsBackToPlain() {
        // Tiny in bytes but very many lines (the issue #23 shape: hundreds of blocks).
        let manyLines = String(repeating: "a\n", count: MarkdownText.maxRichLines + 1)
        XCTAssertLessThan(manyLines.utf8.count, MarkdownText.maxRichBytes, "stays under the byte ceiling")
        XCTAssertFalse(MarkdownText.shouldRenderRich(manyLines), "past the line ceiling ⇒ plain-text guard")
    }

    func testAtLineCeilingStaysRich() {
        // Exactly maxRichLines lines (maxRichLines-1 newlines) is still within bounds.
        let atCeiling = String(repeating: "a\n", count: MarkdownText.maxRichLines - 1) + "a"
        XCTAssertTrue(MarkdownText.shouldRenderRich(atCeiling))
    }
}
#endif
