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

    // MARK: Click-to-line navigation (ES-E5-5)

    /// Two DIFFERENT hits in the SAME pane must produce DIFFERENT navigation intent — the click-to-line fix.
    /// The half-delivered behaviour armed `search:` + a SINGLE `navigate_search:next` for every row, so the
    /// 1st and 3rd hits were indistinguishable. Here the 3rd hit advances by its ordinal (3 nexts) while the
    /// 1st advances by 1 — revert ``navigationActions`` to a single shared next and this fails.
    func testNavigationActionsAdvanceToTheClickedHitsOrdinal() throws {
        // One pane, THREE hits on distinct lines (buffer order).
        let results = GlobalSearchController.run(
            sources: [source("pane", ["alpha doc", "beta doc", "gamma doc"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hits = try XCTUnwrap(results.groups.first?.hits)
        XCTAssertEqual(hits.count, 3)

        let first = GlobalSearchController.navigationActions(for: hits[0], in: results, query: "doc")
        let third = GlobalSearchController.navigationActions(for: hits[2], in: results, query: "doc")

        // Both arm the same search…
        XCTAssertEqual(first.first, "search:doc")
        XCTAssertEqual(third.first, "search:doc")
        // …but advance by the hit's 0-based ordinal + 1 — so the rows land DISTINCTLY.
        XCTAssertEqual(first, ["search:doc", "navigate_search:next"])
        XCTAssertEqual(
            third,
            ["search:doc", "navigate_search:next", "navigate_search:next", "navigate_search:next"],
        )
        XCTAssertNotEqual(first, third, "distinct rows in one pane must produce distinct navigation intent")
    }

    /// REGEX-mode click-to-line must NOT arm libghostty's literal matcher (which has no regex engine — arming
    /// the pattern matches the pattern TEXT, usually 0 hits, leaving every `navigate_search:next` dead: the
    /// dishonest "counter says N, nav moves nothing" state). Instead it must END any stale search and scroll
    /// straight to the clicked hit's row — mirroring the find bar's regex path. Revert `navigationActions` to
    /// the literal `search:`/`navigate_search:` sequence and this fails.
    func testNavigationActionsRegexScrollsToRowWithoutLiteralSearch() throws {
        let results = GlobalSearchController.run(
            sources: [source("pane", ["alpha 12", "beta 34", "gamma 56"])],
            query: #"\d+"#,
            caseSensitive: false,
            isRegex: true,
        )
        let hits = try XCTUnwrap(results.groups.first?.hits)
        XCTAssertEqual(hits.count, 3)

        // The 3rd hit is on line index 2 — regex mode scrolls there directly.
        let third = GlobalSearchController.navigationActions(
            for: hits[2], in: results, query: #"\d+"#, isRegex: true,
        )
        XCTAssertEqual(third, ["end_search", "scroll_to_row:\(hits[2].line)"])

        // It must NEVER arm the literal pattern or step the literal cursor (those move nothing in regex mode).
        XCTAssertFalse(
            third.contains { $0.hasPrefix("search:") },
            "regex jump must not arm libghostty's literal search",
        )
        XCTAssertFalse(third.contains("navigate_search:next"), "regex jump must not step the dead literal cursor")
        XCTAssertFalse(third.contains("navigate_search:previous"))

        // Distinct regex rows still land distinctly (each scrolls to its own row).
        let first = GlobalSearchController.navigationActions(
            for: hits[0], in: results, query: #"\d+"#, isRegex: true,
        )
        XCTAssertEqual(first, ["end_search", "scroll_to_row:\(hits[0].line)"])
        XCTAssertNotEqual(first, third, "distinct regex rows must produce distinct scroll targets")
    }

    /// An empty query arms nothing (validate-then-drop); a hit absent from the results degrades to a single
    /// step (ordinal 0) rather than trapping.
    func testNavigationActionsEmptyQueryAndStaleHit() throws {
        let results = GlobalSearchController.run(
            sources: [source("pane", ["a doc"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        XCTAssertEqual(GlobalSearchController.navigationActions(for: hit, in: results, query: ""), [])
        // A hit not present in an (empty) result set falls back to a single step (no trap, no over-advance).
        XCTAssertEqual(
            GlobalSearchController.navigationActions(for: hit, in: .empty, query: "doc"),
            ["search:doc", "navigate_search:next"],
        )
    }
}
