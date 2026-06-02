import XCTest
import CoreGraphics
@testable import RworkClientUI

/// Pins the **command-routing** contract (docs/22 §5): the one tested `apply(_:to:)` free function
/// that every keyboard surface — the macOS menu-bar ``WorkspaceCommands``, the iPad hardware-keyboard
/// HUD, and the compact on-screen affordances — funnels through. Each `WorkspaceCommand` case must
/// land on the expected ``WorkspaceStore`` mutation, observable through the store's public surface
/// (the tree of intent + the `FakePaneSession`-backed registry).
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (docs/22 §0,
/// §8) so it exercises the command → mutation chain **without ever building a `RworkClient` or a
/// `HostServer`** (the latter deadlocks the pool). No view is constructed: `apply(_:to:)` is the pure
/// seam under test, identical to what a `Button` action in ``WorkspaceCommands`` invokes.
///
/// Asserted, one case per command:
/// - `.splitHorizontal` / `.splitVertical` — the active tab's leaf count grows by one, along the
///   requested axis, and the new leaf becomes focused.
/// - `.closePane` — the focused leaf is removed (count shrinks) and focus re-points.
/// - `.newTab` — a tab is appended and activated.
/// - `.closeTab` — the active tab is removed.
/// - `.nextTab` / `.prevTab` — the active tab advances with wrap.
/// - `.selectTab(n)` — the 1-based position is activated (⌘9 = last).
/// - `.focus(dir)` — focus moves geometrically against the reported `SolvedLayout`.
/// - `.cycleFocus(forward:)` — focus cycles through the pre-order leaf list with wrap.
/// - `.toggleZoom` — `zoomedPane` toggles on the focused pane.
/// - `.renameTab` — a deliberate command-layer no-op (the inline field commits the value, not the
///   command).
///
/// `WorkspaceStore` and `apply(_:to:)` are `@MainActor`, so the whole suite is `@MainActor`. Every
/// op here is synchronous (no close-teardown awaiting is needed — the *tree* assertions hold the
/// instant `apply` returns).
@MainActor
final class CommandRoutingTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a store with the ``FakePaneSession`` seam (NEVER a real client/host). `restoring` pins a
    /// known tree; default is the one-terminal-tab default workspace.
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(
            restoring: restoring,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2
        )
    }

    /// The active tab's leaf ids in pre-order, or `[]` when there is no active tab.
    private func leafIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.activeTab?.root.allLeafIDs() ?? []
    }

    /// Reports a left/right SolvedLayout for `pair` (the two leaves) so geometric focus moves resolve:
    /// `pair.0` fills the left half, `pair.1` the right half. The store caches it via
    /// `updateSolvedLayout`, exactly as the view does after solving (docs/22 §2.1).
    private func reportTwoPaneLayout(_ store: WorkspaceStore, left: PaneID, right: PaneID) {
        let solved = SolvedLayout(
            frames: [
                left:  CGRect(x: 0,   y: 0, width: 100, height: 100),
                right: CGRect(x: 100, y: 0, width: 100, height: 100),
            ],
            dividers: []
        )
        store.updateSolvedLayout(solved)
    }

    // MARK: - Splits

    /// `apply(.splitHorizontal)` splits the focused leaf side-by-side: the active tab gains one leaf
    /// and the new leaf becomes focused (the store focuses the freshly created sibling).
    func testApplySplitHorizontalGrowsLeafCountAndFocusesNewLeaf() {
        let store = makeStore()
        XCTAssertEqual(leafIDs(store).count, 1, "default workspace = one leaf")
        let original = store.activeTab!.focusedPane

        apply(.splitHorizontal, to: store)

        let leaves = leafIDs(store)
        XCTAssertEqual(leaves.count, 2, "splitHorizontal adds exactly one leaf")
        XCTAssertEqual(store.allSessions.count, 2, "reconcile materialized the new leaf's session")
        let focused = store.activeTab!.focusedPane
        XCTAssertNotEqual(focused, original, "focus moved to the newly created leaf")
        XCTAssertTrue(leaves.contains(focused), "the focused leaf is in the tree")

        // The split's axis is horizontal (side-by-side children).
        guard case let .split(axis, _, _) = store.activeTab!.root else {
            return XCTFail("root should now be a split")
        }
        XCTAssertEqual(axis, .horizontal, "splitHorizontal produced a horizontal split")
    }

    /// `apply(.splitVertical)` splits the focused leaf stacked top/bottom (vertical axis).
    func testApplySplitVerticalGrowsLeafCountAndUsesVerticalAxis() {
        let store = makeStore()

        apply(.splitVertical, to: store)

        XCTAssertEqual(leafIDs(store).count, 2, "splitVertical adds exactly one leaf")
        guard case let .split(axis, _, _) = store.activeTab!.root else {
            return XCTFail("root should now be a split")
        }
        XCTAssertEqual(axis, .vertical, "splitVertical produced a vertical split")
    }

    // MARK: - Close pane

    /// `apply(.closePane)` removes the focused leaf from a multi-leaf tab and re-points focus to the
    /// survivor (the tab itself is NOT closed while another leaf remains).
    func testApplyClosePaneRemovesFocusedLeaf() {
        let store = makeStore()
        apply(.splitHorizontal, to: store)            // now two leaves, the new one focused
        XCTAssertEqual(leafIDs(store).count, 2)
        let closing = store.activeTab!.focusedPane

        apply(.closePane, to: store)

        let leaves = leafIDs(store)
        XCTAssertEqual(leaves.count, 1, "closePane removed the focused leaf")
        XCTAssertFalse(leaves.contains(closing), "the closed leaf is gone from the tree")
        XCTAssertEqual(store.activeTab!.focusedPane, leaves[0], "focus re-pointed to the survivor")
    }

    // MARK: - Tabs: lifecycle

    /// `apply(.newTab)` appends a fresh tab and activates it.
    func testApplyNewTabAddsAndActivatesTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspace.tabs.count, 1)
        let firstTab = store.activeTab!.id

        apply(.newTab, to: store)

        XCTAssertEqual(store.workspace.tabs.count, 2, "newTab appended a tab")
        XCTAssertNotEqual(store.activeTab!.id, firstTab, "the new tab is active")
    }

    /// `apply(.closeTab)` removes the active tab (a neighbour becomes active).
    func testApplyCloseTabRemovesActiveTab() {
        let store = makeStore()
        apply(.newTab, to: store)                       // two tabs; the second active
        XCTAssertEqual(store.workspace.tabs.count, 2)
        let active = store.activeTab!.id

        apply(.closeTab, to: store)

        XCTAssertEqual(store.workspace.tabs.count, 1, "closeTab removed the active tab")
        XCTAssertNil(store.workspace.tabs.first { $0.id == active }, "the closed tab is gone")
    }

    // MARK: - Tabs: navigation

    /// `apply(.nextTab)` / `apply(.prevTab)` advance the active tab with wrap.
    func testApplyNextAndPrevTabAdvanceWithWrap() {
        let store = makeStore()
        apply(.newTab, to: store)
        apply(.newTab, to: store)                       // three tabs; the third active
        let ids = store.workspace.tabs.map(\.id)
        XCTAssertEqual(store.workspace.activeTabID, ids[2])

        apply(.nextTab, to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[0], "next from last wraps to first")

        apply(.prevTab, to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[2], "prev from first wraps to last")
    }

    /// `apply(.selectTab(n))` activates the tab at the 1-based menu position; ⌘9 selects the last tab.
    func testApplySelectTabByPosition() {
        let store = makeStore()
        apply(.newTab, to: store)
        apply(.newTab, to: store)                       // three tabs
        let ids = store.workspace.tabs.map(\.id)

        apply(.selectTab(1), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[0], "selectTab(1) = first tab")

        apply(.selectTab(2), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[1], "selectTab(2) = second tab")

        apply(.selectTab(9), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[2], "selectTab(9) = last tab (macOS convention)")
    }

    // MARK: - Focus: geometric

    /// `apply(.focus(.right))` moves focus to the geometric right neighbour, resolved against the
    /// reported `SolvedLayout` (and `.focus(.left)` moves back).
    func testApplyFocusDirectionMovesGeometrically() {
        let store = makeStore()
        apply(.splitHorizontal, to: store)              // two side-by-side leaves
        let leaves = leafIDs(store)                      // pre-order: [left, right]
        let left = leaves[0], right = leaves[1]
        reportTwoPaneLayout(store, left: left, right: right)

        // Start focused on the left pane.
        store.focus(left)
        XCTAssertEqual(store.activeTab!.focusedPane, left)

        apply(.focus(.right), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, right, "focus(.right) lands on the right pane")

        apply(.focus(.left), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, left, "focus(.left) lands back on the left pane")
    }

    /// `apply(.focus(.right))` is a graceful no-op when no layout has been reported (the directional
    /// resolver has no rects to reason about — docs/22 §2.1).
    func testApplyFocusDirectionNoopWithoutSolvedLayout() {
        let store = makeStore()
        apply(.splitHorizontal, to: store)
        let focusedBefore = store.activeTab!.focusedPane

        apply(.focus(.left), to: store)                  // no updateSolvedLayout called

        XCTAssertEqual(store.activeTab!.focusedPane, focusedBefore, "no layout ⇒ no directional move")
    }

    // MARK: - Focus: cycle

    /// `apply(.cycleFocus(forward:))` cycles through the pre-order leaf list with wrap, even without a
    /// solved layout (the `.next`/`.previous` path falls back to the tree's pre-order cycle).
    func testApplyCycleFocusWrapsThroughLeaves() {
        let store = makeStore()
        apply(.splitHorizontal, to: store)
        let leaves = leafIDs(store)                      // [a, b]
        let a = leaves[0], b = leaves[1]
        store.focus(a)

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, b, "cycle forward a → b")

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, a, "cycle forward wraps b → a")

        apply(.cycleFocus(forward: false), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, b, "cycle backward wraps a → b")
    }

    // MARK: - Zoom

    /// `apply(.toggleZoom)` sets `zoomedPane` to the focused pane, then clears it on a second apply.
    func testApplyToggleZoomTogglesZoomedPane() {
        let store = makeStore()
        let focused = store.activeTab!.focusedPane
        XCTAssertNil(store.activeTab!.zoomedPane, "no zoom initially")

        apply(.toggleZoom, to: store)
        XCTAssertEqual(store.activeTab!.zoomedPane, focused, "toggleZoom zoomed the focused pane")

        apply(.toggleZoom, to: store)
        XCTAssertNil(store.activeTab!.zoomedPane, "toggleZoom again cleared the zoom")
    }

    // MARK: - Rename (command-layer no-op)

    /// `apply(.renameTab)` is a deliberate no-op at the command layer — the inline rename field commits
    /// the value through `store.renameTab(_:_:)`, not through the command (docs/22 §5). It must not
    /// mutate the tree, focus, zoom, or the registry.
    func testApplyRenameTabIsCommandLayerNoop() {
        let store = makeStore()
        let before = store.workspace
        let sessionsBefore = store.allSessions.count

        apply(.renameTab, to: store)

        XCTAssertEqual(store.workspace, before, "renameTab command must not mutate the tree")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renameTab command must not touch the registry")
    }

    // MARK: - No-target safety

    /// Commands that need an active tab / focused pane are a graceful no-op when there is none — e.g.
    /// after closing the only tab. None must trap (docs/22 §5: a command with no valid target is a
    /// no-op).
    func testCommandsAreNoopWithNoActiveTab() {
        // Close the only tab to reach the empty-workspace state.
        let store = makeStore()
        apply(.closeTab, to: store)
        XCTAssertNil(store.activeTab, "workspace is now empty")

        // These all read the (absent) active tab / focused pane and must simply do nothing.
        apply(.splitHorizontal, to: store)
        apply(.splitVertical, to: store)
        apply(.closePane, to: store)
        apply(.closeTab, to: store)
        apply(.toggleZoom, to: store)
        apply(.focus(.right), to: store)
        apply(.cycleFocus(forward: true), to: store)
        apply(.renameTab, to: store)

        XCTAssertNil(store.activeTab, "still empty — no command resurrected a tab")
        XCTAssertTrue(store.allSessions.isEmpty, "no sessions materialized from no-op commands")
    }
}
