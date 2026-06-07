import XCTest
import CoreGraphics
@testable import RworkClientUI

/// Pins the **command-routing** contract (docs/30 §7): the one tested `apply(_:to:)` free function
/// that every keyboard surface — the macOS menu-bar ``WorkspaceCommands``, the iPad hardware-keyboard
/// HUD, and the compact on-screen affordances — funnels through. Each `WorkspaceCommand` case must
/// land on the expected ``WorkspaceStore`` mutation, observable through the store's public surface
/// (the tree of intent + the `FakePaneSession`-backed registry).
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (docs/22 §0,
/// §8) so it exercises the command → mutation chain **without ever building a `RworkClient` or a
/// `HostServer`** (the latter deadlocks the pool). No view is constructed: `apply(_:to:)` is the pure
/// seam under test, identical to what a `Button` action in ``WorkspaceCommands`` invokes.
@MainActor
final class CommandRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(
            restoring: restoring,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2
        )
    }

    /// The active tab's pane ids in z-order, or `[]` when there is no active tab.
    private func paneIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.activeTab?.canvas.allIDs() ?? []
    }

    /// Reports a left/right SolvedLayout so geometric focus moves resolve: `left` fills the left half,
    /// `right` the right half (exactly as the canvas view does after solving, docs/30 §6.2).
    private func reportTwoPaneLayout(_ store: WorkspaceStore, left: PaneID, right: PaneID) {
        store.updateSolvedLayout(SolvedLayout(
            frames: [
                left:  CGRect(x: 0,   y: 0, width: 100, height: 100),
                right: CGRect(x: 100, y: 0, width: 100, height: 100),
            ]
        ))
    }

    // MARK: - New pane / tidy

    /// `apply(.newPane)` adds a pane to the canvas, grows the pane count by one, and focuses the new pane.
    func testApplyNewPaneGrowsPaneCountAndFocusesNewPane() {
        let store = makeStore()
        XCTAssertEqual(paneIDs(store).count, 1, "default workspace = one pane")
        let original = store.activeTab!.focusedPane

        apply(.newPane, to: store)

        let ids = paneIDs(store)
        XCTAssertEqual(ids.count, 2, "newPane adds exactly one pane")
        XCTAssertEqual(store.allSessions.count, 2, "reconcile materialized the new pane's session")
        let focused = store.activeTab!.focusedPane
        XCTAssertNotEqual(focused, original, "focus moved to the newly created pane")
        XCTAssertTrue(ids.contains(focused), "the focused pane is on the canvas")
    }

    /// `apply(.tidy)` packs the canvas into a non-overlapping grid (pane count + sessions unchanged).
    func testApplyTidyArrangesWithoutChangingPaneSet() {
        let store = makeStore()
        apply(.newPane, to: store)
        apply(.newPane, to: store)                          // three panes
        XCTAssertEqual(paneIDs(store).count, 3)

        apply(.tidy, to: store)

        XCTAssertEqual(paneIDs(store).count, 3, "tidy never changes the pane set")
        XCTAssertEqual(store.allSessions.count, 3, "tidy is a registry no-op")
        // No two panes overlap after tidy.
        let frames = store.activeTab!.canvas.items.map(\.frame)
        for i in frames.indices {
            for j in (i + 1)..<frames.count {
                let inter = frames[i].intersection(frames[j])
                XCTAssertTrue(inter.isNull || inter.isEmpty, "tidied panes must not overlap")
            }
        }
    }

    /// `apply(.centerFocusedPane)` only moves the camera (no pane-set / focus change).
    func testApplyCenterFocusedPaneMovesOnlyCamera() {
        let store = makeStore()
        apply(.newPane, to: store)
        let focused = store.activeTab!.focusedPane
        let panesBefore = paneIDs(store)

        apply(.centerFocusedPane, to: store)

        XCTAssertEqual(paneIDs(store), panesBefore, "center never changes the pane set")
        XCTAssertEqual(store.activeTab!.focusedPane, focused, "center never changes focus")
    }

    // MARK: - Close pane

    /// `apply(.closePane)` removes the focused pane from a multi-pane tab and re-points focus.
    func testApplyClosePaneRemovesFocusedPane() {
        let store = makeStore()
        apply(.newPane, to: store)                          // two panes, the new one focused
        XCTAssertEqual(paneIDs(store).count, 2)
        let closing = store.activeTab!.focusedPane

        apply(.closePane, to: store)

        let ids = paneIDs(store)
        XCTAssertEqual(ids.count, 1, "closePane removed the focused pane")
        XCTAssertFalse(ids.contains(closing), "the closed pane is gone")
        XCTAssertEqual(store.activeTab!.focusedPane, ids[0], "focus re-pointed to the survivor")
    }

    // MARK: - Tabs: lifecycle

    func testApplyNewTabAddsAndActivatesTab() {
        let store = makeStore()
        XCTAssertEqual(store.workspace.tabs.count, 1)
        let firstTab = store.activeTab!.id

        apply(.newTab, to: store)

        XCTAssertEqual(store.workspace.tabs.count, 2, "newTab appended a tab")
        XCTAssertNotEqual(store.activeTab!.id, firstTab, "the new tab is active")
    }

    func testApplyCloseTabRemovesActiveTab() {
        let store = makeStore()
        apply(.newTab, to: store)
        XCTAssertEqual(store.workspace.tabs.count, 2)
        let active = store.activeTab!.id

        apply(.closeTab, to: store)

        XCTAssertEqual(store.workspace.tabs.count, 1, "closeTab removed the active tab")
        XCTAssertNil(store.workspace.tabs.first { $0.id == active }, "the closed tab is gone")
    }

    // MARK: - Tabs: navigation

    func testApplyNextAndPrevTabAdvanceWithWrap() {
        let store = makeStore()
        apply(.newTab, to: store)
        apply(.newTab, to: store)
        let ids = store.workspace.tabs.map(\.id)
        XCTAssertEqual(store.workspace.activeTabID, ids[2])

        apply(.nextTab, to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[0], "next from last wraps to first")

        apply(.prevTab, to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[2], "prev from first wraps to last")
    }

    func testApplySelectTabByPosition() {
        let store = makeStore()
        apply(.newTab, to: store)
        apply(.newTab, to: store)
        let ids = store.workspace.tabs.map(\.id)

        apply(.selectTab(1), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[0], "selectTab(1) = first tab")

        apply(.selectTab(2), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[1], "selectTab(2) = second tab")

        apply(.selectTab(9), to: store)
        XCTAssertEqual(store.workspace.activeTabID, ids[2], "selectTab(9) = last tab (macOS convention)")
    }

    // MARK: - Focus: geometric

    func testApplyFocusDirectionMovesGeometrically() {
        let store = makeStore()
        apply(.newPane, to: store)                          // two panes
        let ids = paneIDs(store)                            // z-order: [original, new]
        let left = ids[0], right = ids[1]
        reportTwoPaneLayout(store, left: left, right: right)

        store.focus(left)
        XCTAssertEqual(store.activeTab!.focusedPane, left)

        apply(.focus(.right), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, right, "focus(.right) lands on the right pane")

        apply(.focus(.left), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, left, "focus(.left) lands back on the left pane")
    }

    func testApplyFocusDirectionNoopWithoutSolvedLayout() {
        let store = makeStore()
        apply(.newPane, to: store)
        let focusedBefore = store.activeTab!.focusedPane

        apply(.focus(.left), to: store)                     // no updateSolvedLayout called

        XCTAssertEqual(store.activeTab!.focusedPane, focusedBefore, "no layout ⇒ no directional move")
    }

    // MARK: - Focus: cycle

    func testApplyCycleFocusWrapsThroughPanes() {
        let store = makeStore()
        apply(.newPane, to: store)
        let ids = paneIDs(store)                            // [a, b]
        let a = ids[0], b = ids[1]
        store.focus(a)

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, b, "cycle forward a → b")

        apply(.cycleFocus(forward: true), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, a, "cycle forward wraps b → a")

        apply(.cycleFocus(forward: false), to: store)
        XCTAssertEqual(store.activeTab!.focusedPane, b, "cycle backward wraps a → b")
    }

    // MARK: - Maximize

    func testApplyToggleZoomTogglesMaximizedPane() {
        let store = makeStore()
        let focused = store.activeTab!.focusedPane
        XCTAssertNil(store.activeTab!.maximizedPane, "no maximize initially")

        apply(.toggleZoom, to: store)
        XCTAssertEqual(store.activeTab!.maximizedPane, focused, "toggleZoom maximized the focused pane")

        apply(.toggleZoom, to: store)
        XCTAssertNil(store.activeTab!.maximizedPane, "toggleZoom again cleared the maximize")
    }

    // MARK: - Rename (command-layer no-op for the tree)

    /// `apply(.renameTab)` does not mutate the tree / focus / maximize / registry — it only nudges the
    /// inline-rename request (the field commits the value through `store.renameTab`, docs/30 §7).
    func testApplyRenameTabDoesNotMutateTreeOrRegistry() {
        let store = makeStore()
        let before = store.workspace
        let sessionsBefore = store.allSessions.count

        apply(.renameTab, to: store)

        XCTAssertEqual(store.workspace, before, "renameTab command must not mutate the tree")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renameTab command must not touch the registry")
    }

    // MARK: - No-target safety

    func testCommandsAreNoopWithNoActiveTab() {
        let store = makeStore()
        apply(.closeTab, to: store)
        XCTAssertNil(store.activeTab, "workspace is now empty")

        // These all read the (absent) active tab / focused pane and must simply do nothing.
        apply(.newPane, to: store)
        apply(.tidy, to: store)
        apply(.centerFocusedPane, to: store)
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
