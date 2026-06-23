// L6RemoteWindowLogicTests — view-LOGIC tests for the L6 remote-window video layer. View-model / pure-
// helper level only; NEVER instantiates SCStream / VTCompressionSession / VTDecompressionSession / Metal
// (hang-safety rule #6). No VideoWindowFactory is registered, so the leaf would render the headless
// placeholder — but these tests assert the PURE decisions (picker list mapping + filter, the
// RemoteGUIDisplay routing, the store's cap gating + the new tree-path remote-tab method, the system-
// dialog spawn diff, and the overlay coordinator's picker wiring) without rendering any video view.

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

// MARK: - A video-capable test double (flips isVideoActive for ANY video kind, no internal cap)

/// A `PaneSessionHandle` double whose `setVideoActive` flips for any `kind.isVideo` (remoteGUI OR
/// systemDialog), so the store's cap accounting (which counts `kind.isVideo`) is exercised purely through
/// the store. Never builds a client/host/video stack.
@MainActor
private final class VideoFakeSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false

    init(spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
}

// MARK: - Picker list mapping + filter

@MainActor
final class RemoteWindowPickerLogicTests: XCTestCase {
    private func summaries() -> [RemoteWindowSummary] {
        [
            RemoteWindowSummary(windowID: 1, appName: "Safari", title: "Apple", width: 1200, height: 800),
            RemoteWindowSummary(windowID: 2, appName: "Xcode", title: "aislopdesk", width: 1440, height: 900),
            RemoteWindowSummary(windowID: 3, appName: "Terminal", title: "", width: 800, height: 600),
        ]
    }

    func testDisplayLabelMapping() {
        XCTAssertEqual(summaries()[0].displayLabel, "Safari — Apple  (1200×800)")
        // An empty title falls back to the app name only.
        XCTAssertEqual(summaries()[2].displayLabel, "Terminal  (800×600)")
    }

    func testFilterIsTokenAndOverTitleAndApp() {
        let all = summaries()
        // Token must match title OR app, case-insensitive.
        XCTAssertEqual(RemoteWindowModel.filtered(all, query: "xcode").map(\.windowID), [2])
        XCTAssertEqual(RemoteWindowModel.filtered(all, query: "APP").map(\.windowID), [1]) // "Apple" title
        // Multi-token = AND across the title+app haystack.
        XCTAssertEqual(RemoteWindowModel.filtered(all, query: "xcode aislop").map(\.windowID), [2])
        XCTAssertTrue(RemoteWindowModel.filtered(all, query: "xcode safari").isEmpty)
        // Empty query → all.
        XCTAssertEqual(RemoteWindowModel.filtered(all, query: "   ").count, 3)
    }

    func testFilterEmptyMessageNamesFilterAndCount() {
        let msg = RemoteWindowModel.windowFilterEmptyMessage(filter: " zzz ", totalCount: 3)
        XCTAssertTrue(msg.contains("zzz"))
        XCTAssertTrue(msg.contains("3 windows"))
        XCTAssertTrue(RemoteWindowModel.windowFilterEmptyMessage(filter: "x", totalCount: 1).contains("1 window"))
    }

    func testPickFillsModelFields() {
        let model = RemoteWindowModel()
        model.pick(RemoteWindowSummary(windowID: 7, appName: "Xcode", title: "Build", width: 100, height: 50))
        XCTAssertEqual(model.windowID, "7")
        XCTAssertEqual(model.title, "Build")
        XCTAssertEqual(model.appName, "Xcode")
        XCTAssertTrue(model.canOpen)
    }
}

// MARK: - Pane-kind routing (terminal leaf vs remote-window leaf)

@MainActor
final class PaneKindRoutingTests: XCTestCase {
    func testVideoKindsRouteToRemoteLeaf() {
        // The PaneContainer routes by `kind.isVideo`: terminal → TerminalLeafView; remoteGUI / systemDialog
        // → RemoteWindowLeafView. The predicate is the routing decision.
        XCTAssertTrue(PaneKind.remoteGUI.isVideo)
        XCTAssertTrue(PaneKind.systemDialog.isVideo)
        XCTAssertFalse(PaneKind.terminal.isVideo)
    }
}

