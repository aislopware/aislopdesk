import Foundation
import XCTest
@testable import AislopdeskClientUI

/// The pure ⌘F find-in-terminal engine (docs/42 W14 #5): literal + regex matching, case toggle, the
/// ordered match list, next/prev/wrap navigation, the "N of M" position, and re-anchoring on recompute.
/// All against an in-memory line buffer — no view, no libghostty.
final class TerminalSearchControllerTests: XCTestCase {
    private let buffer = [
        "the quick brown fox",
        "jumps over the lazy dog",
        "THE END",
        "error: file not found",
        "error: permission denied",
    ]

    private func make() -> TerminalSearchController {
        var c = TerminalSearchController()
        c.setLines(buffer)
        return c
    }

    // MARK: Literal matching

    func testEmptyQueryHasNoMatches() {
        var c = make()
        c.setQuery("")
        XCTAssertEqual(c.matchCount, 0)
        XCTAssertNil(c.currentIndex)
        XCTAssertNil(c.positionLabel)
    }

    func testCaseInsensitiveByDefaultFindsAllOccurrences() {
        var c = make()
        c.setQuery("the")
        // "the" (l0), "the" (l1 in "the lazy"), "THE" (l2) — case-insensitive default.
        XCTAssertEqual(c.matchCount, 3)
        XCTAssertEqual(c.matches.map(\.line), [0, 1, 2])
    }

    func testCaseSensitiveNarrows() {
        var c = make()
        c.setQuery("THE")
        c.setCaseSensitive(true)
        XCTAssertEqual(c.matchCount, 1)
        XCTAssertEqual(c.matches.first?.line, 2)
    }

    func testColumnAndLengthAreReported() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches[0].line, 3)
        XCTAssertEqual(c.matches[0].column, 0)
        XCTAssertEqual(c.matches[0].length, 5)
    }

    func testOverlappingLiteralMatchesAreAllFound() {
        var c = TerminalSearchController()
        c.setLines(["aaaa"])
        c.setQuery("aa")
        // "aa" at offsets 0,1,2 — overlapping matches advance by one.
        XCTAssertEqual(c.matchCount, 3)
        XCTAssertEqual(c.matches.map(\.column), [0, 1, 2])
    }

    // MARK: Navigation + wrap

    func testNextWrapsAround() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.currentIndex, 0)
        c.next()
        XCTAssertEqual(c.currentIndex, 1)
        c.next()
        XCTAssertEqual(c.currentIndex, 2)
        c.next()
        XCTAssertEqual(c.currentIndex, 0) // wrap
    }

    func testPreviousWrapsAround() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.currentIndex, 0)
        c.previous()
        XCTAssertEqual(c.currentIndex, 2) // wrap to last
        c.previous()
        XCTAssertEqual(c.currentIndex, 1)
    }

    func testPositionLabel() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.positionLabel?.current, 1)
        XCTAssertEqual(c.positionLabel?.total, 2)
        c.next()
        XCTAssertEqual(c.positionLabel?.current, 2)
        XCTAssertEqual(c.positionLabel?.total, 2)
    }

    func testCurrentMatchTracksIndex() {
        var c = make()
        c.setQuery("error")
        XCTAssertEqual(c.current?.line, 3)
        c.next()
        XCTAssertEqual(c.current?.line, 4)
    }

    // MARK: Recompute re-anchoring

    func testRecomputeClampsCurrentIndexWhenMatchesShrink() {
        var c = make()
        c.setQuery("error")
        c.next() // index 1 (the second "error")
        XCTAssertEqual(c.currentIndex, 1)
        // Narrowing to a query with ONE match must clamp the old index-1 into range.
        c.setQuery("permission")
        XCTAssertEqual(c.matchCount, 1)
        XCTAssertEqual(c.currentIndex, 0)
    }

    func testClearResetsQueryAndMatchesButKeepsBuffer() {
        var c = make()
        c.setQuery("the")
        XCTAssertEqual(c.matchCount, 3)
        c.clear()
        XCTAssertEqual(c.matchCount, 0)
        XCTAssertNil(c.currentIndex)
        XCTAssertTrue(c.query.isEmpty)
        // Buffer survives — reopening + querying works without re-feeding.
        c.setQuery("dog")
        XCTAssertEqual(c.matchCount, 1)
    }

    // MARK: Regex

    func testRegexMatching() {
        var c = make()
        c.setRegex(true)
        c.setQuery("error: \\w+")
        XCTAssertEqual(c.matchCount, 2)
        XCTAssertEqual(c.matches.map(\.line), [3, 4])
    }

    func testInvalidRegexYieldsNoMatchesNeverTraps() {
        var c = make()
        c.setRegex(true)
        c.setQuery("error(") // unbalanced — invalid pattern
        XCTAssertEqual(c.matchCount, 0) // validate-then-drop, no crash
        XCTAssertNil(c.currentIndex)
    }

    func testRegexAnchors() {
        var c = make()
        c.setRegex(true)
        c.setQuery("^error")
        XCTAssertEqual(c.matchCount, 2) // lines 3 & 4 start with "error"
    }

    // MARK: Navigation no-ops with no matches

    func testNavigationIsNoOpWithoutMatches() {
        var c = make()
        c.setQuery("zzzznotfound")
        XCTAssertEqual(c.matchCount, 0)
        c.next()
        XCTAssertNil(c.currentIndex)
        c.previous()
        XCTAssertNil(c.currentIndex)
    }
}
