import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// W4 (docs/42 §"W4 — Store retarget"): pins the **DORMANT** tree-driven reconcile path the store
/// gains alongside the live canvas `reconcile()`. ``WorkspaceStore/reconcileTree()`` diffs the desired
/// leaf set `tree.allPaneIDs()` against the SAME `[PaneID: any PaneSessionHandle]` registry the canvas
/// path uses, materializing one idle handle per new leaf and tearing down orphaned ones — mirroring the
/// canvas reconcile, but driven by the new ``TreeWorkspace`` of intent.
///
/// These tests are an EXTENSION of ``WorkspaceStoreReconcileTests`` (same class) so the W4 verify
/// `swift test --filter WorkspaceStoreReconcileTests` exercises both the canvas and the tree paths. They
/// inject the spec-only `makeSession` seam with a ``FakePaneSession`` — never a `AislopdeskClient` /
/// `HostServer` — and assert against the fake's RECORDED materialize (`adopt`) / `teardown` call counts,
/// not against the reconcile's own recomputed output (no tautology).
///
/// Each store is built EMPTY-canvas so the canvas-init reconcile leaves the registry empty; the tree path
/// is then the sole driver, and a registry handle exists iff its leaf is in the tree.
extension WorkspaceStoreReconcileTests {
    // MARK: - Tree fixtures (empty-canvas store + a seeded tree)

