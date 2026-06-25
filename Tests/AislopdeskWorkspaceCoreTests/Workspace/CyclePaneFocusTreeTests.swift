import XCTest
@testable import AislopdeskWorkspaceCore

/// E1 WI-2 (ES-E1-2): pins ``WorkspaceStore/cyclePaneFocusTree(forward:)`` — the ⌘]/⌘[ "focus next/
/// previous pane" walk over the ACTIVE TAB's panes in pre-order DFS, wrapping at the ends, a no-op below
/// two panes. Distinct from ⌘⇧]/⌘⇧[ tab cycling (E1 re-scopes those chords; this is the pane-level walk).
///
/// The pure ``WorkspaceStore/paneCycleTreeTarget(forward:)`` resolver is asserted in isolation (the wrap /
/// no-op guard, mirroring `recentPaneTarget` / `inGroupCycleTarget`), then the public mutating
/// ``WorkspaceStore/cyclePaneFocusTree(forward:)`` is driven end-to-end so the resolved target actually
/// becomes the active pane. The store is `.tree`-live and backed by the `FakePaneSession` seam — no real
/// `AislopdeskClient` / `HostServer`, no SwiftUI view.
@MainActor
final class CyclePaneFocusTreeTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree`, backed by the `FakePaneSession` seam.
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// A single-tab, single-session workspace whose tab tiles `paneIDs` left-to-right in ONE horizontal
    /// split (so `Tab.allPaneIDs()` is exactly `paneIDs`, in that DFS order), or a bare `.leaf` when a
    /// single pane is requested (a `.split` invariant-requires ≥ 2 children). `active` is the active pane.
    private func tiledWorkspace(_ paneIDs: [PaneID], active: PaneID) -> TreeWorkspace {
        let root: SplitNode
        if paneIDs.count == 1 {
            root = .leaf(paneIDs[0])
        } else {
            let children = paneIDs.map { WeightedChild(weight: .flex(1), node: .leaf($0)) }
            root = .split(id: SplitNodeID(), axis: .horizontal, children: children)
        }
        let tab = Tab(root: root, activePane: active)
        var specs: [PaneID: PaneSpec] = [:]
        for id in paneIDs { specs[id] = PaneSpec(kind: .terminal, title: "Terminal") }
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    /// The active tab's active pane.
    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    // MARK: - Forward walks DFS order and wraps

    /// `cyclePaneFocusTree(forward: true)` steps to the NEXT pane in DFS order on each call and WRAPS from
    /// the last pane back to the first.
    func testCycleForwardWalksDFSAndWraps() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeTreeStore(restoringTree: tiledWorkspace([a, b, c], active: a))
        XCTAssertEqual(activePane(store), a, "starts on the first pane")

        store.cyclePaneFocusTree(forward: true)
        XCTAssertEqual(activePane(store), b, "a → b")
        store.cyclePaneFocusTree(forward: true)
        XCTAssertEqual(activePane(store), c, "b → c")
        store.cyclePaneFocusTree(forward: true)
        XCTAssertEqual(activePane(store), a, "c wraps → a")
    }

    // MARK: - Backward reverses DFS order and wraps

    /// `cyclePaneFocusTree(forward: false)` steps to the PREVIOUS pane in DFS order and WRAPS from the first
    /// pane back to the last.
    func testCycleBackwardReversesAndWraps() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeTreeStore(restoringTree: tiledWorkspace([a, b, c], active: a))

        store.cyclePaneFocusTree(forward: false)
        XCTAssertEqual(activePane(store), c, "a wraps → c")
        store.cyclePaneFocusTree(forward: false)
        XCTAssertEqual(activePane(store), b, "c → b")
        store.cyclePaneFocusTree(forward: false)
        XCTAssertEqual(activePane(store), a, "b → a")
    }

    // MARK: - Pure resolver (wrap + no-op guard) in isolation

    /// The pure ``WorkspaceStore/paneCycleTreeTarget(forward:)`` resolves the wrap WITHOUT moving focus, so
    /// the `count > 1` guard + the DFS ordering are testable in isolation (it returns the SAME pane is never
    /// possible here — a wrap always lands on a DIFFERENT pane, which is what makes this not a tautology).
    func testTargetResolvesWrapWithoutMovingFocus() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeTreeStore(restoringTree: tiledWorkspace([a, b, c], active: c))
        XCTAssertEqual(store.paneCycleTreeTarget(forward: true), a, "from the last pane, forward wraps to first")
        XCTAssertEqual(store.paneCycleTreeTarget(forward: false), b, "from the last pane, backward is the previous")
        XCTAssertEqual(activePane(store), c, "resolving the target is pure — focus is untouched")
    }

    // MARK: - No-op below two panes

    /// A single-pane tab cannot cycle: the resolver returns `nil` and `cyclePaneFocusTree` leaves focus put.
    func testSinglePaneTabIsNoOp() {
        let only = PaneID()
        let store = makeTreeStore(restoringTree: tiledWorkspace([only], active: only))
        XCTAssertNil(store.paneCycleTreeTarget(forward: true), "one pane → nothing to cycle to")
        XCTAssertNil(store.paneCycleTreeTarget(forward: false))

        store.cyclePaneFocusTree(forward: true)
        XCTAssertEqual(activePane(store), only, "focus unchanged on a single-pane tab")
        store.cyclePaneFocusTree(forward: false)
        XCTAssertEqual(activePane(store), only)
    }
}
