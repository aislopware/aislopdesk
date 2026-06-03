import XCTest
@testable import RworkClientUI

/// Pins the load-bearing **reconcile** contract of ``WorkspaceStore`` (docs/22 §2.3, §8): the diff
/// that keeps the `[PaneID: any PaneSessionHandle]` table of liveness 1:1 with the leaves of the pure
/// tree of intent after **every** mutation. This is what guarantees there is exactly one
/// ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`) per
/// pane — the four byte-pipeline invariants by construction.
///
/// The whole suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` so it exercises
/// the store's materialize / teardown / id-adoption logic **without ever building a `RworkClient` or a
/// `HostServer`** (forbidden — the latter deadlocks the pool). The assertions are deterministic:
///
/// - **The registry invariant** `Set(registry.keys) == Set(allLeafIDs())` AND `handle.id == leafID`
///   holds synchronously the instant any mutation returns (init / addTab / closeTab / selectTab /
///   moveTab / split / closePane / focus / move / toggleZoom / setFractions / updateSpec / bootstrap).
/// - **Materialization** mints exactly one new idle handle per new leaf and ``adopt(id:)``s it to the
///   leaf id (`.adopt(leafID)` is the handle's first recorded event — the `.id(PaneID)` identity hazard).
/// - **Teardown** of an orphaned leaf runs `teardown()` EXACTLY ONCE, after `quiesce()` (teardown is
///   async, reconcile is synchronous: the registry already excludes the orphan, but the teardown work
///   only completes once the tracked task runs).
/// - **Idempotency** — a no-op-shaped mutation (selecting the already-active tab, focusing the
///   already-focused pane) leaves `allSessions` unchanged (no extra makeSession / teardown).
/// - **View-only projection** — `updateSolvedLayout(...)`, the only view→store geometry report, never
///   touches the registry (a compact ↔ regular flip does NOT reconcile).
///
/// `WorkspaceStore` is `@MainActor`, so the whole suite is `@MainActor`. The close paths are async
/// (the teardown fan-out is awaited via `quiesce()`); everything else is synchronous.
@MainActor
final class WorkspaceStoreReconcileTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a store with the ``FakePaneSession`` seam (NEVER a real client/host). `restoring` lets a
    /// test pin a known tree; default is the one-terminal-tab default workspace.
    private func makeStore(restoring: Workspace? = nil, liveVideoCap: Int = 2) -> WorkspaceStore {
        WorkspaceStore(
            restoring: restoring,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: liveVideoCap
        )
    }

    /// All leaf ids across every tab, in pre-order (the reconcile diff domain), derived from the tree —
    /// the source of truth the registry is asserted against.
    private func leafIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.workspace.tabs.flatMap { $0.root.allLeafIDs() }
    }

    /// The set of ids the registry currently holds, surfaced via the only public registry windows
    /// (`allSessions` — order unspecified, hence a Set).
    private func registryIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.allSessions.map { $0.id })
    }

    /// The fake handle for `id` (downcast for the recorded-lifecycle accessors), or `nil`.
    private func fake(_ store: WorkspaceStore, _ id: PaneID) -> FakePaneSession? {
        store.handle(for: id) as? FakePaneSession
    }

    /// THE invariant, asserted after every op: the registry keys are exactly the tree's leaf ids, AND
    /// every materialized handle has adopted its leaf id (so `handle(for:)` round-trips by identity).
    private func assertInvariant(
        _ store: WorkspaceStore,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let leaves = Set(leafIDs(store))
        XCTAssertEqual(registryIDs(store), leaves, "registry.keys != allLeafIDs() \(message)", file: file, line: line)
        XCTAssertEqual(store.allSessions.count, leaves.count, "registry has duplicate/extra handles \(message)", file: file, line: line)
        for id in leaves {
            let handle = store.handle(for: id)
            XCTAssertNotNil(handle, "no handle for leaf \(id) \(message)", file: file, line: line)
            XCTAssertEqual(handle?.id, id, "handle.id != its leaf id (adopt failed) \(message)", file: file, line: line)
        }
    }

    // MARK: - init materializes the default/restored leaves

    /// `init` calls `reconcile()` so the default workspace's single terminal leaf is materialized
    /// immediately — the registry is non-empty before any mutation, and the invariant already holds.
    func testInitMaterializesDefaultWorkspaceLeaf() {
        let store = makeStore()
        XCTAssertEqual(store.allSessions.count, 1, "default workspace = one terminal leaf, materialized at init")
        assertInvariant(store, "after init(default)")

        let leaf = leafIDs(store)[0]
        let handle = fake(store, leaf)
        XCTAssertEqual(handle?.kind, .terminal, "the materialized session mirrors the leaf spec kind")
        XCTAssertEqual(handle?.id, leaf, "init adopted the leaf id")
        // adopt() is the first thing reconcile does to a fresh handle → first recorded event.
        XCTAssertEqual(handle?.events.first, .adopt(leaf), "reconcile re-points identity via adopt(id:) at materialization")
    }

    /// Restoring a multi-leaf, multi-tab tree materializes EVERY leaf at init (shape + intent only —
    /// sessions are idle, never connected).
    func testInitMaterializesAllRestoredLeavesAcrossTabs() {
        // Tab A: a 2-leaf horizontal split. Tab B: a single claudeCode leaf.
        let a0 = PaneID(), a1 = PaneID(), b0 = PaneID()
        let tabA = Tab(
            name: "A",
            root: .split(.horizontal,
                         children: [.leaf(a0, PaneSpec(kind: .terminal, title: "a0")),
                                    .leaf(a1, PaneSpec(kind: .terminal, title: "a1"))],
                         fractions: [0.5, 0.5]),
            focusedPane: a0
        )
        let tabB = Tab(name: "B", root: .leaf(b0, PaneSpec(kind: .claudeCode, title: "b0")), focusedPane: b0)
        let restored = Workspace(tabs: [tabA, tabB], activeTabID: tabA.id)

        let store = makeStore(restoring: restored)

        XCTAssertEqual(store.allSessions.count, 3, "all three leaves across both tabs materialized at init")
        assertInvariant(store, "after init(restored 3-leaf/2-tab)")
        XCTAssertEqual(fake(store, b0)?.kind, .claudeCode, "leaf spec kind preserved through materialization")
        // No connect/video at materialization — sessions are idle.
        XCTAssertEqual(fake(store, b0)?.isVideoActive, false, "materialized session is idle (no video)")
        XCTAssertEqual(fake(store, b0)?.pauseCount, 0, "materialized session is not paused")
    }

    // MARK: - split materializes exactly one new leaf, focuses it, keeps the original

    /// A split adds EXACTLY one new key (the new leaf), preserves the original leaf's session by
    /// identity (no churn of the existing pane), focuses the new leaf, and tears down nothing.
    func testSplitMaterializesExactlyOneNewLeafAndKeepsOriginal() async {
        let store = makeStore()
        let original = leafIDs(store)[0]
        let originalHandle = fake(store, original)

        store.split(original, axis: .horizontal, kind: .terminal)

        let leaves = leafIDs(store)
        XCTAssertEqual(leaves.count, 2, "split goes from 1 → 2 leaves")
        assertInvariant(store, "after split")

        // The original pane's SAME handle instance survives (identity-stable — not rebuilt).
        XCTAssertTrue(originalHandle === fake(store, original), "split does not churn the existing pane's session")

        // Exactly one new key, focused, and never torn down.
        let newLeaf = leaves.first { $0 != original }
        XCTAssertNotNil(newLeaf, "a new leaf id appeared")
        XCTAssertEqual(fake(store, newLeaf!)?.events.first, .adopt(newLeaf!), "new handle adopted the new leaf id")
        XCTAssertTrue(store.isFocused(newLeaf!), "split() focuses the new pane")

        await store.quiesce()
        XCTAssertEqual(originalHandle?.teardownCount, 0, "the surviving original pane is never torn down by a split")
    }

    /// Two same-axis splits flatten into one 3-way row (WF2 flatten rule): the registry tracks all
    /// three leaves and only ever materializes the two genuinely-new ones.
    func testRepeatedSameAxisSplitMaterializesEachNewLeafOnce() async {
        let store = makeStore()
        let l0 = leafIDs(store)[0]

        store.split(l0, axis: .horizontal, kind: .terminal)
        let afterFirst = Set(leafIDs(store))
        let l1 = afterFirst.subtracting([l0]).first!
        assertInvariant(store, "after first split")

        store.split(l1, axis: .horizontal, kind: .terminal)
        let afterSecond = leafIDs(store)
        XCTAssertEqual(afterSecond.count, 3, "same-axis split flattens to a 3-way row")
        assertInvariant(store, "after second same-axis split")

        // The first two handles are untouched (no re-materialize, no teardown).
        await store.quiesce()
        XCTAssertEqual(fake(store, l0)?.teardownCount, 0)
        XCTAssertEqual(fake(store, l1)?.teardownCount, 0)
        let l2 = Set(afterSecond).subtracting([l0, l1]).first!
        XCTAssertEqual(fake(store, l2)?.events.first, .adopt(l2), "only the genuinely-new leaf is materialized + adopted")
    }

    // MARK: - closePane tears down the orphan EXACTLY ONCE and removes it

    /// Closing a non-last leaf removes its key from the registry SYNCHRONOUSLY (the invariant holds on
    /// return), and after `quiesce()` the orphan's `teardown()` has run EXACTLY ONCE.
    func testClosePaneRemovesKeySynchronouslyAndTearsDownExactlyOnce() async {
        let store = makeStore()
        let original = leafIDs(store)[0]
        store.split(original, axis: .vertical, kind: .terminal)
        let leaves = leafIDs(store)
        let victim = leaves.first { $0 != original }!
        let survivor = original
        let victimHandle = fake(store, victim)!

        store.closePane(victim)

        // Synchronous: the orphan is gone the instant closePane returns.
        XCTAssertNil(store.handle(for: victim), "orphan removed from the registry synchronously")
        XCTAssertNotNil(store.handle(for: survivor), "the surviving pane stays live")
        XCTAssertEqual(leafIDs(store), [survivor], "tree collapsed the singleton split back to the survivor")
        assertInvariant(store, "after closePane (pre-quiesce)")
        // teardown is async — it has NOT necessarily run yet, but the registry is already correct.

        await store.quiesce()
        XCTAssertEqual(victimHandle.teardownCount, 1, "the orphaned session's teardown() runs exactly once")
        assertInvariant(store, "after closePane (post-quiesce)")
        // quiesce is idempotent — a second await drives no further teardown.
        await store.quiesce()
        XCTAssertEqual(victimHandle.teardownCount, 1, "quiesce is idempotent; no double teardown")
    }

    /// Closing the LAST leaf of the only tab empties the workspace: the registry drains to empty and
    /// that one session is torn down once.
    func testCloseLastLeafEmptiesRegistry() async {
        let store = makeStore()
        let only = leafIDs(store)[0]
        let onlyHandle = fake(store, only)!

        store.closePane(only)

        XCTAssertTrue(store.allSessions.isEmpty, "closing the last leaf empties the registry")
        XCTAssertTrue(store.workspace.tabs.isEmpty, "and empties the workspace (the tab closed)")
        assertInvariant(store, "after closing the only leaf")

        await store.quiesce()
        XCTAssertEqual(onlyHandle.teardownCount, 1, "the lone session is torn down once")
    }

    // MARK: - closeTab tears down ALL of that tab's sessions

    /// Closing a whole tab (with a multi-leaf tree) tears down EVERY session in that tab, exactly once
    /// each, and leaves the surviving tab's sessions intact.
    func testCloseTabTearsDownAllItsSessions() async {
        // Tab A: 2 leaves. Tab B (active-after): 1 leaf.
        let a0 = PaneID(), a1 = PaneID(), b0 = PaneID()
        let tabA = Tab(
            name: "A",
            root: .split(.horizontal,
                         children: [.leaf(a0, PaneSpec(kind: .terminal, title: "a0")),
                                    .leaf(a1, PaneSpec(kind: .terminal, title: "a1"))],
                         fractions: [0.5, 0.5]),
            focusedPane: a0
        )
        let tabB = Tab(name: "B", root: .leaf(b0, PaneSpec(kind: .terminal, title: "b0")), focusedPane: b0)
        let store = makeStore(restoring: Workspace(tabs: [tabA, tabB], activeTabID: tabA.id))

        let a0Handle = fake(store, a0)!
        let a1Handle = fake(store, a1)!
        let b0Handle = fake(store, b0)!

        store.closeTab(tabA.id)

        // Both of tab A's leaves are gone from the registry synchronously; tab B's survives.
        XCTAssertNil(store.handle(for: a0))
        XCTAssertNil(store.handle(for: a1))
        XCTAssertNotNil(store.handle(for: b0))
        XCTAssertEqual(leafIDs(store), [b0], "only tab B's leaf remains")
        assertInvariant(store, "after closeTab(A)")

        await store.quiesce()
        XCTAssertEqual(a0Handle.teardownCount, 1, "tab A leaf a0 torn down once")
        XCTAssertEqual(a1Handle.teardownCount, 1, "tab A leaf a1 torn down once")
        XCTAssertEqual(b0Handle.teardownCount, 0, "the surviving tab's session is untouched")
    }

    // MARK: - addTab materializes its leaf

    /// `addTab` appends a fresh single-leaf tab and materializes its session — exactly one new key, the
    /// rest of the registry unchanged.
    func testAddTabMaterializesItsLeaf() {
        let store = makeStore()
        let before = registryIDs(store)

        store.addTab(kind: .claudeCode)

        let after = registryIDs(store)
        XCTAssertEqual(after.count, before.count + 1, "addTab materializes exactly one new leaf")
        XCTAssertTrue(before.isSubset(of: after), "existing sessions are untouched")
        assertInvariant(store, "after addTab")

        let newLeaf = after.subtracting(before).first!
        XCTAssertEqual(fake(store, newLeaf)?.kind, .claudeCode, "new tab's leaf materialized with its kind")
    }

    // MARK: - Whole-API invariant sweep (split / close / addTab / closeTab / move / zoom / focus)

    /// Drives a representative sequence of EVERY mutation and asserts the registry invariant holds the
    /// instant each one returns — the docs/22 §2.3 "holds after any sequence of ops" claim.
    func testInvariantHoldsAfterEveryMutationInASequence() async {
        let store = makeStore()
        assertInvariant(store, "init")

        // addTab
        store.addTab(kind: .terminal)
        assertInvariant(store, "addTab")
        let tab2 = store.activeTab!

        // split (creates a second leaf in tab2) — needed before move/zoom/focus have neighbours.
        let p0 = tab2.focusedPane
        store.split(p0, axis: .horizontal, kind: .terminal)
        assertInvariant(store, "split")
        let leavesInTab2 = store.activeTab!.root.allLeafIDs()
        XCTAssertEqual(leavesInTab2.count, 2)

        // focus (pure focus change — leaf set unchanged → registry unchanged)
        store.focus(leavesInTab2[0])
        assertInvariant(store, "focus")

        // move(.next) cycles focus within the tab (pre-order cycle; no layout reported)
        store.move(.next)
        assertInvariant(store, "move(.next)")

        // toggleZoom (presentation flag — no tree surgery)
        store.toggleZoom()
        assertInvariant(store, "toggleZoom on")
        store.toggleZoom()
        assertInvariant(store, "toggleZoom off")

        // setFractions on tab2's root split (geometry only — leaf set unchanged)
        store.setFractions(tab: tab2.id, path: [], to: [0.3, 0.7])
        assertInvariant(store, "setFractions")

        // updateSpec (rename a leaf — leaf set unchanged, session not rebuilt)
        let handleBefore = store.handle(for: leavesInTab2[0]) as AnyObject
        store.updateSpec(leavesInTab2[0]) { $0.title = "renamed" }
        assertInvariant(store, "updateSpec")
        XCTAssertTrue(handleBefore === (store.handle(for: leavesInTab2[0]) as AnyObject),
                      "updateSpec does NOT rebuild the live session under the user")

        // moveTab (reorder — leaf set unchanged)
        store.moveTab(from: IndexSet(integer: 0), to: 2)
        assertInvariant(store, "moveTab")

        // selectTab (focus another tab — leaf set unchanged)
        store.selectTab(store.workspace.tabs[0].id)
        assertInvariant(store, "selectTab")

        // closePane one of tab2's leaves (orphan teardown)
        let toClose = leavesInTab2[1]
        store.closePane(toClose)
        assertInvariant(store, "closePane")

        // closeTab the remaining multi/​single-leaf tab2
        store.closeTab(tab2.id)
        assertInvariant(store, "closeTab")

        await store.quiesce()
        assertInvariant(store, "post-quiesce")
    }

    // MARK: - Idempotency (no public reconcile; assert via no-op-shaped mutations)

    /// There is no public `reconcile()`; instead, a no-op-shaped mutation (selecting the
    /// already-active tab) leaves the registry byte-for-byte unchanged — same handle instances, no new
    /// makeSession call, no teardown. (reconcile twice with an unchanged tree is a no-op.)
    func testSelectingAlreadyActiveTabDoesNotChangeRegistry() async {
        let store = makeStore()
        store.addTab(kind: .terminal) // now 2 tabs, second active
        let activeID = store.activeTab!.id
        let before = store.allSessions.map { ObjectIdentifier($0) }

        store.selectTab(activeID) // already active → no-op-shaped

        let after = store.allSessions.map { ObjectIdentifier($0) }
        XCTAssertEqual(Set(before), Set(after), "re-selecting the active tab materializes nothing new and tears nothing down")
        XCTAssertEqual(store.allSessions.count, before.count)
        assertInvariant(store, "after re-selecting the active tab")

        await store.quiesce()
        for handle in store.allSessions {
            XCTAssertEqual((handle as? FakePaneSession)?.teardownCount, 0, "no spurious teardown on a no-op-shaped mutation")
        }
    }

    /// Focusing the already-focused pane is likewise a no-op for the registry: the leaf set is
    /// unchanged, so reconcile materializes nothing and tears nothing down.
    func testFocusingAlreadyFocusedPaneDoesNotChangeRegistry() async {
        let store = makeStore()
        let focused = store.activeTab!.focusedPane
        let handleBefore = store.handle(for: focused) as AnyObject

        store.focus(focused) // already focused → no-op-shaped

        XCTAssertEqual(store.allSessions.count, 1)
        XCTAssertTrue(handleBefore === (store.handle(for: focused) as AnyObject), "the same session instance survives")
        assertInvariant(store, "after focusing the already-focused pane")

        await store.quiesce()
        XCTAssertEqual(fake(store, focused)?.teardownCount, 0)
    }

    // MARK: - View-only projection does NOT reconcile (compact ↔ regular flip)

    /// `updateSolvedLayout(...)` is the ONLY view→store geometry report and is view-only: a simulated
    /// compact ↔ regular projection flip (which only changes how the SAME tree is rendered, via
    /// ``WorkspaceLayout/isCompact(horizontalSizeClassCompact:width:)``) must not touch the registry.
    func testCompactRegularProjectionFlipDoesNotReconcile() async {
        let store = makeStore()
        store.addTab(kind: .terminal)
        let p0 = store.activeTab!.focusedPane
        store.split(p0, axis: .horizontal, kind: .terminal)
        let before = store.allSessions.map { ObjectIdentifier($0) }
        assertInvariant(store, "pre-flip")

        // Sanity-pin the projection helper so the "flip" is real, then report each layout to the store.
        XCTAssertTrue(WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, width: 400), "narrow → compact")
        XCTAssertFalse(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 1200), "wide → regular")
        // The breakpoint is a DETAIL-area width: the macOS minimum window's detail (~500pt with the
        // ideal sidebar) must resolve REGULAR, not compact — the threshold (460) sits below it.
        XCTAssertFalse(WorkspaceLayout.isCompact(horizontalSizeClassCompact: false, width: 500),
                       "macOS min-window detail (~500pt) → regular")
        // The size-class path is unchanged: an iPhone-class detail is compact regardless of width.
        XCTAssertTrue(WorkspaceLayout.isCompact(horizontalSizeClassCompact: true, width: 500),
                      "size-class compact → compact even at 500pt")

        // A regular-mode solved layout, then a compact-mode (empty-frames) one — the view→store report.
        let leaves = store.activeTab!.root.allLeafIDs()
        let regular = SolvedLayout(
            frames: [
                leaves[0]: CGRect(x: 0, y: 0, width: 600, height: 400),
                leaves[1]: CGRect(x: 600, y: 0, width: 600, height: 400),
            ],
            dividers: []
        )
        store.updateSolvedLayout(regular)
        assertInvariant(store, "after reporting regular layout")
        XCTAssertEqual(Set(store.allSessions.map { ObjectIdentifier($0) }), Set(before), "regular layout report changed no sessions")

        let compact = SolvedLayout.empty // compact carousel solves no multi-pane rects
        store.updateSolvedLayout(compact)
        assertInvariant(store, "after reporting compact layout")
        XCTAssertEqual(Set(store.allSessions.map { ObjectIdentifier($0) }), Set(before),
                       "a compact↔regular projection flip is view-only — registry untouched")

        await store.quiesce()
        for handle in store.allSessions {
            XCTAssertEqual((handle as? FakePaneSession)?.teardownCount, 0, "projection flip tears nothing down")
        }
    }

    // MARK: - Teardown ordering across multiple orphans (single serialized task)

    /// Closing a whole tab orphans MULTIPLE sessions; reconcile drives their `teardown()` in ONE
    /// dedicated task in registry-removal order. Each runs exactly once (no fire-and-forget double-run).
    func testClosingMultiLeafTabTearsDownEachOrphanExactlyOnce() async {
        let a0 = PaneID(), a1 = PaneID(), a2 = PaneID(), b0 = PaneID()
        let tabA = Tab(
            name: "A",
            root: .split(.horizontal,
                         children: [.leaf(a0, PaneSpec(kind: .terminal, title: "a0")),
                                    .leaf(a1, PaneSpec(kind: .terminal, title: "a1")),
                                    .leaf(a2, PaneSpec(kind: .terminal, title: "a2"))],
                         fractions: [1.0 / 3, 1.0 / 3, 1.0 / 3]),
            focusedPane: a0
        )
        let tabB = Tab(name: "B", root: .leaf(b0, PaneSpec(kind: .terminal, title: "b0")), focusedPane: b0)
        let store = makeStore(restoring: Workspace(tabs: [tabA, tabB], activeTabID: tabA.id))

        let handles = [a0, a1, a2].map { fake(store, $0)! }
        store.closeTab(tabA.id)
        assertInvariant(store, "after closing the 3-leaf tab")

        await store.quiesce()
        for (i, handle) in handles.enumerated() {
            XCTAssertEqual(handle.teardownCount, 1, "orphan a\(i) torn down exactly once")
            XCTAssertEqual(handle.events, [.adopt(handle.id), .teardown],
                           "orphan a\(i) recorded only adopt-then-teardown (no spurious lifecycle calls)")
        }
    }

    // MARK: - in-flight video-cap accounting does not perturb the registry invariant (ITEM #3)

    /// The ITEM #3 in-flight-teardown video accounting (`tearingDownVideo`) is a SEPARATE bookkeeping
    /// set from the registry: closing a live `.remoteGUI` pane removes its key from the registry
    /// SYNCHRONOUSLY (the invariant `registry.keys == allLeafIDs()` holds the instant `closePane`
    /// returns) even while its teardown — and hence its in-flight cap slot — is still parked. The cap
    /// accounting must never leak into or perturb the registry/leaf-set invariant.
    func testInFlightVideoAccountingDoesNotPerturbRegistryInvariant() async {
        // A single remoteGUI tab grown to two leaves (no stray terminal tab to muddy the invariant).
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let tab = Tab(name: "Remote window", root: .leaf(rootID, spec), focusedPane: rootID)
        let store = makeStore(restoring: Workspace(tabs: [tab], activeTabID: tab.id))
        let first = store.activeTab!.root.allLeafIDs()[0]
        store.split(first, axis: .horizontal, kind: .remoteGUI)
        let ids = store.activeTab!.root.allLeafIDs()
        XCTAssertEqual(ids.count, 2)
        assertInvariant(store, "two remoteGUI leaves")

        // Park the close-victim's teardown so its in-flight cap slot is held across the assertions.
        let gate = FakeTeardownGate()
        fake(store, ids[0])!.teardownGate = gate
        XCTAssertTrue(store.activateVideo(ids[0]), "ids[0] holds a live video stack")

        store.closePane(ids[0])

        // The registry invariant holds SYNCHRONOUSLY even though ids[0]'s teardown (and its in-flight
        // cap slot) is still parked: the registry excludes the orphan the instant closePane returns.
        XCTAssertNil(store.handle(for: ids[0]), "orphan removed from the registry synchronously")
        assertInvariant(store, "registry invariant holds while teardown (and its cap slot) is in flight")

        // Release + drain: the invariant still holds, and now no teardown / in-flight slot is pending.
        gate.release()
        await store.quiesce()
        assertInvariant(store, "registry invariant holds after the in-flight teardown completes")
        XCTAssertEqual(fake(store, ids[1])!.teardownCount, 0, "the survivor was never torn down")
    }

    // MARK: - quiesce awaits a teardown task spawned DURING its own drain (BUG-J)

    /// BUG-J: a teardown task spawned by a `reconcile()` that runs WHILE `quiesce()` is awaiting an
    /// earlier teardown must still be awaited — `quiesce()` loops to a fixpoint rather than snapshotting
    /// once. We park the first close's teardown on a gate, start `quiesce()` (it suspends awaiting that
    /// task), then — while it is suspended — close a SECOND pane (spawning a new teardown task), release
    /// the gate, and confirm BOTH teardowns completed once `quiesce()` returns. A single-snapshot drain
    /// would have dropped the second task.
    func testQuiesceAwaitsTeardownSpawnedDuringDrain() async {
        // Three terminal leaves in one tab so we can close two of them independently and keep a survivor.
        let a0 = PaneID(), a1 = PaneID(), a2 = PaneID()
        let tab = Tab(
            name: "A",
            root: .split(.horizontal,
                         children: [.leaf(a0, PaneSpec(kind: .terminal, title: "a0")),
                                    .leaf(a1, PaneSpec(kind: .terminal, title: "a1")),
                                    .leaf(a2, PaneSpec(kind: .terminal, title: "a2"))],
                         fractions: [1.0 / 3, 1.0 / 3, 1.0 / 3]),
            focusedPane: a0
        )
        let store = makeStore(restoring: Workspace(tabs: [tab], activeTabID: tab.id))
        let gate0 = FakeTeardownGate()
        let h0 = fake(store, a0)!
        let h1 = fake(store, a1)!
        h0.teardownGate = gate0    // the first close's teardown will park here

        // First close → spawns teardown task #1, which parks on gate0.
        store.closePane(a0)
        XCTAssertNil(store.handle(for: a0))

        // Start quiesce; it will suspend awaiting task #1 (parked on gate0). Run it as a child task so
        // the test body can interleave a second close while quiesce is mid-drain.
        let quiesced = Task { @MainActor in await store.quiesce() }

        // Wait until task #1's teardown body has actually entered (and parked on) the gate, so quiesce is
        // genuinely suspended mid-drain before we spawn the second teardown (no fixed-sleep race).
        let entered = await waitUntil { gate0.waiterCount == 1 }
        XCTAssertTrue(entered, "the first teardown parked on the gate — quiesce is suspended mid-drain")

        // While quiesce is suspended, close a SECOND pane → spawns teardown task #2 (no gate → it will
        // complete immediately once it runs). With a single-snapshot drain this task would be dropped.
        store.closePane(a1)
        XCTAssertNil(store.handle(for: a1))

        // Release the first teardown; quiesce's loop must now re-check teardownTasks, find task #2, and
        // await it too before returning.
        gate0.release()
        await quiesced.value

        XCTAssertEqual(h0.teardownCount, 1, "the gated first teardown ran exactly once")
        XCTAssertEqual(h1.teardownCount, 1,
                       "the teardown spawned DURING quiesce's drain was still awaited (BUG-J fixpoint loop)")
        // After the fixpoint loop, nothing is pending: a second quiesce is a no-op.
        await store.quiesce()
        XCTAssertEqual(h0.teardownCount, 1)
        XCTAssertEqual(h1.teardownCount, 1)
        XCTAssertEqual(fake(store, a2)?.teardownCount, 0, "the survivor was never torn down")
    }

    // MARK: - Helpers

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps). Mirrors
    /// the `waitUntil` used by `ScenePhaseFanOutTests` / the connection tests.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
