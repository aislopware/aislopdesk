// L5OverlayLogicTests — view-LOGIC tests for the L5 overlay layer (command palette / modal / toast /
// context menu). Pure model + coordinator level only; NEVER instantiates Ghostty/VT/Metal/SCStream
// (hang-safety rule). Covers:
//   - SearchMixer ranking + per-filter gating + section separators + zero-state recents,
//   - PaletteAction routing (running a row mutates the store; settings/filter actions),
//   - the busy-close ConfirmModal flow via the store's pendingCloseSpec (confirm vs cancel),
//   - OverlayCoordinator toast lifecycle (push / de-dupe / cap / dismiss),
//   - ContextMenuModel action mapping (pane/tab item → store mutation).

import AislopdeskAgentDetect
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

// MARK: - Hang-safe session factories

/// A busy-shell dummy session so a close routes through the `pendingClose` confirmation guard. Mirrors
/// `DummyPaneSession` exactly, only flipping `isShellBusy` to true.
@MainActor
final class BusyPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false
    var isShellBusy: Bool { true }

    init(spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind == .remoteGUI { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
}

@MainActor
private func makeIdleStore() -> WorkspaceStore {
    WorkspaceStore(
        restoringTree: .defaultWorkspace(), liveModel: .tree,
        makeSession: { spec in DummyPaneSession(spec: spec) },
    )
}

@MainActor
private func makeBusyStore() -> WorkspaceStore {
    WorkspaceStore(
        restoringTree: .defaultWorkspace(), liveModel: .tree,
        makeSession: { spec in BusyPaneSession(spec: spec) },
    )
}

// MARK: - SearchMixer ranking / filtering

@MainActor
final class PaletteMixerTests: XCTestCase {
    private func mixer(_ store: WorkspaceStore) -> SearchMixer {
        SearchMixer(sources: [
            ActionsPaletteSource(),
            TabsPaletteSource.snapshot(store),
            EmptyPaletteSource(filter: .files, sectionTitle: "Files"),
        ])
    }

    func testActionsCatalogIsNonEmptyAndIncludesOpenSettings() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "")
        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains("action.newTerminalTab"))
        XCTAssertTrue(ids.contains("action.openSettings"))
    }

    func testQueryFiltersToMatchingRows() {
        let store = makeIdleStore()
        let results = SearchMixer.selectable(mixer(store).results(query: "split"))
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.title.lowercased().contains("split") })
    }

    func testPrefixOutranksMidWordSubstring() {
        // "New Tab" (title prefix "new") should outrank "New Remote Window Tab" for query "new".
        let store = makeIdleStore()
        let results = SearchMixer.selectable(mixer(store).results(query: "New"))
        let newTabIndex = results.firstIndex { $0.id == "action.newTerminalTab" }
        XCTAssertNotNil(newTabIndex)
        // Exact-ish prefix "New Tab" must be first among the matches.
        XCTAssertEqual(results.first?.id, "action.newTerminalTab")
    }

    func testActiveFilterGatesSourcesToTabsOnly() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "", activeFilter: .tabs)
        // Only the TABS source runs ⇒ no action rows present.
        XCTAssertFalse(results.contains { $0.id.hasPrefix("action.") })
        XCTAssertTrue(results.contains { $0.id.hasPrefix("tab.") })
    }

    func testEmptyStubSourceContributesNoRowsButRegistersFilter() {
        let store = makeIdleStore()
        let m = mixer(store)
        XCTAssertTrue(m.availableFilters.contains(.files))
        // Filtering to Files yields no rows (the stub returns []).
        XCTAssertTrue(m.results(query: "anything", activeFilter: .files).isEmpty)
    }

    func testSectionSeparatorPrecedesEachNonEmptySource() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "") // all sources, no filter
        // The first row of the Actions group is the "Actions" separator.
        XCTAssertEqual(results.first?.isSeparator, true)
        XCTAssertEqual(results.first?.title, "Actions")
        // The TABS source (non-empty: one default pane) gets its own separator too.
        XCTAssertTrue(results.contains { $0.isSeparator && $0.title == "Tabs" })
    }

    func testSelectableExcludesSeparators() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "")
        let selectable = SearchMixer.selectable(results)
        XCTAssertFalse(selectable.contains(where: \.isSeparator))
        XCTAssertLessThan(selectable.count, results.count)
    }
}

