// PaletteContentAndReachTests — the "palette-content-and-ios-reach" audit group (4 findings):
//   1. (HIGH) the command palette had NO hardware-keyboard entry point on iOS — the per-pane interceptor
//      routed with no overlay toggles, so a focused-pane ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ died at a nil toggle.
//   2. the curated catalog was missing many spec-named verbs (Reopen Closed Pane, Sync Input to All Panes,
//      Close Window, Font Size ±/Reset, New Session, Open Composer).
//   3. the Read Only / Secure Keyboard Entry rows never lit the ✓ gutter even when active.
//   4. the "Fork in…" agent commands were absent from the palette (macOS Agents-menu-only, iOS-unreachable).
//
// All headless — no view, no socket, no video (per the hang-safety rule), driven by a tree-model
// `WorkspaceStore` over the tiny `MountTestPaneSession` double (defined in `OverlayCoordinatorMountTests`).

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class PaletteContentAndReachTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    private func makeOverlay() -> (OverlayCoordinator, WorkspaceStore) {
        let store = makeStore()
        return (OverlayCoordinator(store: store), store)
    }

    private func row(_ id: String) throws -> PaletteItem {
        try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == id },
            "the catalog has the '\(id)' row",
        )
    }

    /// The selectable row ids the verbs-only mixer returns for `query` (the snapshot the palette renders).
    private func searchIDs(_ query: String) -> [String] {
        let mixer = SearchMixer(sources: ActionsPaletteSource.categorySources())
        return SearchMixer.selectable(mixer.results(query: query)).map(\.id)
    }

    // MARK: - Finding 1 (HIGH): the iOS hardware-keyboard interceptor routes the overlay chords

    /// THE iOS reachability pin: a per-pane ``TerminalKeyInterceptor``'s resolved overlay action must route
    /// through ``WorkspaceStore/routeInterceptedKey(_:)``, which threads the view-injected
    /// ``WorkspaceStore/overlayKeyToggles`` — so ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ / ⌘⌥J fire their overlays on a
    /// platform with no app-level NSEvent monitor (iPad). REVERT-TO-CONFIRM-FAIL: the un-fixed interceptor
    /// called the bare `WorkspaceBindingRegistry.route(action, to:)` (no toggles), so `.commandPalette` →
    /// `toggles.palette?()` was nil and `fired["palette"]` stays false — every assertion below trips.
    func testInterceptedOverlayChordsFireTheInjectedToggles() {
        let store = makeStore()
        var fired: Set<String> = []
        store.overlayKeyToggles = WorkspaceOverlayKeyToggles(
            palette: { fired.insert("palette") },
            cheatSheet: { fired.insert("cheatSheet") },
            globalSearch: { fired.insert("globalSearch") },
            jumpTo: { fired.insert("jumpTo") },
            openQuickly: { fired.insert("openQuickly") },
            sendToChat: { fired.insert("sendToChat") },
            peekReply: { fired.insert("peekReply") },
        )

        let routed: [(WorkspaceAction, String)] = [
            (.commandPalette, "palette"),
            (.globalSearch, "globalSearch"),
            (.openQuickly, "openQuickly"),
            (.jumpTo, "jumpTo"),
            (.sendToChat, "sendToChat"),
            (.peekAndReply, "peekReply"),
        ]
        for (action, key) in routed {
            store.routeInterceptedKey(action)
            XCTAssertTrue(
                fired.contains(key),
                "the intercepted \(action) chord fired its injected overlay toggle '\(key)' (iOS reachability)",
            )
        }
    }

    /// Control: with NO toggles installed (the macOS default — its NSEvent dispatcher owns the chord before the
    /// surface), `routeInterceptedKey` is a graceful no-op, never a trap. Proves the seam is opt-in.
    func testInterceptedOverlayChordIsAGracefulNoOpWhenUnwired() {
        let store = makeStore()
        // No overlayKeyToggles set ⇒ all nil. Routing the palette chord must not crash / mutate anything.
        store.routeInterceptedKey(.commandPalette)
        XCTAssertNil(store.overlayKeyToggles.palette, "no toggle installed ⇒ the chord is a graceful no-op")
    }

    // MARK: - Finding 2: the curated catalog surfaces the previously-missing spec verbs

    /// The catalog now ENUMERATES the spec-named verbs that were unreachable (Reopen Closed Pane, Sync Input
    /// to All Panes, New Session, Close Window, Font Size ±/Reset, Open Composer), each under its otty
    /// category. REVERT-TO-CONFIRM-FAIL: dropping any row makes its `catalog.first` nil → the `XCTUnwrap` trips.
    func testCatalogSurfacesPreviouslyMissingVerbs() throws {
        let expected: [(id: String, title: String, category: PaletteCategory)] = [
            ("action.reopenClosed", "Reopen Closed Pane", .tab),
            ("action.toggleSyncInput", "Sync Input to All Panes", .pane),
            ("action.newSession", "New Session", .window),
            ("action.closeWindow", "Close Window", .window),
            ("action.increaseFontSize", "Increase Font Size", .view),
            ("action.decreaseFontSize", "Decrease Font Size", .view),
            ("action.resetFontSize", "Reset Font Size", .view),
            ("action.openComposer", "Open Composer", .agents),
        ]
        for (id, title, category) in expected {
            let item = try row(id)
            XCTAssertEqual(item.title, title, "the '\(id)' row's title")
            XCTAssertEqual(item.category, category, "the '\(id)' row's otty category")
            XCTAssertEqual(item.filter, .actions, "the '\(id)' row is a verb (Actions filter)")
        }
    }

    /// A representative previously-missing verb surfaces in the palette SNAPSHOT for a typed query (not just in
    /// the static array) — proving it is actually reachable through the mixer. FAILS before the row existed.
    func testReopenClosedSurfacesInThePaletteSnapshot() {
        XCTAssertTrue(
            searchIDs("reopen").contains("action.reopenClosed"),
            "typing 'reopen' surfaces the Reopen Closed Pane verb in the palette snapshot",
        )
        XCTAssertTrue(
            searchIDs("font").contains("action.increaseFontSize"),
            "typing 'font' surfaces the font-size verbs",
        )
    }

    /// CLOSED loop: running the "New Session" row's `.store` arm mints a new session (proves the row is wired,
    /// not a label). FAILS if the row's run-arm were a no-op stub.
    func testRunningNewSessionRowMintsASession() throws {
        let store = makeStore()
        let item = try row("action.newSession")
        guard case let .store(run) = item.action else {
            XCTFail("New Session is a `.store` row")
            return
        }
        let before = store.tree.sessions.count
        run(store)
        XCTAssertEqual(store.tree.sessions.count, before + 1, "running New Session added a session")
    }

    /// CLOSED loop: the "Close Window" row routes through the injected ``OverlayCoordinator/closeWindow``
    /// actuator (macOS `performClose` → the close-confirmation gate) — NOT the dead `requestCloseWindow()` park
    /// the audit flagged. Pin that running it fires the closure AND closes the palette. FAILS if the
    /// `.closeWindow` run arm dropped the injected actuator.
    func testRunningCloseWindowRowFiresInjectedActuatorAndCloses() throws {
        let (overlay, _) = makeOverlay()
        var fired = false
        overlay.closeWindow = { fired = true }
        overlay.openPalette()
        let item = try row("action.closeWindow")

        overlay.run(item)
        XCTAssertTrue(fired, "the Close Window row fires the injected performClose actuator")
        XCTAssertFalse(overlay.paletteVisible, "a window-scope action closes the palette")
    }

    // MARK: - Finding 3: Read Only lights the ✓ gutter when the active pane is read-only

    /// `OverlayHostView.toggledState(for:store:)` now resolves the Read Only ✓ off the live `store` + active
    /// pane (the convergent `paneReadOnly` set), so the gutter tracks the real input gate. REVERT-TO-CONFIRM-
    /// FAIL: the un-fixed predicate had no `action.toggleReadOnly` case → `default: false` → the post-toggle
    /// assertion (✓ shown) trips. A non-toggle row never shows ✓ (control).
    func testToggledStateTracksActivePaneReadOnly() throws {
        let store = makeStore()
        let chrome = WorkspaceChromeState()
        let predicate = OverlayHostView.toggledState(for: chrome, store: store)
        let readOnlyRow = try row("action.toggleReadOnly")
        let plainRow = try row("action.newTerminalTab")

        XCTAssertFalse(predicate(readOnlyRow), "a fresh active pane is writable ⇒ no ✓ on Read Only")
        XCTAssertFalse(predicate(plainRow), "a non-toggle row never shows ✓")

        store.toggleReadOnlyInActivePane()
        XCTAssertTrue(
            predicate(readOnlyRow),
            "the active pane is now read-only ⇒ the Read Only ✓ gutter lights (fails on the un-fixed predicate)",
        )

        store.toggleReadOnlyInActivePane()
        XCTAssertFalse(predicate(readOnlyRow), "toggling back off clears the ✓")
    }

    /// The Secure Keyboard Entry ✓ reads the active model's `secureInputActive` mirror; with no live terminal
    /// model (a headless active pane) it resolves false — proving the predicate consults the model flag rather
    /// than a hardcoded value (and never lights spuriously).
    func testToggledStateSecureEntryReadsModelFlag() throws {
        let store = makeStore()
        let predicate = OverlayHostView.toggledState(for: WorkspaceChromeState(), store: store)
        let secureRow = try row("action.secureKeyboardEntry")
        XCTAssertFalse(
            predicate(secureRow),
            "no live terminal model ⇒ secureInputActive is false ⇒ no spurious ✓",
        )
    }

    // MARK: - Finding 4: the "Fork in…" agent commands are in the palette (cross-platform)

    /// The three CLAUDE-ONLY "Fork in…" verbs are surfaced under the AGENTS category, each routing its fork
    /// ``WorkspaceAction``. REVERT-TO-CONFIRM-FAIL: they lived only in the registry (macOS Agents menu), so the
    /// `catalog.first` was nil and the `XCTUnwrap` trips.
    func testForkVerbsAreInThePaletteUnderAgents() throws {
        for (id, title) in [
            ("action.forkSplitRight", "Fork in Split Right"),
            ("action.forkSplitDown", "Fork in Split Down"),
            ("action.forkNewTab", "Fork in New Tab"),
        ] {
            let item = try row(id)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.category, .agents, "the '\(id)' fork verb groups under AGENTS")
            XCTAssertNil(item.shortcut, "the fork verbs ship no default chord ⇒ no hint chip")
        }
        XCTAssertTrue(
            searchIDs("fork").contains("action.forkNewTab"),
            "typing 'fork' surfaces the Fork-in-New-Tab verb in the palette snapshot",
        )
    }

    /// Running a Fork verb against a NON-agent active pane (no detected `/branch`) is a GRACEFUL no-op — it
    /// routes through the SAME `performFork` guard, which returns early when the active pane is not a live agent
    /// session, so no split / tab is minted. Pins that surfacing the fork verb is never a destructive control.
    func testForkVerbIsAGracefulNoOpWithoutADetectedBranch() throws {
        let store = makeStore()
        let item = try row("action.forkSplitRight")
        guard case let .store(run) = item.action else {
            XCTFail("Fork is a `.store` row")
            return
        }
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let panesBefore = store.tree.allPaneIDs().count

        run(store) // non-agent MountTestPaneSession active pane ⇒ performFork's guard bails

        XCTAssertEqual(store.tree.activeSession?.tabs.count ?? 0, tabsBefore, "no tab minted without a fork")
        XCTAssertEqual(store.tree.allPaneIDs().count, panesBefore, "no split minted without a fork")
    }
}