    /// A store whose canvas is EMPTY (so the canvas-init reconcile yields an empty registry) and whose
    /// `tree` is seeded from `restoringTree`. The tree path is then the only thing that touches the
    /// registry, so a tree test can assert the registry 1:1 against `tree.allPaneIDs()` with no canvas
    /// pane confounding it. NEVER a real client/host (`FakePaneSession` seam).
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: []), focusedPane: nil),
            restoringTree: restoringTree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The set of ids the registry currently holds (via the only public window, `allSessions`).
    private func treeRegistryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map(\.id))
    }

    /// The fake handle for `id` (downcast for recorded-lifecycle accessors), or `nil`.
    private func treeFake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    /// THE tree invariant, asserted after every tree op: `Set(registry.keys) == Set(tree.allPaneIDs())`
    /// AND every materialized handle adopted its leaf id.
    private func assertTreeInvariant(
        _ store: WorkspaceStore,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let leaves = Set(store.tree.allPaneIDs())
        XCTAssertEqual(
            treeRegistryIDs(store),
            leaves,
            "registry.keys != tree.allPaneIDs() \(message)",
            file: file,
            line: line,
        )
        XCTAssertEqual(
            store.allSessions.count,
            leaves.count,
            "registry has duplicate/extra handles \(message)",
            file: file,
            line: line,
        )
        XCTAssertTrue(store.tree.isInvariantHeld(), "tree specs == leafIDs broken \(message)", file: file, line: line)
        for id in leaves {
            XCTAssertEqual(
                store.handle(for: id)?.id,
                id,
                "handle.id != its leaf id (adopt failed) \(message)",
                file: file,
                line: line,
            )
        }
    }

    // MARK: - reconcileTree materializes the seeded tree

    /// Seeding a tree and calling `reconcileTree()` materializes exactly one idle handle per leaf,
    /// adopting each leaf id — the registry now matches the tree (it started empty from the empty canvas).
    func testReconcileTreeMaterializesSeededTreeLeaves() {
        let tree = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "root"))
        let store = makeTreeStore(restoringTree: tree)

        // The empty canvas left an empty registry; the seeded tree is dormant until reconcileTree runs.
        store.reconcileTree()

        let leaf = store.tree.allPaneIDs()[0]
        XCTAssertEqual(store.allSessions.count, 1, "one leaf → one materialized handle")
        assertTreeInvariant(store, "after reconcileTree(seeded single-leaf tree)")
        let handle = treeFake(store, leaf)
        XCTAssertEqual(handle?.kind, .terminal, "materialized session mirrors the leaf spec kind")
        XCTAssertEqual(handle?.events.first, .adopt(leaf), "reconcileTree re-points identity via adopt(id:)")
        XCTAssertEqual(handle?.isVideoActive, false, "materialized session is idle (no video)")
    }

    // MARK: - splitting the active pane materializes exactly one new leaf

    /// Splitting the active pane creates ONE new leaf; reconcileTree materializes exactly one new handle
    /// and KEEPS the original — assert via the fakes' adopt/teardown counts, not the tree output.
    func testSplitActivePaneMaterializesExactlyOneNewLeaf() throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let original = store.tree.allPaneIDs()[0]
        let originalFake = treeFake(store, original)
        XCTAssertEqual(store.allSessions.count, 1)

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "split added one leaf to the tree")
        XCTAssertEqual(store.allSessions.count, 2, "reconcileTree materialized exactly one new handle")
        assertTreeInvariant(store, "after splitActivePane")
        // The original handle is the SAME object (never re-materialized) — teardown never ran on it.
        XCTAssertTrue(treeFake(store, original) === originalFake, "original handle untouched by the split")
        XCTAssertEqual(originalFake?.teardownCount, 0, "original session never torn down on split")
        // The new leaf is the active pane and its handle adopted that exact id.
        let newLeaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != original })
        XCTAssertEqual(treeFake(store, newLeaf)?.events.first, .adopt(newLeaf), "new leaf adopted its id")
    }

    /// Repeated same-axis splits each materialize exactly one new handle (n-ary insert).
    func testRepeatedSplitsMaterializeEachNewLeafOnce() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        XCTAssertEqual(store.allSessions.count, 1)

        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)

        XCTAssertEqual(store.tree.allPaneIDs().count, 3, "two same-axis splits → three leaves")
        XCTAssertEqual(store.allSessions.count, 3, "each new leaf materialized exactly once")
        assertTreeInvariant(store, "after two splits")
        // No handle was torn down across the two splits.
        for id in store.tree.allPaneIDs() {
            XCTAssertEqual(treeFake(store, id)?.teardownCount, 0, "no session torn down during split sequence")
        }
    }

    // MARK: - closing a pane orphans + tears down EXACTLY its handle

    /// Closing a split pane removes its registry key synchronously and tears down its handle exactly once;
    /// the surviving pane's handle is untouched (assert teardown counts, awaited via quiesce()).
    func testCloseTreePaneTearsDownExactlyOneOrphan() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let a = store.tree.allPaneIDs()[0]
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let b = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != a })
        let aFake = treeFake(store, a)
        let bFake = treeFake(store, b)
        XCTAssertEqual(store.allSessions.count, 2)

        store.closePaneTree(b)

        // Registry key dropped SYNCHRONOUSLY (invariant holds the instant the mutation returns).
        XCTAssertNil(store.handle(for: b), "closed leaf's registry key removed synchronously")
        XCTAssertEqual(store.allSessions.count, 1, "one survivor remains registered")
        assertTreeInvariant(store, "after closePaneTree(b)")
        // The orphan's teardown completes after quiesce(); the survivor's never runs.
        await store.quiesce()
        XCTAssertEqual(bFake?.teardownCount, 1, "closed leaf torn down EXACTLY once")
        XCTAssertEqual(aFake?.teardownCount, 0, "surviving leaf never torn down")
        XCTAssertTrue(treeFake(store, a) === aFake, "surviving handle is the same object")
    }

    // MARK: - closing the LAST pane in a tab/session cascades the registry

    /// Closing the last pane of the only tab/session re-seeds a fresh default leaf (the workspace is never
    /// empty): reconcileTree tears down the old handle and materializes the re-seeded one.
    func testCloseLastPaneCascadesAndReseeds() async {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let only = store.tree.allPaneIDs()[0]
        let onlyFake = treeFake(store, only)
        XCTAssertEqual(store.allSessions.count, 1)

        store.closePaneTree(only)

        // The tree re-seeded a brand-new default leaf (never empty); the registry now backs THAT leaf.
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "workspace re-seeded one default leaf")
        let reseeded = store.tree.allPaneIDs()[0]
        XCTAssertNotEqual(reseeded, only, "the re-seeded leaf is a fresh id")
        XCTAssertEqual(store.allSessions.count, 1, "registry backs the re-seeded leaf")
        XCTAssertNil(store.handle(for: only), "the old leaf's handle was orphaned")
        assertTreeInvariant(store, "after close-last cascade")
        await store.quiesce()
        XCTAssertEqual(onlyFake?.teardownCount, 1, "the closed leaf torn down once")
    }

    /// Closing the last pane of a tab (in a multi-tab session) closes the tab and cascades: that tab's
    /// leaf is torn down, the other tab's leaves survive untouched.
    func testCloseLastPaneOfTabClosesTabAndCascadesRegistry() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let tab0Leaf = store.tree.allPaneIDs()[0]
        // Open a second tab with its own leaf.
        store.newTab(kind: .terminal)
        let tab1Leaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != tab0Leaf })
        XCTAssertEqual(store.allSessions.count, 2, "two tabs, one leaf each, both materialized")
        let tab0Fake = treeFake(store, tab0Leaf)
        let tab1Fake = treeFake(store, tab1Leaf)

        // Close the second tab's only leaf → the tab closes; tab0's leaf survives.
        store.closePaneTree(tab1Leaf)

        XCTAssertEqual(store.tree.allPaneIDs(), [tab0Leaf], "only tab0's leaf remains in the tree")
        XCTAssertEqual(store.allSessions.count, 1, "registry cascaded to one leaf")
        XCTAssertNil(store.handle(for: tab1Leaf), "the closed tab's leaf was orphaned")
        assertTreeInvariant(store, "after close-last-of-tab")
        await store.quiesce()
        XCTAssertEqual(tab1Fake?.teardownCount, 1, "the closed tab's leaf torn down once")
        XCTAssertEqual(tab0Fake?.teardownCount, 0, "the surviving tab's leaf untouched")
    }

    // MARK: - new session materializes its leaf; close session tears it down

    /// A new session adds one tab/leaf and materializes it; closing the session tears that leaf down and
    /// keeps the other session's leaves.
    func testNewAndCloseSessionMaterializeAndTeardownRegistry() async throws {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let s0Leaf = store.tree.allPaneIDs()[0]
        let s0Fake = treeFake(store, s0Leaf)

        store.newSession(name: "host-2", kind: .terminal)
        let s1Leaf = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != s0Leaf })
        XCTAssertEqual(store.allSessions.count, 2, "new session's leaf materialized")
        assertTreeInvariant(store, "after newSession")
        let s1Fake = treeFake(store, s1Leaf)

        let s1ID = try XCTUnwrap(store.tree.tab(containing: s1Leaf)?.0)
        store.closeSession(s1ID)

        XCTAssertEqual(store.tree.allPaneIDs(), [s0Leaf], "only the first session's leaf remains")
        XCTAssertEqual(store.allSessions.count, 1, "registry cascaded to the surviving session")
        assertTreeInvariant(store, "after closeSession")
        await store.quiesce()
        XCTAssertEqual(s1Fake?.teardownCount, 1, "the closed session's leaf torn down once")
        XCTAssertEqual(s0Fake?.teardownCount, 0, "the surviving session's leaf untouched")
    }

    // MARK: - selecting a tab/session keeps ALL leaves registered (full set, not active tab)

    /// reconcileTree keeps the FULL leaf set registered (not just the active tab's): selecting a different
    /// tab/session changes focus/active state but never materializes or tears down a handle.
    func testSelectTabKeepsFullLeafSetRegistered() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        let tab0Leaf = store.tree.allPaneIDs()[0]
        store.newTab(kind: .terminal)
        XCTAssertEqual(store.allSessions.count, 2, "both tabs' leaves are registered (full set)")
        let before = treeRegistryIDs(store)
        let beforeFakes = store.tree.allPaneIDs().compactMap { treeFake(store, $0) }

        // Switch back to the first tab — pure active-state change.
        store.selectTab(0)

        XCTAssertEqual(treeRegistryIDs(store), before, "tab switch left the registry unchanged (full set)")
        XCTAssertEqual(store.allSessions.count, 2, "no handle materialized or torn down on tab switch")
        // No handle re-materialized → the same objects + zero teardowns.
        for fake in beforeFakes {
            XCTAssertEqual(fake.teardownCount, 0, "tab switch tore nothing down")
        }
        _ = tab0Leaf
        assertTreeInvariant(store, "after selectTab")
    }

    // MARK: - idempotency: reconcileTree twice = no churn

    /// Calling `reconcileTree()` a second time with no tree change materializes nothing new and tears
    /// nothing down — the registry is unchanged (assert the same handle objects + zero teardowns).
    func testReconcileTreeIsIdempotent() {
        let store = makeTreeStore(restoringTree: .defaultWorkspace())
        store.reconcileTree()
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let leaves = store.tree.allPaneIDs()
        let fakesBefore = leaves.map { treeFake(store, $0) }
        let countBefore = store.allSessions.count

        store.reconcileTree() // second pass, no tree change

        XCTAssertEqual(store.allSessions.count, countBefore, "idempotent reconcileTree added no handle")
        assertTreeInvariant(store, "after idempotent reconcileTree")
        for (i, id) in leaves.enumerated() {
            XCTAssertTrue(treeFake(store, id) === fakesBefore[i], "no handle re-materialized on the second pass")
            XCTAssertEqual(treeFake(store, id)?.teardownCount, 0, "idempotent reconcileTree tore nothing down")
        }
    }

    // MARK: - the canvas reconcile path is NOT perturbed by the tree path

    /// The tree path uses the SAME registry but is dormant for the live canvas path: a store driven ONLY
    /// by the canvas (default construction) never gains a tree leaf in its registry, and `tree` defaults to
    /// the single-pane default without being reconciled at init (canvas `reconcile()` is the only init
    /// reconcile). This pins that init does NOT call reconcileTree (no double-binding).
    func testInitDoesNotReconcileTree() {
        // Default construction (non-empty default canvas) — the canvas path materialized its pane.
        let store = WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        // The registry backs the CANVAS pane, NOT the tree's default leaf (init did not reconcileTree).
        let canvasPane = store.workspace.canvas.allIDs()[0]
        XCTAssertEqual(store.allSessions.count, 1, "init materialized exactly the canvas pane")
        XCTAssertNotNil(store.handle(for: canvasPane), "canvas pane is registered")
        // The default tree leaf is a DIFFERENT id and is NOT in the registry (dormant).
        let treeLeaf = store.tree.allPaneIDs()[0]
        XCTAssertNotEqual(treeLeaf, canvasPane, "tree default leaf is independent of the canvas pane")
        XCTAssertNil(store.handle(for: treeLeaf), "the tree default leaf is NOT registered at init (dormant)")
    }
}