// MARK: - PaletteAction routing (running a row mutates the store)

@MainActor
final class PaletteActionRoutingTests: XCTestCase {
    func testRunningSplitRowSplitsTheActivePane() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let split = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.splitRight" })
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        try coordinator.run(XCTUnwrap(split))
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1, "running the split row adds a pane")
        XCTAssertFalse(coordinator.paletteVisible, "running a row closes the palette")
    }

    func testRunningNewTabRowAddsTabAndRecordsRecent() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let newTab = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.newTerminalTab" })
        try coordinator.run(XCTUnwrap(newTab))
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore + 1)
        XCTAssertTrue(store.recentCommands.contains(.newPane(.terminal)), "the verb is recorded into recents")
    }

    func testOpenSettingsRowOpensSettingsAndClosesPalette() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let row = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.openSettings" })
        try coordinator.run(XCTUnwrap(row))
        XCTAssertTrue(coordinator.settingsVisible)
        XCTAssertFalse(coordinator.paletteVisible)
    }

    func testTabsRowFocusesThatPane() throws {
        let store = makeIdleStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteFilter = .tabs
        // Pick the FIRST pane (not currently active — split focuses the new second pane).
        let firstPane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.root.allPaneIDs().first)
        let tabsSource = TabsPaletteSource.snapshot(store)
        let row = try? XCTUnwrap(
            tabsSource.candidates(query: "").first { $0.id == "tab.\(firstPane!.raw.uuidString)" },
        )
        try coordinator.run(XCTUnwrap(row))
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, firstPane)
    }

    func testKeyboardSelectionMoveAndAccept() {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteQuery = "split"
        coordinator.paletteSelection = 0
        let selectable = coordinator.selectableResults
        XCTAssertGreaterThanOrEqual(selectable.count, 1)
        // Move down stays clamped within the selectable rows.
        coordinator.moveSelection(100)
        XCTAssertEqual(coordinator.paletteSelection, selectable.count - 1)
        coordinator.moveSelection(-100)
        XCTAssertEqual(coordinator.paletteSelection, 0)
        // Accept runs the selected row (a split) and closes.
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        coordinator.acceptSelected()
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1)
        XCTAssertFalse(coordinator.paletteVisible)
    }

    func testSeparatorRowIsNoOp() {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let sep = PaletteItem.separator("Actions", filter: .actions)
        coordinator.run(sep)
        XCTAssertTrue(coordinator.paletteVisible, "running a separator does nothing (palette stays open)")
    }

    func testZeroStateSurfacesRecents() {
        let store = makeIdleStore()
        store.recordRecentCommand(.toggleZoom)
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteQuery = ""
        let results = coordinator.paletteResults
        XCTAssertTrue(results.contains { $0.isSeparator && $0.title == "Recents" })
        // The toggle-zoom recent maps onto its catalog row.
        XCTAssertTrue(results.contains { $0.id == "action.toggleZoom" })
    }
}

// MARK: - ConfirmModal flow (pendingCloseSpec confirm / cancel)

@MainActor
final class ConfirmModalFlowTests: XCTestCase {
    func testBusyCloseParksAPendingCloseSpec() throws {
        let store = makeBusyStore()
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.splitActivePane(axis: .horizontal, kind: .terminal) // make it a split so it isn't last
        try store.requestClosePaneTree(XCTUnwrap(pane))
        XCTAssertNotNil(store.pendingCloseSpec, "a busy shell parks the close behind the confirm modal")
    }

    func testCancelClearsThePendingClose() throws {
        let store = makeBusyStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.root.allPaneIDs().first)
        try store.requestClosePaneTree(XCTUnwrap(pane))
        XCTAssertNotNil(store.pendingCloseSpec)
        store.cancelPendingClose()
        XCTAssertNil(store.pendingCloseSpec, "cancel clears the pending close, pane stays")
    }

    func testConfirmClosesThePaneAndClearsThePending() throws {
        let store = makeBusyStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let panes = store.tree.activeSession?.activeTab?.root.allPaneIDs() ?? []
        XCTAssertEqual(panes.count, 2)
        let target = try? XCTUnwrap(panes.first)
        try store.requestClosePaneTree(XCTUnwrap(target))
        XCTAssertNotNil(store.pendingCloseSpec)
        store.confirmPendingClose()
        XCTAssertNil(store.pendingCloseSpec)
        XCTAssertFalse(try store.tree.contains(XCTUnwrap(target)), "confirm actually closes the pane")
    }
}

