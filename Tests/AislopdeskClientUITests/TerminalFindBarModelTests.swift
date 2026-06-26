// TerminalFindBarModelTests — E5 / WI-3. Pins the in-pane find bar's view-model (``TerminalFindBarModel``):
// the driver over the PURE ``TerminalSearchController`` (count / N-of-M / next-prev-wrap) + the libghostty
// `search:` / `navigate_search:` / `end_search` passthrough. The model is HEADLESS — its only renderer touch
// is `surface as? TerminalSurfaceActions`, which a pure in-memory ``FakeSearchSurface`` satisfies (NO real
// `GhosttySurface` / VideoToolbox / Metal — the hang-safety rule; this mirrors the existing
// `CapturingSurface`/`RecordingSurface` fakes in `TerminalViewModelTests`).
//
// Every case FAILS on the un-fixed tree (the model did not exist before WI-3) and asserts an observable state
// transition (visibility / query / flags / `N of M` / the fired bind-action strings) against expected values,
// never against the output's own derivation.

#if canImport(SwiftUI)
import AislopdeskTerminal
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class TerminalFindBarModelTests: XCTestCase {
    /// A pure in-memory terminal surface: returns a canned scrollback mirror for `searchScrollbackLines()` and
    /// RECORDS the libghostty bind-action strings (`search:…` / `navigate_search:…` / `end_search`) the find
    /// bar fires, so the driver is pinned without a real renderer. Hang-safe (no SCStream/VT/Metal).
    private final class FakeSearchSurface: TerminalSurface, TerminalSurfaceActions, @unchecked Sendable {
        var lines: [String]
        private(set) var actions: [String] = []
        var onWrite: ((Data) -> Void)?

        init(lines: [String]) { self.lines = lines }

        // TerminalSurface
        func feed(_: Data) {}
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}

        // TerminalSurfaceActions
        func hasSelection() -> Bool { false }
        func readSelection() -> String? { nil }
        func performBindingAction(_ action: String) -> Bool {
            actions.append(action)
            return true
        }

        func scrollbackTextLines() -> [String] { lines }
    }

    /// Build a find-bar model bound to a headless ``TerminalViewModel`` fed by a fake surface, run `body`, and
    /// keep the (weakly-held) vm + surface alive across it (the model holds the vm weakly; the vm holds the
    /// surface weakly).
    private func withBar(
        lines: [String],
        _ body: (_ bar: TerminalFindBarModel, _ surface: FakeSearchSurface) -> Void,
    ) {
        let surface = FakeSearchSurface(lines: lines)
        let vm = TerminalViewModel(surface: surface)
        let bar = TerminalFindBarModel()
        bar.attach(vm)
        body(bar, surface)
        withExtendedLifetime((vm, surface)) {}
    }

    /// ES-E5-1/2: `open()` shows the bar; typing live-counts every match over the snapshot mirror (`N of M`).
    func testOpenShowsBarAndCountsMatches() {
        withBar(lines: ["read the docs here", "no hits", "more docs and docs"]) { bar, _ in
            XCTAssertFalse(bar.visible)
            bar.open()
            XCTAssertTrue(bar.visible)

            bar.setQuery("docs")
            XCTAssertEqual(bar.controller.matchCount, 3) // line0 ×1 + line2 ×2
            XCTAssertEqual(bar.controller.positionLabel?.current, 1)
            XCTAssertEqual(bar.controller.positionLabel?.total, 3)
        }
    }

    /// ES-E5-3: ↩/⌘G next + ⇧↩/⇧⌘G prev advance + wrap the selection AND fire the libghostty nav bind-actions.
    func testNextPreviousWrapAndFireSurfaceNav() {
        withBar(lines: ["docs", "docs", "docs"]) { bar, surface in
            bar.open()
            bar.setQuery("docs") // 3 matches; current = 1
            XCTAssertTrue(surface.actions.contains("search:docs"))

            bar.next()
            XCTAssertEqual(bar.controller.positionLabel?.current, 2)
            bar.next()
            bar.next() // wraps past the last → back to 1
            XCTAssertEqual(bar.controller.positionLabel?.current, 1)
            bar.previous() // wraps past the first → last (3)
            XCTAssertEqual(bar.controller.positionLabel?.current, 3)

            XCTAssertTrue(surface.actions.contains("navigate_search:next"))
            XCTAssertTrue(surface.actions.contains("navigate_search:prev"))
        }
    }

    /// ES-E5-3 (find-next-opens-find): ⌘G with the bar closed OPENS it (faithful otty behaviour).
    func testNextOpensBarWhenClosed() {
        withBar(lines: ["docs"]) { bar, _ in
            XCTAssertFalse(bar.visible)
            bar.next()
            XCTAssertTrue(bar.visible)
        }
    }

    /// ES-E5-3 (Esc/×): close clears the query + matches, hides the bar, and ENDS the surface search (drops the
    /// in-buffer highlights).
    func testCloseClearsQueryHidesBarAndEndsSurfaceSearch() {
        withBar(lines: ["docs"]) { bar, surface in
            bar.open()
            bar.setQuery("docs")
            XCTAssertFalse(bar.controller.query.isEmpty)

            bar.close()
            XCTAssertFalse(bar.visible)
            XCTAssertEqual(bar.controller.query, "")
            XCTAssertNil(bar.controller.positionLabel)
            XCTAssertTrue(surface.actions.contains("end_search"))
        }
    }

    /// ES-E5-4 (`Aa`): the case toggle flips the flag, refreshes the mirror, and narrows the match set.
    func testCaseToggleNarrowsMatches() {
        withBar(lines: ["DOCS docs Docs"]) { bar, _ in
            bar.open()
            bar.setQuery("docs")
            XCTAssertEqual(bar.controller.matchCount, 3) // case-insensitive default

            bar.toggleCaseSensitive()
            XCTAssertTrue(bar.controller.caseSensitive)
            XCTAssertEqual(bar.controller.matchCount, 1) // only the exact "docs"
        }
    }

    /// ES-E5-4 (`.*`): the regex toggle flips the flag and switches literal → ICU pattern matching.
    func testRegexToggleSwitchesToPatternMatching() {
        withBar(lines: ["a1 b2 c3"]) { bar, _ in
            bar.open()
            bar.setQuery("[0-9]")
            XCTAssertEqual(bar.controller.matchCount, 0, "literal mode finds no '[0-9]' substring")

            bar.toggleRegex()
            XCTAssertTrue(bar.controller.isRegex)
            XCTAssertEqual(bar.controller.matchCount, 3, "regex mode matches the three digits")
        }
    }
}
#endif