// MARK: - RemoteGUIDisplay (the leaf's live/entry-form/gated decision)

final class RemoteGUIDisplayRoutingTests: XCTestCase {
    func testAdmittedIsLive() {
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: true, configured: true, hasFreeSlot: false), .live)
    }

    func testUnconfiguredIsEntryFormEvenWhenSaturated() {
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: false, hasFreeSlot: false), .entryForm)
    }

    func testConfiguredWithFreeSlotStaysEntryFormUntilAdmitted() {
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: true, hasFreeSlot: true), .entryForm)
    }

    func testConfiguredAndSaturatedIsGated() {
        XCTAssertEqual(RemoteGUIDisplay.resolve(admitted: false, configured: true, hasFreeSlot: false), .gated)
    }
}

// MARK: - Store: new remote-window tab (tree path) + activate/deactivate gating

@MainActor
final class RemoteWindowTabStoreTests: XCTestCase {
    private func makeStore(cap: Int) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { VideoFakeSession(spec: $0) }, liveVideoCap: cap,
        )
    }

    func testNewRemoteWindowTabOpensBoundVideoPane() {
        let store = makeStore(cap: 2)
        let id = store.newRemoteWindowTab(windowID: 42, title: "Build", appName: "Xcode")
        // A new TAB was added with a `.remoteGUI` leaf carrying the endpoint.
        XCTAssertTrue(store.tree.contains(id))
        let spec = store.tree.activeSession?.specs[id]
        XCTAssertEqual(spec?.kind, .remoteGUI)
        XCTAssertEqual(spec?.video?.windowID, 42)
        XCTAssertEqual(spec?.video?.appName, "Xcode")
        XCTAssertEqual(store.handle(for: id)?.kind, .remoteGUI)
    }

    func testActivateDeactivateRespectsCap() {
        let store = makeStore(cap: 1)
        let a = store.newRemoteWindowTab(windowID: 1, title: "A", appName: "App")
        let b = store.newRemoteWindowTab(windowID: 2, title: "B", appName: "App")
        XCTAssertTrue(store.hasFreeVideoSlot(for: a))
        XCTAssertTrue(store.activateVideo(a), "first video pane admits under cap=1")
        XCTAssertFalse(store.hasFreeVideoSlot(for: b), "cap saturated")
        XCTAssertFalse(store.activateVideo(b), "second pane is gated")
        // Freeing the slot lets the gated pane in.
        store.deactivateVideo(a)
        XCTAssertTrue(store.hasFreeVideoSlot(for: b))
        XCTAssertTrue(store.activateVideo(b))
    }

    func testActivateVideoIdempotentTrueAndNonVideoFalse() {
        let store = makeStore(cap: 2)
        let v = store.newRemoteWindowTab(windowID: 9, title: "V", appName: "App")
        XCTAssertTrue(store.activateVideo(v))
        XCTAssertTrue(store.activateVideo(v), "re-activating an active pane is idempotent true")
        // A terminal pane is never a video activation target.
        let term = store.tree.activeSession?.tabs.first?.root.allPaneIDs().first
        if let term { XCTAssertFalse(store.activateVideo(term)) }
    }
}

// MARK: - System-dialog spawn logic (the monitor's diff over the discovery list)

