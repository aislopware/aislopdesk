import XCTest
@testable import RworkClientUI

// MARK: - LiveVideoCapTests

/// Pins the `liveVideoCap` admission policy on ``WorkspaceStore`` (docs/22 §7): the concurrent
/// live-video ceiling that protects the PATH 2 resource budget (2N UDP sockets / N
/// `VTDecompressionSession` / N `CVDisplayLink`). The cap is enforced at **activation**
/// (``WorkspaceStore/activateVideo(_:)``), NOT at materialization — `reconcile()` always
/// materializes an IDLE `.remoteGUI` session; the store only admits its video stack when a slot is
/// free.
///
/// Everything here injects ``FakePaneSession`` through the `makeSession` seam — never a `RworkClient`
/// or a `HostServer`. The double's `setVideoActive` flips its `isVideoActive` flag UNCONDITIONALLY
/// for `.remoteGUI` (no internal cap), so the cap under test is purely the store's: we exercise it
/// only through `store.activateVideo` / `store.deactivateVideo`, never by poking the double.
///
/// The asserted contract:
/// - the first `liveVideoCap` `.remoteGUI` panes activate (`true`); the next is GATED (`false`) and
///   left inactive (the view shows the gated placeholder);
/// - re-activating an already-active pane is an idempotent `true`;
/// - `deactivateVideo` frees a slot, after which a previously-gated pane CAN activate — the store
///   does NOT auto-promote a queued pane on free (activation is view-driven on appear, docs/22 §7);
/// - `terminal` / `claudeCode` panes are NEVER gated by the video cap (and never count against it):
///   `activateVideo` returns `false` for them because they are non-video, not because of the cap.
@MainActor
final class LiveVideoCapTests: XCTestCase {

    // MARK: - Fixtures

    /// A store wired with the test double and an explicit cap. Never constructs a real client/host.
    private func makeStore(cap: Int) -> WorkspaceStore {
        WorkspaceStore(makeSession: { FakePaneSession($0) }, liveVideoCap: cap)
    }

    /// Casts a handle to the concrete double so a test can read its recorded video state.
    private func fake(_ handle: (any PaneSessionHandle)?) -> FakePaneSession {
        guard let f = handle as? FakePaneSession else {
            fatalError("expected a FakePaneSession from the injected seam")
        }
        return f
    }

    /// Builds a store whose ONLY tab is a tree of `n` `.remoteGUI` leaves (one root leaf + `n−1`
    /// splits), returning the store and the leaf ids in tree pre-order. The store is `restoring:` a
    /// single-remoteGUI-tab workspace (NOT `addTab`, which would leave the default terminal tab in
    /// the registry and contaminate the cap accounting). Each split adds exactly one new `.remoteGUI`
    /// session; reconcile materializes them all IDLE (none video-active yet).
    private func makeStoreWithRemoteGUILeaves(_ n: Int, cap: Int) -> (store: WorkspaceStore, ids: [PaneID]) {
        precondition(n >= 1)
        let rootID = PaneID()
        let spec = PaneSpec(kind: .remoteGUI, title: "Remote window")
        let tab = Tab(name: "Remote window", root: .leaf(rootID, spec), focusedPane: rootID)
        let ws = Workspace(tabs: [tab], activeTabID: tab.id)
        let store = WorkspaceStore(restoring: ws, makeSession: { FakePaneSession($0) }, liveVideoCap: cap)

        var ids = store.activeTab!.root.allLeafIDs()
        // Split the most-recently-added leaf to grow the tree to `n` remoteGUI leaves.
        while ids.count < n {
            store.split(ids.last!, axis: .horizontal, kind: .remoteGUI)
            ids = store.activeTab!.root.allLeafIDs()
        }
        XCTAssertEqual(ids.count, n, "tree should have exactly \(n) remoteGUI leaves")
        XCTAssertEqual(store.allSessions.count, n, "registry holds only the remoteGUI leaves (no stray default tab)")
        return (store, ids)
    }

    // MARK: - Materialization is idle (cap is NOT a materialization gate)

