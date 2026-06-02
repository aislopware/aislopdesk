import XCTest
@testable import RworkClientUI

/// Pins the **pure tab arithmetic** on ``Workspace`` (docs/22 §5, §8) — add / close / move /
/// select / rename, plus active-tab reselection on close and the default-workspace factory. Every
/// op returns a new `Workspace` value; no store, no client, no async.
///
/// The subtle contracts asserted here:
/// - `closing(_:)` an *active* tab reselects `min(removedIndex, count−1)` (the tab that slid into
///   the slot, clamped to last).
/// - `selecting(position:)` is 1-based, and position 9 = last tab when there are > 9 tabs.
/// - `selectingAdjacent(forward:)` wraps, and no-ops with < 2 tabs.
/// - `defaultWorkspace()` is exactly one active "Terminal" tab with one focused terminal leaf.
final class WorkspaceTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a workspace of `n` terminal tabs (named t0…t(n-1)) with the first active, returning
    /// the workspace and the ordered tab ids so tests can assert against pinned identities.
    private func makeWorkspace(_ n: Int) -> (ws: Workspace, ids: [TabID]) {
        var tabs: [Tab] = []
        for i in 0..<n {
            tabs.append(Tab.make(kind: .terminal, title: "t\(i)"))
        }
        let ws = Workspace(tabs: tabs, activeTabID: tabs.first?.id)
        return (ws, tabs.map { $0.id })
    }

    // MARK: - defaultWorkspace

    func testDefaultWorkspaceIsOneActiveTerminalTab() {
        let ws = Workspace.defaultWorkspace()
        XCTAssertEqual(ws.schemaVersion, Workspace.currentSchemaVersion)
        XCTAssertEqual(ws.schemaVersion, 1)
        XCTAssertEqual(ws.tabs.count, 1)

        let tab = ws.tabs[0]
        XCTAssertEqual(tab.name, "Terminal")
        XCTAssertEqual(ws.activeTabID, tab.id, "the single tab is active")
        XCTAssertEqual(ws.activeTab?.id, tab.id)

        // Root is a single terminal leaf, focused, not zoomed.
        XCTAssertEqual(tab.root.leafCount, 1)
        XCTAssertNil(tab.zoomedPane)
        let leafID = tab.root.allLeafIDs()[0]
        XCTAssertEqual(tab.focusedPane, leafID, "focus points at the only leaf")
        XCTAssertEqual(tab.root.spec(for: leafID)?.kind, .terminal)
    }

    // MARK: - adding

    func testAddingKindAppendsAndActivates() {
        let (ws, ids) = makeWorkspace(2)
        let result = ws.adding(kind: .claudeCode, title: "claude")

        XCTAssertEqual(result.tabs.count, 3)
        XCTAssertEqual(result.tabs[2].name, "claude")
        XCTAssertEqual(result.tabs[2].root.spec(for: result.tabs[2].root.allLeafIDs()[0])?.kind, .claudeCode)
        XCTAssertEqual(result.activeTabID, result.tabs[2].id, "the freshly added tab becomes active")
        // Original tabs preserved by identity.
        XCTAssertEqual(Array(result.tabs.prefix(2)).map { $0.id }, ids)
    }

    func testAddingPrebuiltTabAppendsAndActivates() {
        let (ws, _) = makeWorkspace(1)
        let tab = Tab.make(kind: .remoteGUI, title: "gui")
        let result = ws.adding(tab)

        XCTAssertEqual(result.tabs.count, 2)
        XCTAssertEqual(result.tabs[1].id, tab.id)
        XCTAssertEqual(result.activeTabID, tab.id)
    }

    // MARK: - selecting

    func testSelectingByIDActivatesIt() {
        let (ws, ids) = makeWorkspace(3)
        let result = ws.selecting(ids[2])
        XCTAssertEqual(result.activeTabID, ids[2])
    }

    func testSelectingAbsentIDIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        let result = ws.selecting(TabID())
        XCTAssertEqual(result, ws)
    }

    func testSelectingPositionIsOneBased() {
        let (ws, ids) = makeWorkspace(3)
        XCTAssertEqual(ws.selecting(position: 1).activeTabID, ids[0], "⌘1 = first")
        XCTAssertEqual(ws.selecting(position: 2).activeTabID, ids[1])
        XCTAssertEqual(ws.selecting(position: 3).activeTabID, ids[2])
    }

    func testSelectingPositionZeroOrOutOfRangeIsNoOp() {
        let (ws, _) = makeWorkspace(3)
        XCTAssertEqual(ws.selecting(position: 0), ws, "0 is out of the 1-based range")
        // Position 5 with only 3 tabs (and 5 != 9) is out of range.
        XCTAssertEqual(ws.selecting(position: 5), ws)
    }

    /// macOS convention: ⌘9 jumps to the LAST tab when there are more than nine tabs.
    func testSelectingPositionNineSelectsLastWhenMoreThanNineTabs() {
        let (ws, ids) = makeWorkspace(12)
        let result = ws.selecting(position: 9)
        XCTAssertEqual(result.activeTabID, ids[11], "⌘9 = last tab when >9 tabs")
    }

    /// With exactly nine (or fewer-but-≥9) tabs, ⌘9 addresses the literal 9th tab.
    func testSelectingPositionNineSelectsNinthWhenNineTabs() {
        let (ws, ids) = makeWorkspace(9)
        let result = ws.selecting(position: 9)
        XCTAssertEqual(result.activeTabID, ids[8], "⌘9 = 9th tab (index 8) when exactly 9 tabs")
    }

    // MARK: - selectingAdjacent (wraps)

    func testSelectingAdjacentForwardWraps() {
        let (ws, ids) = makeWorkspace(3) // active = ids[0]
        let one = ws.selectingAdjacent(forward: true)
        XCTAssertEqual(one.activeTabID, ids[1])
        let two = one.selectingAdjacent(forward: true)
        XCTAssertEqual(two.activeTabID, ids[2])
        let wrapped = two.selectingAdjacent(forward: true)
        XCTAssertEqual(wrapped.activeTabID, ids[0], "forward past the end wraps to first")
    }

    func testSelectingAdjacentBackwardWraps() {
        let (ws, ids) = makeWorkspace(3) // active = ids[0]
        let wrapped = ws.selectingAdjacent(forward: false)
        XCTAssertEqual(wrapped.activeTabID, ids[2], "backward past the start wraps to last")
    }

    func testSelectingAdjacentNoOpWithSingleTab() {
        let (ws, ids) = makeWorkspace(1)
        XCTAssertEqual(ws.selectingAdjacent(forward: true).activeTabID, ids[0])
        XCTAssertEqual(ws.selectingAdjacent(forward: false).activeTabID, ids[0])
    }

    // MARK: - renaming

    func testRenamingChangesNameOnly() {
        let (ws, ids) = makeWorkspace(2)
        let result = ws.renaming(ids[1], to: "renamed")
        XCTAssertEqual(result.tabs[1].name, "renamed")
        XCTAssertEqual(result.tabs[0].name, "t0", "siblings untouched")
        XCTAssertEqual(result.activeTabID, ws.activeTabID, "rename does not change selection")
    }

    func testRenamingAbsentIDIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        XCTAssertEqual(ws.renaming(TabID(), to: "x"), ws)
    }

    // MARK: - moving (onMove semantics, identity preserved)

    func testMovingReordersAndPreservesActiveByIdentity() {
        let (ws, ids) = makeWorkspace(3) // [t0, t1, t2], active t0
        // Move t0 (index 0) to the end (destination 3 in SwiftUI onMove terms).
        let result = ws.moving(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(result.tabs.map { $0.id }, [ids[1], ids[2], ids[0]])
        XCTAssertEqual(result.activeTabID, ids[0], "active tab preserved by identity across reorder")
    }

    // MARK: - closing

    func testClosingNonActiveTabKeepsActive() {
        let (ws, ids) = makeWorkspace(3) // active t0
        let result = ws.closing(ids[2])
        XCTAssertEqual(result.tabs.map { $0.id }, [ids[0], ids[1]])
        XCTAssertEqual(result.activeTabID, ids[0], "closing a non-active tab leaves the active one")
    }

    func testClosingAbsentTabIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        XCTAssertEqual(ws.closing(TabID()), ws)
    }

    /// Closing the active tab in the MIDDLE reselects the tab that slid into the slot (same index).
    func testClosingActiveMiddleTabReselectsSuccessorInSlot() {
        let (base, ids) = makeWorkspace(4)
        let ws = base.selecting(ids[1]) // active = t1 (index 1)
        let result = ws.closing(ids[1])
        XCTAssertEqual(result.tabs.map { $0.id }, [ids[0], ids[2], ids[3]])
        XCTAssertEqual(result.activeTabID, ids[2], "the tab that took the removed slot becomes active")
    }

    /// Closing the active LAST tab clamps the reselection to the new last tab.
    func testClosingActiveLastTabClampsToNewLast() {
        let (base, ids) = makeWorkspace(3)
        let ws = base.selecting(ids[2]) // active = last
        let result = ws.closing(ids[2])
        XCTAssertEqual(result.tabs.map { $0.id }, [ids[0], ids[1]])
        XCTAssertEqual(result.activeTabID, ids[1], "reselection clamps to the new last tab")
    }

    /// Closing the active FIRST tab reselects what is now the first tab (old index 1).
    func testClosingActiveFirstTabReselectsNewFirst() {
        let (ws, ids) = makeWorkspace(3) // active = t0
        let result = ws.closing(ids[0])
        XCTAssertEqual(result.tabs.map { $0.id }, [ids[1], ids[2]])
        XCTAssertEqual(result.activeTabID, ids[1], "min(removedIndex, count-1) = index 0 = new first")
    }

    /// Closing the only tab empties the workspace and clears the active id.
    func testClosingOnlyTabEmptiesWorkspace() {
        let (ws, ids) = makeWorkspace(1)
        let result = ws.closing(ids[0])
        XCTAssertTrue(result.tabs.isEmpty)
        XCTAssertNil(result.activeTabID)
        XCTAssertNil(result.activeTab)
    }

    // MARK: - lookups

    func testIndexOfAndActiveTab() {
        let (ws, ids) = makeWorkspace(3)
        XCTAssertEqual(ws.index(of: ids[1]), 1)
        XCTAssertNil(ws.index(of: TabID()))
        XCTAssertEqual(ws.activeTab?.id, ids[0])
    }

    // MARK: - active-tab delegation

    func testUpdatingActiveTabRoutesToActiveOnly() {
        let (ws, ids) = makeWorkspace(2) // active t0
        let result = ws.updatingActiveTab { $0.name = "active-renamed" }
        XCTAssertEqual(result.tabs[0].name, "active-renamed")
        XCTAssertEqual(result.tabs[1].name, "t1", "non-active tab untouched")
        // Verify it really targeted the active one by identity.
        XCTAssertEqual(result.tabs[0].id, ids[0])
    }

    func testUpdatingTabByIDTargetsThatTab() {
        let (ws, ids) = makeWorkspace(2)
        let result = ws.updatingTab(ids[1]) { $0.name = "explicit" }
        XCTAssertEqual(result.tabs[1].name, "explicit")
        XCTAssertEqual(result.tabs[0].name, "t0")
    }

    func testUpdatingTabAbsentIDIsNoOp() {
        let (ws, _) = makeWorkspace(2)
        XCTAssertEqual(ws.updatingTab(TabID()) { $0.name = "x" }, ws)
    }
}