@MainActor
final class SystemDialogSpawnLogicTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { VideoFakeSession(spec: $0) },
        )
    }

    private func makeMonitor(_ store: WorkspaceStore) -> SystemDialogMonitor {
        SystemDialogMonitor(
            store: store,
            isConnected: { true },
            target: { .default },
        )
    }

    func testReconcileSpawnsAndClosesDialogPanes() {
        let store = makeStore()
        let monitor = makeMonitor(store)
        let dialog = SystemDialogInfo(
            windowID: 100, owner: "SecurityAgent", title: "Authenticate",
            width: 400, height: 200, isSecure: true,
        )
        // Present → spawns an ephemeral systemDialog pane (a transient tab on the active session).
        monitor.reconcileForTesting([dialog])
        let dialogPanes = store.tree.allPaneIDs().filter { store.tree.activeSession?.specs[$0]?.kind == .systemDialog }
        XCTAssertEqual(dialogPanes.count, 1, "a present dialog spawns exactly one pane")
        // Gone host-side → the pane is closed again.
        monitor.reconcileForTesting([])
        let after = store.tree.allPaneIDs().filter { store.tree.activeSession?.specs[$0]?.kind == .systemDialog }
        XCTAssertTrue(after.isEmpty, "a vanished dialog closes its pane")
    }

    func testSystemDialogPaneIsBoundVideoKind() {
        let store = makeStore()
        let id = store.addSystemDialogPane(windowID: 5, owner: "SecurityAgent", title: "Login", isSecure: true)
        // The pane is an ephemeral video-kind leaf carrying the dialog's windowID — so PaneContainer routes
        // it to the RemoteWindowLeafView (the `isSecure` view-only hint is driven by LivePaneSession at
        // runtime; the secure-flag fold is pinned by the Core SystemDialogPaneTests with a real session).
        XCTAssertEqual(store.handle(for: id)?.kind, .systemDialog)
        XCTAssertTrue(PaneKind.systemDialog.isVideo, "a system dialog routes to the remote-window leaf")
        XCTAssertEqual(store.tree.activeSession?.specs[id]?.video?.windowID, 5)
    }
}

// MARK: - Overlay coordinator: remote-window picker wiring (W1)

@MainActor
final class RemotePickerCoordinatorTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { VideoFakeSession(spec: $0) },
        )
    }

    func testOpenAndCloseRemotePicker() {
        let store = makeStore()
        let coordinator = OverlayCoordinator(store: store)
        XCTAssertFalse(coordinator.remotePickerVisible)
        coordinator.openRemotePicker()
        XCTAssertTrue(coordinator.remotePickerVisible)
        XCTAssertNotNil(coordinator.remotePickerModel, "a fresh discovery model is built per open")
        coordinator.closeRemotePicker()
        XCTAssertFalse(coordinator.remotePickerVisible)
        XCTAssertNil(coordinator.remotePickerModel)
    }

    func testOpenRemoteWindowCreatesBoundTabAndClosesPicker() throws {
        let store = makeStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openRemotePicker()
        let before = store.tree.allPaneIDs().count
        coordinator.openRemoteWindow(
            RemoteWindowSummary(windowID: 77, appName: "Xcode", title: "Build", width: 100, height: 50),
        )
        XCTAssertFalse(coordinator.remotePickerVisible, "a pick closes the picker")
        let after = store.tree.allPaneIDs()
        XCTAssertEqual(after.count, before + 1, "a pick opens a new remote-window pane")
        // The new pane is a bound `.remoteGUI` leaf.
        let bound = after.first { store.tree.activeSession?.specs[$0]?.video?.windowID == 77 }
        XCTAssertNotNil(bound)
        XCTAssertEqual(try store.tree.activeSession?.specs[XCTUnwrap(bound)]?.kind, .remoteGUI)
    }

    func testNewRemoteTabPaletteRowOpensPicker() {
        // The "New Remote Window Tab" catalog row routes to the picker (it is `.openRemotePicker`, not a
        // direct `.store` mutation that would mint an unbound pane).
        let row = ActionsPaletteSource.catalog.first { $0.id == "action.newRemoteTab" }
        XCTAssertNotNil(row)
        if case .openRemotePicker = row?.action {} else {
            XCTFail("New Remote Window Tab must open the picker (.openRemotePicker)")
        }
    }
}