    /// `reconcile()` materializes one IDLE `.remoteGUI` session per leaf regardless of the cap —
    /// the cap only bites at activation. After building 3 leaves under cap=2, all 3 sessions exist
    /// and none is video-active.
    func testRemoteGUIPanesMaterializeIdleEvenBeyondCap() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        XCTAssertEqual(store.allSessions.count, 3, "all leaves materialize, even beyond the cap")
        for id in ids {
            let h = store.handle(for: id)
            XCTAssertNotNil(h, "leaf \(id) has a live session")
            XCTAssertEqual(h?.kind, .remoteGUI)
            XCTAssertFalse(h!.isVideoActive, "materialized sessions are idle — no video activated")
        }
        // Registry-key invariant holds: one handle per leaf, keyed by leaf id.
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.activeTab!.root.allLeafIDs()))
    }

    // MARK: - The cap admits up to N, then gates

    /// With cap=2, the first two `.remoteGUI` panes activate (`true`) and the third is GATED:
    /// `activateVideo` returns `false` and leaves the pane inactive.
    func testActivateAdmitsUpToCapThenGatesThird() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)

        XCTAssertTrue(store.activateVideo(ids[0]), "1st video pane admitted")
        XCTAssertTrue(store.activateVideo(ids[1]), "2nd video pane admitted (at the cap)")
        XCTAssertFalse(store.activateVideo(ids[2]), "3rd is gated — cap saturated by 2 others")

        // The first two hold live video; the gated third stays idle.
        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive)
        XCTAssertTrue(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertFalse(fake(store.handle(for: ids[2])).isVideoActive, "gated pane never had setVideoActive(true)")

        // The double recorded exactly the two admitted activations, none for the gated pane.
        XCTAssertEqual(fake(store.handle(for: ids[0])).events, [.adopt(ids[0]), .videoActive(true)])
        XCTAssertEqual(fake(store.handle(for: ids[2])).events, [.adopt(ids[2])],
                       "gated pane saw only its adopt — the store never called setVideoActive on it")

        // Exactly cap panes are live.
        let activeCount = store.allSessions.filter { $0.kind == .remoteGUI && $0.isVideoActive }.count
        XCTAssertEqual(activeCount, store.liveVideoCap)
    }

    /// Re-activating an already-active pane is an idempotent `true` and does NOT consume a second
    /// slot (so it cannot accidentally push the live count past the cap).
    func testActivateAlreadyActiveIsIdempotentTrue() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))

        XCTAssertTrue(store.activateVideo(ids[0]), "already-active ⇒ idempotent true")
        XCTAssertTrue(store.activateVideo(ids[1]), "the second real slot is still free")
        XCTAssertFalse(store.activateVideo(ids[2]), "cap still 2 — the re-activation did not free or consume a slot")

        // ids[0] recorded only ONE setVideoActive(true) despite two activate calls.
        let events0 = fake(store.handle(for: ids[0])).events
        XCTAssertEqual(events0.filter { $0 == .videoActive(true) }.count, 1,
                       "idempotent re-activation does not re-call setVideoActive")
    }

    // MARK: - Freeing a slot

    /// `deactivateVideo` frees a slot; a previously-gated pane can then activate. The store does NOT
    /// auto-promote the queued pane on free — it only becomes active when the view re-requests it
    /// via `activateVideo` (docs/22 §7: activation is view-driven on appear).
    func testDeactivateFreesSlotForPreviouslyGatedPane() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "third gated while two are live")

        // Free slot 0.
        store.deactivateVideo(ids[0])
        XCTAssertFalse(fake(store.handle(for: ids[0])).isVideoActive, "slot 0 freed")
        // No auto-promotion: the previously-gated pane is still idle until it re-requests.
        XCTAssertFalse(fake(store.handle(for: ids[2])).isVideoActive,
                       "store does not auto-promote a queued pane on free")

        // The previously-gated pane now activates because a slot is free.
        XCTAssertTrue(store.activateVideo(ids[2]), "a freed slot admits the previously-gated pane")
        XCTAssertTrue(fake(store.handle(for: ids[2])).isVideoActive)

        // Still exactly cap live (ids[1] + ids[2]); ids[0] is idle.
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], ids[2]]))
    }

    /// `deactivateVideo` on a pane that is not active is a harmless no-op and frees nothing extra.
    func testDeactivateInactivePaneIsNoOp() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        // ids[1] is idle; deactivating it should not throw or flip anything.
        store.deactivateVideo(ids[1])
        XCTAssertFalse(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive, "the active pane is untouched")
    }

    // MARK: - cap respects OTHER panes only (the self-exclusion in activateVideo)

    /// The cap counts only OTHER active video panes (the `$0.id != id` filter in `activateVideo`),
    /// so with cap=1 the single admitted pane can be re-activated even though it is itself the one
    /// occupying the slot.
    func testCapOfOneAdmitsOneAndReactivatesSelf() {
        let (store, ids) = makeStoreWithRemoteGUILeaves(2, cap: 1)
        XCTAssertTrue(store.activateVideo(ids[0]), "the single slot admits the first pane")
        XCTAssertFalse(store.activateVideo(ids[1]), "no slot left for a second pane")
        XCTAssertTrue(store.activateVideo(ids[0]), "self re-activation succeeds — the cap excludes self")
    }

    // MARK: - non-video kinds are never gated by the cap

    /// `terminal` and `claudeCode` panes are not gated by the video cap — `activateVideo` returns
    /// `false` for them because they are NON-VIDEO (not because the cap is saturated), they never
    /// flip `isVideoActive`, and they never consume a video slot.
    func testTerminalAndClaudeCodeAreNeverGatedAndNeverConsumeSlots() {
        // cap=2, but saturate it with two live remoteGUI panes first.
        let store = makeStore(cap: 2)
        store.addTab(kind: .remoteGUI)                         // tab: one remoteGUI leaf
        let guiRoot = store.activeTab!.root.allLeafIDs()[0]
        store.split(guiRoot, axis: .horizontal, kind: .remoteGUI)
        let guiIDs = store.activeTab!.root.allLeafIDs()        // two remoteGUI leaves
        XCTAssertTrue(store.activateVideo(guiIDs[0]))
        XCTAssertTrue(store.activateVideo(guiIDs[1]))          // cap now saturated

        // Add terminal + claudeCode panes in a separate tab.
        store.addTab(kind: .terminal)
        let terminalID = store.activeTab!.root.allLeafIDs()[0]
        store.split(terminalID, axis: .vertical, kind: .claudeCode)
        let mixedIDs = store.activeTab!.root.allLeafIDs()
        let claudeID = mixedIDs.first { store.handle(for: $0)?.kind == .claudeCode }!

        // activateVideo is a definitional false for non-video kinds — regardless of cap state.
        XCTAssertFalse(store.activateVideo(terminalID), "terminal is non-video, not cap-gated")
        XCTAssertFalse(store.activateVideo(claudeID), "claudeCode is non-video, not cap-gated")

        // They never flipped a video flag and never consumed a slot.
        XCTAssertFalse(store.handle(for: terminalID)!.isVideoActive)
        XCTAssertFalse(store.handle(for: claudeID)!.isVideoActive)
        XCTAssertEqual(fake(store.handle(for: terminalID)).events, [.adopt(terminalID)],
                       "non-video pane saw only its adopt — no videoActive event")

        // The two real video panes are still the only ones live (the cap is unchanged by the
        // non-video activate attempts).
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([guiIDs[0], guiIDs[1]]))
    }

    /// `activateVideo` on an unknown / torn-down pane id is a safe `false` (no registered handle).
    func testActivateUnknownPaneIsFalse() {
        let store = makeStore(cap: 2)
        XCTAssertFalse(store.activateVideo(PaneID()), "no handle for an unregistered id")
    }

    // MARK: - the freed slot survives an unrelated reconcile

    /// Activating, then a structural mutation that does NOT touch the video leaves (adding a
    /// terminal tab → reconcile), leaves the video activation state intact: reconcile never
    /// re-materializes or de-activates existing sessions, so the cap accounting is stable across
    /// reconciles. After the unrelated reconcile the gated pane is still gated.
    func testVideoActivationSurvivesUnrelatedReconcile() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]))

        // An unrelated structural mutation (new terminal tab) triggers reconcile but adds only a
        // terminal leaf — the existing remoteGUI sessions (and their video state) are untouched.
        store.addTab(kind: .terminal)
        await store.quiesce()   // no orphans here, but pin the teardown-completion seam regardless

        XCTAssertTrue(fake(store.handle(for: ids[0])).isVideoActive, "video pane survived reconcile")
        XCTAssertTrue(fake(store.handle(for: ids[1])).isVideoActive)
        XCTAssertFalse(store.activateVideo(ids[2]), "still gated — the cap accounting is unchanged")

        // The original handles were not rebuilt (same instances, same single activation event each).
        XCTAssertEqual(fake(store.handle(for: ids[0])).events.filter { $0 == .videoActive(true) }.count, 1)
    }

    // MARK: - closing an ACTIVE video pane frees its slot (teardown path)

    /// Closing a pane that holds a live video slot removes it from the registry synchronously (so it
    /// no longer counts against the cap) and tears its session down asynchronously. After
    /// `quiesce()` the orphan's `teardown()` has run; a previously-gated pane can now activate
    /// because the closed pane's slot is free.
    func testClosingActiveVideoPaneFreesSlot() async {
        let (store, ids) = makeStoreWithRemoteGUILeaves(3, cap: 2)
        XCTAssertTrue(store.activateVideo(ids[0]))
        XCTAssertTrue(store.activateVideo(ids[1]))
        XCTAssertFalse(store.activateVideo(ids[2]), "gated while ids[0] and ids[1] are live")

        let closed = fake(store.handle(for: ids[0]))    // grab the double before it leaves the registry

        // Close the first live video pane (a non-last leaf, so the tab survives).
        store.closePane(ids[0])

        // Synchronously: it is gone from the registry and the invariant holds.
        XCTAssertNil(store.handle(for: ids[0]), "closed pane removed from the registry synchronously")
        XCTAssertEqual(Set(store.allSessions.map { $0.id }),
                       Set(store.activeTab!.root.allLeafIDs()),
                       "registry keys == leaf ids the instant closePane returns")

        // Its slot is freed immediately for the cap (it no longer counts), so the gated pane admits.
        XCTAssertTrue(store.activateVideo(ids[2]), "the closed pane's slot frees the gated pane")

        // The async teardown completes only after quiesce().
        await store.quiesce()
        XCTAssertEqual(closed.teardownCount, 1, "the closed video session was torn down exactly once")
        XCTAssertEqual(closed.events.last, .teardown)

        // Final live set: ids[1] (still live) + ids[2] (newly admitted).
        let activeIDs = Set(store.allSessions.filter { $0.isVideoActive }.map { $0.id })
        XCTAssertEqual(activeIDs, Set([ids[1], ids[2]]))
    }
}