// MARK: - Toast lifecycle

@MainActor
final class ToastLifecycleTests: XCTestCase {
    func testPushAppendsNewestLast() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "a", title: "A"))
        c.pushToast(Toast(id: "b", title: "B"))
        XCTAssertEqual(c.toasts.map(\.id), ["a", "b"])
    }

    func testSameIdReplaces() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "x", title: "First"))
        c.pushToast(Toast(id: "x", title: "Second"))
        XCTAssertEqual(c.toasts.count, 1)
        XCTAssertEqual(c.toasts.first?.title, "Second")
    }

    func testCapEvictsOldest() {
        let c = OverlayCoordinator()
        for i in 0..<8 { c.pushToast(Toast(id: "t\(i)", title: "T\(i)")) }
        XCTAssertEqual(c.toasts.count, 4, "the stack is capped at 4")
        XCTAssertEqual(c.toasts.first?.id, "t4", "the oldest are evicted")
        XCTAssertEqual(c.toasts.last?.id, "t7")
    }

    func testDismissRemovesById() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "a", title: "A"))
        c.pushToast(Toast(id: "b", title: "B"))
        c.dismissToast("a")
        XCTAssertEqual(c.toasts.map(\.id), ["b"])
    }
}

// MARK: - ContextMenuModel action mapping

@MainActor
final class ContextMenuMappingTests: XCTestCase {
    func testPaneItemsIncludeSplitRenameReconnectClose() {
        let pane = PaneID()
        let items = ContextMenuModel.paneItems(paneID: pane, lastKnownCwd: "~/src", isInSplit: true)
        let ids = Set(items.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "pane.splitRight",
            "pane.splitDown",
            "pane.rename",
            "pane.reconnect",
            "pane.close",
        ]))
        XCTAssertTrue(ids.contains("pane.copyPath"), "a known cwd adds Copy Path")
        // The close row is destructive and labeled "Close Pane" in a split.
        let close = try? XCTUnwrap(items.first { $0.id == "pane.close" })
        XCTAssertEqual(close?.role, .destructive)
        XCTAssertEqual(close?.title, "Close Pane")
    }

    func testPaneCloseLabelIsCloseTabWhenNotInSplit() {
        let items = ContextMenuModel.paneItems(paneID: PaneID(), lastKnownCwd: nil, isInSplit: false)
        let close = try? XCTUnwrap(items.first { $0.id == "pane.close" })
        XCTAssertEqual(close?.title, "Close Tab")
        XCTAssertFalse(items.contains { $0.id == "pane.copyPath" }, "no cwd ⇒ no Copy Path row")
    }

    func testPaneSplitRowMutatesTheStore() throws {
        let store = makeIdleStore()
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let items = try ContextMenuModel.paneItems(paneID: XCTUnwrap(pane), lastKnownCwd: nil, isInSplit: false)
        let split = try? XCTUnwrap(items.first { $0.id == "pane.splitRight" })
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        split?.run?(store)
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1)
    }

    func testTabCloseRowClosesTheTab() throws {
        let store = makeIdleStore()
        store.newTab(kind: .terminal) // now 2 tabs
        let session = try? XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session?.tabs.count, 2)
        let tab = try? XCTUnwrap(session?.activeTab)
        let pane = try? XCTUnwrap(tab?.activePane)
        let items = try ContextMenuModel.tabItems(paneID: XCTUnwrap(pane), tabID: XCTUnwrap(tab?.id))
        let close = try? XCTUnwrap(items.first { $0.id == "tab.close" })
        close?.run?(store)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "closing the tab drops it")
    }

    func testSeparatorsAreNonRunnable() {
        let items = ContextMenuModel.paneItems(paneID: PaneID(), lastKnownCwd: "x", isInSplit: true)
        let separators = items.filter(\.isSeparator)
        XCTAssertFalse(separators.isEmpty)
        XCTAssertTrue(separators.allSatisfy { $0.run == nil })
    }
}
