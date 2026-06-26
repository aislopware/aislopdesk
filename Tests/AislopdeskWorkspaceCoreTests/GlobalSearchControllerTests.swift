import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// The pure ⇧⌘F Global Search engine (E5 WI-1): runs ``TerminalSearchController/computeMatches`` over every
/// terminal pane's scrollback mirror, drops zero-hit sources, groups by source, builds full-line excerpts with
/// UTF-16 highlight ranges, and produces the `N results — M tabs` summary. All against in-memory sources — no
/// view, no store, no libghostty.
final class GlobalSearchControllerTests: XCTestCase {
    /// Mints a source with a fresh identity (UUID-backed) and the given title + buffer.
    private func source(_ title: String, _ lines: [String]) -> GlobalSearchSource {
        GlobalSearchSource(
            paneID: PaneID(),
            sessionID: SessionID(),
            tabID: TabID(),
            groupTitle: title,
            lines: lines,
        )
    }

    // MARK: Grouping + summary

    func testGroupsByTabAndCountsSummary() {
        // 3 sources; "doc" hits in 2 of them (2 + 2 = 4 hits); the third has none and must be dropped.
        let sources = [
            source("alpha", ["open docs", "read doc"]), // 2 hits
            source("beta", ["doc doc"]), // 2 hits ("doc" at col 0 and col 4)
            source("gamma", ["nothing here"]), // 0 hits ⇒ no group
        ]
        let results = GlobalSearchController.run(sources: sources, query: "doc", caseSensitive: false, isRegex: false)

        XCTAssertEqual(results.groups.count, 2)
        XCTAssertEqual(results.totalMatches, 4)
        XCTAssertEqual(results.tabCount, 2)
        XCTAssertEqual(results.summary, "4 results — 2 tabs")
        // Source order is preserved; the zero-hit "gamma" is absent (not merely empty).
        XCTAssertEqual(results.groups.map(\.groupTitle), ["alpha", "beta"])
        XCTAssertEqual(results.groups.map(\.hits.count), [2, 2])
    }

    // MARK: Empty source

    func testEmptySourceContributesNoGroup() {
        let sources = [
            source("empty-pane", []), // never received bytes ⇒ absent
            source("live-pane", ["a doc line"]), // 1 hit
        ]
        let results = GlobalSearchController.run(sources: sources, query: "doc", caseSensitive: false, isRegex: false)

        XCTAssertEqual(results.groups.count, 1)
        XCTAssertEqual(results.groups.first?.groupTitle, "live-pane")
        XCTAssertEqual(results.totalMatches, 1)
        XCTAssertEqual(results.tabCount, 1)
    }

    // MARK: Excerpt + highlight range

    func testExcerptAndHighlightRange() throws {
        let results = GlobalSearchController.run(
            sources: [source("only", ["the docs folder"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        // The excerpt is the FULL matched line, not a substring.
        XCTAssertEqual(hit.excerpt, "the docs folder")
        // "the " is 4 UTF-16 units, so "doc" begins at column 4 with length 3.
        XCTAssertEqual(hit.column, 4)
        XCTAssertEqual(hit.length, 3)
        // The highlight is that exact UTF-16 sub-range of the excerpt.
        XCTAssertEqual(hit.highlight, 4..<7)
        // …and slicing the excerpt by that UTF-16 range yields the matched term (proves the range is usable).
        // swiftlint:disable:next legacy_objc_type
        let ns = hit.excerpt as NSString
        let sliced = ns.substring(with: NSRange(location: hit.highlight.lowerBound, length: hit.highlight.count))
        XCTAssertEqual(sliced, "doc")
    }

    // MARK: Case + regex honored (parity with TerminalSearchController flags)

    func testCaseSensitiveAndRegexHonored() {
        // Case-insensitive (default) matches both "doc" and "DOC"; case-sensitive narrows to the exact "DOC".
        let caseSource = [source("case", ["doc", "DOC"])]
        let insensitive = GlobalSearchController.run(
            sources: caseSource,
            query: "DOC",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(insensitive.totalMatches, 2)
        let sensitive = GlobalSearchController.run(
            sources: caseSource,
            query: "DOC",
            caseSensitive: true,
            isRegex: false,
        )
        XCTAssertEqual(sensitive.totalMatches, 1)
        XCTAssertEqual(sensitive.groups.first?.hits.first?.line, 1)

        // Regex mode honors the pattern (literal mode would not match "do." at all).
        let regexSource = [source("regex", ["dog", "dot", "cat"])]
        let regex = GlobalSearchController.run(
            sources: regexSource,
            query: "do.",
            caseSensitive: false,
            isRegex: true,
        )
        XCTAssertEqual(regex.totalMatches, 2)
        let literal = GlobalSearchController.run(
            sources: regexSource,
            query: "do.",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(literal.totalMatches, 0) // no literal "do." substring exists
    }

    // MARK: Invalid regex — validate-then-drop

    func testInvalidRegexYieldsNoResultsNeverTraps() {
        let results = GlobalSearchController.run(
            sources: [source("only", ["doc one", "doc two"])],
            query: "doc(", // unbalanced ⇒ invalid pattern
            caseSensitive: false,
            isRegex: true,
        )
        XCTAssertTrue(results.groups.isEmpty) // dropped, never trapped
        XCTAssertEqual(results.totalMatches, 0)
        XCTAssertEqual(results.tabCount, 0)
    }

    // MARK: Empty query

    func testEmptyQueryYieldsZeroResults() {
        let results = GlobalSearchController.run(
            sources: [source("only", ["doc one", "doc two"])],
            query: "",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(results, .empty)
        XCTAssertEqual(results.totalMatches, 0)
        XCTAssertEqual(results.tabCount, 0)
        XCTAssertEqual(results.summary, "0 results — 0 tabs")
    }
}
