import XCTest
@testable import AislopdeskWorkspaceCore

/// E12 — the BEHAVIORAL dispatch of the Composer (`⌘⇧E`) / Prompt Queue (`⌘⇧M`) actions through the
/// production ``WorkspaceBindingRegistry/route(_:to:)`` seam, observed on a
/// ``RecordingTerminalPaneSession`` that carries a REAL ``ComposerModel`` + ``TerminalViewModel`` (so the
/// `ComposerProviding` resolution + the `onRequestComposer` / `onRequestPromptQueue` view-focus callbacks
/// are exercised end-to-end WITHOUT a socket or a real renderer).
///
/// REVERT-TO-CONFIRM-FAIL: with the routing stubs left as `case .composer: break` / `.promptQueue: break`
/// the composer never opens and the callbacks never fire — `testComposerActionTogglesActivePaneComposer`
/// and `testPromptQueueActionOpensActivePaneComposer` both fail. `.sendToChat` is the deliberate inert E13
/// stub (a guard test, unchanged before/after).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no GhosttySurface /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class WorkspaceBindingRoutingTests: XCTestCase {
    /// A `.tree`-live store backed by the recording (composer + terminal-model carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's recording session.
    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    // MARK: - .composer (⌘⇧E)

    /// `.composer` TOGGLES the active pane's durable composer visible AND fires the pane's
    /// `onRequestComposer` (the view-focus nudge). A second route toggles it back hidden.
    func testComposerActionTogglesActivePaneComposer() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var requested = 0
        session.terminalModel?.onRequestComposer = { requested += 1 }

        XCTAssertFalse(composer.isVisible, "precondition: the composer starts hidden")

        WorkspaceBindingRegistry.route(.composer, to: store)
        XCTAssertTrue(composer.isVisible, ".composer toggles the active pane's composer VISIBLE")
        XCTAssertEqual(requested, 1, ".composer also fires the pane's onRequestComposer (focus nudge)")

        WorkspaceBindingRegistry.route(.composer, to: store) // ⌘⇧E again
        XCTAssertFalse(composer.isVisible, ".composer again toggles it HIDDEN")
        XCTAssertEqual(requested, 2, "each ⌘⇧E re-fires the focus nudge")
    }

    // MARK: - .promptQueue (⌘⇧M)

    /// `.promptQueue` OPENS (not toggles) the active pane's composer in queue-input mode AND fires the
    /// pane's `onRequestPromptQueue`. A second route leaves it open (open, not toggle).
    func testPromptQueueActionOpensActivePaneComposer() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var queueOpened = 0
        session.terminalModel?.onRequestPromptQueue = { queueOpened += 1 }

        WorkspaceBindingRegistry.route(.promptQueue, to: store)
        XCTAssertTrue(composer.isVisible, ".promptQueue opens the active pane's composer (queue-input mode)")
        XCTAssertEqual(queueOpened, 1, ".promptQueue fires the pane's onRequestPromptQueue")

        WorkspaceBindingRegistry.route(.promptQueue, to: store) // ⌘⇧M again
        XCTAssertTrue(composer.isVisible, ".promptQueue is OPEN (not toggle) — stays visible on repeat")
        XCTAssertEqual(queueOpened, 2, "each ⌘⇧M re-fires the queue-mode focus nudge")
    }

    // MARK: - .sendToChat (E13 — stays inert here)

    /// `.sendToChat` is the deliberate inert E13 stub: routing it has NO composer effect and fires no
    /// composer/queue callback (E12 ships ONLY composer + prompt-queue input mechanics, per E12-carryovers).
    func testSendToChatStaysInert() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var anyCallback = 0
        session.terminalModel?.onRequestComposer = { anyCallback += 1 }
        session.terminalModel?.onRequestPromptQueue = { anyCallback += 1 }

        WorkspaceBindingRegistry.route(.sendToChat, to: store)
        XCTAssertFalse(composer.isVisible, ".sendToChat is an inert stub (E13) — no composer effect")
        XCTAssertEqual(anyCallback, 0, ".sendToChat fires no composer/queue callback")
    }

    // MARK: - .pinWindow (E19 ES-E19-1 / WI-3 — Pin Window)

    /// `.pinWindow` FORWARDS to the passed `togglePinWindow` closure EXACTLY once (the macOS window-level
    /// concern the live app flips `WorkspaceChromeState.pinned` from) and never mutates the tree.
    /// REVERT-TO-CONFIRM-FAIL: with the routing case left `case .pinWindow: break` the closure never fires —
    /// `fired` stays 0 and this fails.
    func testPinWindowRoutesToTheClosureOnce() {
        let store = makeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.pinWindow, to: store, togglePinWindow: { fired += 1 })
        XCTAssertEqual(fired, 1, ".pinWindow invokes togglePinWindow exactly once")
        XCTAssertEqual(store.tree, before, "pinning the window is a view affordance — the tree is unchanged")
    }

    /// `.pinWindow` WITHOUT a `togglePinWindow` closure (the headless / test / iOS default) is a graceful,
    /// non-trapping no-op — never a dead chord, never a tree mutation.
    func testPinWindowWithoutClosureIsAGracefulNoOp() {
        let store = makeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.pinWindow, to: store) // no closure ⇒ no-op
        XCTAssertEqual(store.tree, before, ".pinWindow with no closure leaves the tree unchanged (no trap)")
    }

    /// The `pinWindow` registry binding exists, has the documented id, is in the `.view` category, and is
    /// CHORD-LESS (`chord: nil`) — parity with otty's chord-less "View ▸ Pin Window" (surfaced for
    /// discoverability without binding a key). FAILS on the un-fixed code (no binding) and on a
    /// category / chord regression.
    func testPinWindowBindingExistsIsViewAndChordless() {
        let binding = WorkspaceBindingRegistry.binding(for: .pinWindow)
        XCTAssertNotNil(binding, "a binding exists for Pin Window")
        XCTAssertEqual(binding?.id, "view.pinWindow", "the Pin Window binding has id view.pinWindow")
        XCTAssertEqual(binding?.title, "Pin Window", "the Pin Window binding title is 'Pin Window'")
        XCTAssertEqual(binding?.category, .view, "the Pin Window binding is in the View category")
        XCTAssertNil(binding?.chord, "the Pin Window binding is unbound by default (chord: nil)")
        XCTAssertNil(
            WorkspaceBindingRegistry.glyph(for: .pinWindow),
            "a chord-less binding renders no key glyph (no chord registered)",
        )
    }

    /// Pin Window surfaces in the View display group (palette / cheat sheet) — so it is discoverable even
    /// though it carries no default chord (the chord-less palette/menu-only idiom).
    func testPinWindowSurfacesInTheViewDisplayGroup() {
        let view = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .view }
        let ids = Set(view?.bindings.map(\.id) ?? [])
        XCTAssertTrue(ids.contains("view.pinWindow"), "Pin Window surfaces in the View display group")
    }

    /// `.pinWindow` is a window-scope action — it must NOT require an active pane (so the palette / menu never
    /// grey it out on an empty shell), matching `.toggleDetailsPanel` / `.toggleSidebar`.
    func testPinWindowDoesNotRequireAnActivePane() {
        XCTAssertFalse(
            WorkspaceAction.pinWindow.requiresActivePane,
            "Pin Window is window-scope — needs no active pane",
        )
    }

    /// The CANVAS fallback path (retained-but-dead model) also FORWARDS Pin Window via the closure — pinning
    /// is a window-level concern, not tree-specific, so the canvas route must not drop it. Pins the
    /// `routeCanvas` case FORWARDS (not just compiles the exhaustive switch).
    func testPinWindowRoutesOnCanvasPath() {
        let store = WorkspaceStore(
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
        var fired = 0
        WorkspaceBindingRegistry.route(.pinWindow, to: store, togglePinWindow: { fired += 1 })
        XCTAssertEqual(fired, 1, "the canvas path also forwards Pin Window to the closure")
    }
}
