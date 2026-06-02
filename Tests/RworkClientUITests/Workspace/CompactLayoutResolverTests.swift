import XCTest
@testable import RworkClientUI

/// Tests for ``CompactLayoutResolver`` — the pure **compact projection** (docs/22 §1.3, §2.2, §4)
/// that flattens the SAME tree of intent into an ordered, swipeable page list. The phone layout must
/// be a lossless *view of the same model*: page order equals the desktop pre-order leaf order, so a
/// size-class flip never reorders or drops a pane. (Swipe → next focus is owned end-to-end by the
/// carousel's `TabView` selection binding + `store.move`, the shipped/tested paging path — the
/// resolver no longer carries a parallel `focus(after:swipe:in:)` seam.)
///
/// Contract under test (read from `CompactLayoutResolver`):
/// - `pages(for:)` order == `tab.root.allLeafIDs()` (pre-order), carrying each leaf's kind+title.
/// - `selectedIndex(for:)` == the focused pane's index, or `0` if the focused pane is absent.
final class CompactLayoutResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func leaf(_ id: PaneID, _ kind: PaneKind = .terminal, _ title: String) -> PaneNode {
        .leaf(id, PaneSpec(kind: kind, title: title))
    }

    /// A 3-leaf tab whose pre-order leaf sequence is deliberately interleaved across a nested
    /// split so that "pre-order" is observable (not merely a flat left-to-right row):
    ///
    ///   root = horizontal [ A , vertical[ B , C ] ]
    ///   pre-order leaves = A, B, C
    ///
    /// Each leaf carries a distinct kind+title so the projection's payload is checkable.
    private func threeLeafTab(focused: PaneID, a: PaneID, b: PaneID, c: PaneID) -> Tab {
        let inner = PaneNode.split(.vertical, children: [
            leaf(b, .claudeCode, "Claude"),
            leaf(c, .remoteGUI, "Screen"),
        ], fractions: [0.5, 0.5])
        let root = PaneNode.split(.horizontal, children: [
            leaf(a, .terminal, "Shell"),
            inner,
        ], fractions: [0.5, 0.5])
        return Tab(name: "Work", root: root, focusedPane: focused, zoomedPane: nil)
    }

    // MARK: - pages(): pre-order, with payload

    /// Pages are emitted in pre-order leaf order, each carrying the leaf's id, kind, and title.
    func testPagesArePreOrderLeavesWithPayload() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let tab = threeLeafTab(focused: a, a: a, b: b, c: c)

        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.map(\.id), [a, b, c], "page order == root.allLeafIDs() pre-order")
        XCTAssertEqual(pages.map(\.id), tab.root.allLeafIDs(), "page order tracks the tree's pre-order exactly")

        XCTAssertEqual(pages.map(\.kind), [.terminal, .claudeCode, .remoteGUI], "each page carries its leaf kind")
        XCTAssertEqual(pages.map(\.title), ["Shell", "Claude", "Screen"], "each page carries its leaf title")
    }

    /// A single-leaf tab projects to exactly one page.
    func testSingleLeafTabHasOnePage() {
        let only = PaneID()
        let tab = Tab(name: "Solo", root: leaf(only, .terminal, "Term"), focusedPane: only)

        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, only)
        XCTAssertEqual(pages.first?.title, "Term")
    }

    /// `Tab.make` produces a one-page compact projection consistent with its single leaf.
    func testMakeTabHasSinglePage() {
        let tab = Tab.make(kind: .terminal, title: "New")
        let pages = CompactLayoutResolver.pages(for: tab)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.id, tab.focusedPane, "the single page is the focused leaf")
        XCTAssertEqual(pages.first?.kind, .terminal)
        XCTAssertEqual(pages.first?.title, "New")
    }

    // MARK: - selectedIndex(): focused pane's position

    /// selectedIndex returns the pre-order index of the focused pane.
    func testSelectedIndexTracksFocusedPane() {
        let a = PaneID(), b = PaneID(), c = PaneID()

        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threeLeafTab(focused: a, a: a, b: b, c: c)), 0)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threeLeafTab(focused: b, a: a, b: b, c: c)), 1)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: threeLeafTab(focused: c, a: a, b: b, c: c)), 2)
    }

    /// If the focused pane is somehow absent from the tree, selectedIndex defends with 0 (keeps
    /// the carousel on a valid page rather than out of bounds) — it does NOT return nil.
    func testSelectedIndexDefaultsToZeroWhenFocusAbsent() {
        let a = PaneID(), b = PaneID(), c = PaneID(), ghost = PaneID()
        let tab = threeLeafTab(focused: ghost, a: a, b: b, c: c)
        XCTAssertEqual(CompactLayoutResolver.selectedIndex(for: tab), 0, "absent focus → page 0 (defensive)")
    }
}
