import XCTest
@testable import RworkClientUI

/// Tests for ``CompactLayoutResolver`` — the pure **compact projection** (docs/30 §6.6) that flattens
/// the SAME canvas of intent into an ordered, swipeable page list. The phone layout must be a lossless
/// *view of the same model*: page order equals the canvas z-order (`tab.canvas.allIDs()`), so a
/// size-class flip never reorders or drops a pane.
///
/// Contract under test:
/// - `pages(for:)` order == `tab.canvas.allIDs()` (z-order), carrying each pane's kind+title.
/// - `selectedIndex(for:)` == the focused pane's index, or `0` if the focused pane is absent.
final class CompactLayoutResolverTests: XCTestCase {

    // MARK: - Fixtures

    /// A 3-pane canvas tab whose z-order is a, b, c (``Tab/canvasTab`` assigns z = array index), each
    /// pane carrying a distinct kind+title so the projection's payload is checkable.
    private func threePaneTab(focused: PaneID, a: PaneID, b: PaneID, c: PaneID) -> Tab {
        Tab.canvasTab(name: "Work", panes: [
            (a, PaneSpec(kind: .terminal, title: "Shell")),
            (b, PaneSpec(kind: .claudeCode, title: "Claude")),
            (c, PaneSpec(kind: .remoteGUI, title: "Screen")),
        ], focused: focused)
    }

    // MARK: - pages(): z-order, with payload

    func testPagesAreZOrderWithPayload() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let tab = threePaneTab(focused: a, a: a, b: b, c: c)

        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.map(\.id), [a, b, c], "page order == canvas.allIDs() z-order")
        XCTAssertEqual(pages.map(\.id), tab.canvas.allIDs(), "page order tracks the canvas z-order exactly")

        XCTAssertEqual(pages.map(\.kind), [.terminal, .claudeCode, .remoteGUI], "each page carries its pane kind")
        XCTAssertEqual(pages.map(\.title), ["Shell", "Claude", "Screen"], "each page carries its pane title")
    }

    func testSinglePaneTabHasOnePage() {
        let only = PaneID()
        let tab = Tab.canvasTab(name: "Solo", panes: [(only, PaneSpec(kind: .terminal, title: "Term"))])

        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, only)
        XCTAssertEqual(pages.first?.title, "Term")
    }

    /// `Tab.make` produces a one-page compact projection consistent with its single pane.
    func testMakeTabHasSinglePage() {
        let tab = Tab.make(kind: .terminal, title: "New")
        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, tab.focusedPane, "the single page is the focused pane")
        XCTAssertEqual(pages.first?.kind, .terminal)
        XCTAssertEqual(pages.first?.title, "New")
    }

    // MARK: - selectedIndex(): focused pane's position

    func testSelectedIndexTracksFocusedPane() {
        let a = PaneID(), b = PaneID(), c = PaneID()

        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threePaneTab(focused: a, a: a, b: b, c: c)), 0)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threePaneTab(focused: b, a: a, b: b, c: c)), 1)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threePaneTab(focused: c, a: a, b: b, c: c)), 2)
    }

    /// If the focused pane is somehow absent, selectedIndex defends with 0 (keeps the carousel on a
    /// valid page) — it does NOT return nil.
    func testSelectedIndexDefaultsToZeroWhenFocusAbsent() {
        let a = PaneID(), b = PaneID(), c = PaneID(), ghost = PaneID()
        let tab = threePaneTab(focused: ghost, a: a, b: b, c: c)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: tab), 0, "absent focus → page 0 (defensive)")
    }
}
