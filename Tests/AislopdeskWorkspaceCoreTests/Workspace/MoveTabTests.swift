import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Tests for ``WorkspaceTreeOps/moveTab(from:to:in:)`` — the PURE tab-reorder op (E6 plan WI-3 / Design #4)
/// behind otty's manual drag-to-reorder. It permutes the active session's `tabs` array ONLY (the leaf set
/// is unchanged ⇒ the store wrapper's reconcile is a registry no-op), clamps an out-of-range destination,
/// and keeps `activeTabIndex` pointed at the SAME tab id across the move. Each assertion fails before the
/// op exists (revert-to-confirm-fail = the static is absent → compile failure).
final class MoveTabTests: XCTestCase {
    // MARK: Fixtures

    /// A one-session workspace with `count` single-leaf tabs, the `activeIndex`-th selected. Returns the
    /// workspace + the tab ids in array order.
    private func workspace(tabCount count: Int, activeIndex: Int) -> (TreeWorkspace, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for i in 0..<count {
            let pane = PaneID()
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "T\(i)")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: activeIndex, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), tabs.map(\.id))
    }

    private func tabIDs(_ ws: TreeWorkspace) -> [TabID] {
        ws.activeSession?.tabs.map(\.id) ?? []
    }

    private func activeTabID(_ ws: TreeWorkspace) -> TabID? {
        ws.activeSession?.activeTab?.id
    }

    // MARK: - Permutation

    func testMoveFromFrontToBackPermutesOrder() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]], "moving index 0 to 2 rotates it to the end")
    }

    func testMoveFromBackToFrontPermutesOrder() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 2, to: 0, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[2], ids[0], ids[1]])
    }

    // MARK: - Selection follows the same tab id

    func testActiveSelectionFollowsTheSameTabIDAcrossTheMove() {
        // The MIDDLE tab is active; moving the FIRST tab past it must keep the middle tab selected.
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 1)
        XCTAssertEqual(activeTabID(ws), ids[1])
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        // New order: [ids1, ids2, ids0]; ids1 is now at index 0.
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(activeTabID(moved), ids[1], "the previously-active tab id stays selected")
        XCTAssertEqual(moved.activeSession?.activeTabIndex, 0, "and activeTabIndex re-points at its new slot")
    }

    func testMovingTheActiveTabKeepsItActive() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        XCTAssertEqual(activeTabID(moved), ids[0], "the moved-and-active tab stays selected at its new index")
        XCTAssertEqual(moved.activeSession?.activeTabIndex, 2)
    }

    // MARK: - Clamping / no-ops

    func testOutOfRangeDestinationClampsToLastIndex() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 99, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]], "an OOB destination clamps to the last slot")
    }

    func testNegativeDestinationClampsToFront() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 2, to: -5, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[2], ids[0], ids[1]], "a negative destination clamps to index 0")
    }

    func testOutOfRangeSourceIsANoOp() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 99, to: 0, in: ws)
        XCTAssertEqual(moved, ws, "an out-of-range source returns the workspace unchanged")
        XCTAssertEqual(tabIDs(moved), ids)
    }

    func testMoveToSameIndexIsANoOp() {
        let (ws, _) = workspace(tabCount: 3, activeIndex: 1)
        let moved = WorkspaceTreeOps.moveTab(from: 1, to: 1, in: ws)
        XCTAssertEqual(moved, ws, "a move to the same index is a no-op")
    }

    func testSingleTabSessionIsANoOp() {
        let (ws, _) = workspace(tabCount: 1, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 0, in: ws)
        XCTAssertEqual(moved, ws, "a single-tab session cannot reorder")
    }

    // MARK: - Leaf set unchanged (reconcile no-op)

    func testLeafSetIsUnchangedByTheMove() {
        let (ws, _) = workspace(tabCount: 4, activeIndex: 0)
        let before = Set(ws.allPaneIDs())
        let moved = WorkspaceTreeOps.moveTab(from: 3, to: 0, in: ws)
        XCTAssertEqual(Set(moved.allPaneIDs()), before, "moveTab adds/removes no leaf (reconcile stays a no-op)")
        XCTAssertTrue(moved.isInvariantHeld(), "the specs == leafIDs invariant survives the permutation")
    }
}
