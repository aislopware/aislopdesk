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
/// and `testPromptQueueActionOpensActivePaneComposer` both fail. `.sendToChat` (E13 WI-5) forwards to the
/// VIEW-owned dialog toggle, so with NO toggle passed here it must have no composer side-effect (a guard).
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

    // MARK: - C4 / C5: hint-mode + copy-mode arm NUDGE first responder to the active terminal

    /// C4 — `.hintToOpen` arms hint mode AND fires the active terminal's `onRequestFocus` (the first-responder
    /// nudge). Without it, if focus was elsewhere (sidebar / settings) when ⌘⇧… fired, Escape never reaches the
    /// renderer's `keyDown` → `cancelHintMode()`, so the hint badge could never be dismissed.
    /// REVERT-TO-CONFIRM-FAIL: with the arm left `case .hintToOpen: store.activeTerminalModel?.beginHint(.open)`
    /// (no focus nudge) `focused` stays 0 and this fails.
    func testHintToOpenNudgesFocusToTheActiveTerminal() throws {
        let store = makeStore()
        let session = try activeSession(store)
        var focused = 0
        session.terminalModel?.onRequestFocus = { focused += 1 }

        WorkspaceBindingRegistry.route(.hintToOpen, to: store)
        XCTAssertEqual(focused, 1, ".hintToOpen nudges first responder to the terminal so Escape can dismiss (C4)")
    }

    /// C5 — `.toggleCopyMode` arms copy-mode AND fires the active terminal's `onRequestFocus`, so Escape reaches
    /// `keyDown` → `exitCopyMode()` even when focus was elsewhere when the chord fired (the vi/copy-mode pill
    /// could otherwise never be dismissed via Escape). REVERT-TO-CONFIRM-FAIL: with the arm left
    /// `case .toggleCopyMode: store.requestCopyModeInActivePane()` (no focus nudge) `focused` stays 0 and this fails.
    func testToggleCopyModeNudgesFocusToTheActiveTerminal() throws {
        let store = makeStore()
        let session = try activeSession(store)
        var focused = 0
        session.terminalModel?.onRequestFocus = { focused += 1 }

        WorkspaceBindingRegistry.route(.toggleCopyMode, to: store)
        XCTAssertEqual(focused, 1, ".toggleCopyMode nudges first responder to the terminal so Escape can dismiss (C5)")
    }

    // MARK: - .sendToChat (E13 WI-5 — forwards to the view dialog toggle, no direct composer effect)

    /// `.sendToChat` (E13 WI-5) opens the view-owned Send-to-Chat DIALOG via a passed-in toggle — it never
    /// touches the active pane's composer directly. So routing it with NO toggle (this call) has no composer
    /// effect and fires no composer/queue callback (the dialog, not this action, drives any composer send).
    func testSendToChatHasNoDirectComposerEffect() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        var anyCallback = 0
        session.terminalModel?.onRequestComposer = { anyCallback += 1 }
        session.terminalModel?.onRequestPromptQueue = { anyCallback += 1 }

        WorkspaceBindingRegistry.route(.sendToChat, to: store) // no toggle ⇒ graceful no-op
        XCTAssertFalse(composer.isVisible, ".sendToChat has no DIRECT composer effect (it opens the dialog)")
        XCTAssertEqual(anyCallback, 0, ".sendToChat fires no composer/queue callback")
    }

    /// `.sendToChat` WITH a `toggleSendToChat` closure FORWARDS to it EXACTLY once (the live wiring the app
    /// threads from `WorkspaceKeyDispatcher` / `WorkspaceCommands` so ⌘⌃↩ + the Agents ▸ Send to Chat menu row
    /// actually open the dialog). REVERT-TO-CONFIRM-FAIL: with the route arm left `case .sendToChat: break` the
    /// closure never fires — `fired` stays 0 and this fails. Pairs with the no-toggle guard above: together they
    /// prove the chord is LIVE when wired and a graceful no-op when not (never a dead chord).
    func testSendToChatRoutesToTheToggleOnce() throws {
        let store = makeStore()
        let session = try activeSession(store)
        let composer = try XCTUnwrap(session.composer)
        let before = store.tree
        var fired = 0

        WorkspaceBindingRegistry.route(.sendToChat, to: store, toggleSendToChat: { fired += 1 })

        XCTAssertEqual(fired, 1, ".sendToChat invokes toggleSendToChat exactly once")
        XCTAssertFalse(composer.isVisible, "...and STILL has no direct composer effect (the dialog owns the send)")
        XCTAssertEqual(store.tree, before, "opening the dialog is a view affordance — the tree is unchanged")
    }

    // MARK: - E13 WI-5: capture → agentChatSessions() → sendChatMessage() → focus (the full store flow)

    /// THE integration pin (ES-E13-5): the active pane's SELECTION is captured, the Claude-only agent panes are
    /// the only `agentChatSessions()` targets, and `sendChatMessage(_:to:)` delivers the VERBATIM payload to the
    /// CHOSEN target's composer out-sink AND auto-switches focus to it — leaving the source pane untouched. This
    /// is the seam the Send-to-Chat dialog binds; it FAILS on the un-wired code (no capture method, an empty
    /// picker, or a send that never reached the composer / never re-focused).
    func testCaptureAgentSessionsSendAndFocusEndToEnd() throws {
        let store = makeStore()
        // The active (first) pane is the SOURCE — stage a mouse-made selection to quote.
        let source = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let sourceSession = try XCTUnwrap(store.handle(for: source) as? RecordingTerminalPaneSession)
        sourceSession.surfaceRecorder?.selectionText = "let answer = 42"

        // A SECOND pane that hosts a live Claude agent — the only valid Send-to-Chat target.
        store.newTab(kind: .terminal)
        let target = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let targetSession = try XCTUnwrap(store.handle(for: target) as? RecordingTerminalPaneSession)
        targetSession.agentActive = true
        store.focusPaneTree(source) // capture reads the ACTIVE pane's selection

        // Capture: the active pane's selection wins (the primary otty path).
        let context = try XCTUnwrap(store.captureSendToChatContext(), "a live selection yields a capture")
        XCTAssertEqual(context.quoted, "let answer = 42", "the captured quote is the verbatim selection")

        // Picker: ONLY the live agent pane is offered (the non-agent source is excluded; Claude-only badge).
        let sessions = store.agentChatSessions()
        XCTAssertEqual(sessions.map(\.id), [target], "only the live agent pane is a Send-to-Chat target")
        XCTAssertEqual(sessions.first?.agentLabel, "Claude Code", "the picker badge is Claude-only")

        // Send: the composed message lands on the TARGET's composer out-sink VERBATIM, and focus switches there.
        let message = SendToChatModel.compose(context: context, comment: "please review")
        XCTAssertTrue(store.sendChatMessage(message, to: target), "the live agent composer accepted the message")
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, target,
            "sendChatMessage auto-switches focus to the target pane (the spec's final-frame tab switch)",
        )
        XCTAssertEqual(
            targetSession.sentInput.last, SendToChatModel.payload(for: message),
            "the VERBATIM Send-to-Chat payload landed on the chosen agent pane's ordered-OUT sink",
        )
        XCTAssertTrue(sourceSession.sentInput.isEmpty, "nothing was injected into the SOURCE pane")
    }

    /// The no-selection case (M1 fix): with NO selection the capture is `nil` (the dialog stays closed — the
    /// honest no-op), EVEN when a completed command block exists. The send-to-chat spec's no-selection fallback
    /// is the last command's OUTPUT body, which is NOT available synchronously here (async OSC-133 wire
    /// round-trip); quoting the command LINE instead would mislead (it sends the command you typed, not its
    /// output), so the fallback is DISABLED rather than quoting the wrong text.
    /// REVERT-TO-CONFIRM-FAIL: the pre-fix code passed `blocks.latest?.commandText` as `lastOutput`, so the
    /// command-block branch returned a non-nil context quoting "npm test" — the second `XCTAssertNil` fails.
    func testCaptureReturnsNilWithoutSelectionEvenWithACommandBlock() throws {
        let store = makeStore()
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)

        // No selection, no block → nothing to quote.
        session.surfaceRecorder?.selectionText = nil
        XCTAssertNil(store.captureSendToChatContext(), "no selection + no command block ⇒ no capture (no-op)")

        // A completed command block must NOT become a (wrong) command-LINE quote — the fallback is disabled.
        model.blocks.upsert(
            index: 1, commandText: "npm test", exitCode: 0, durationMS: 10, complete: true, outputLen: 0,
        )
        XCTAssertNil(
            store.captureSendToChatContext(),
            "no selection ⇒ still no capture: the command LINE is the wrong text and the OUTPUT body is async",
        )

        // The selection path (the faithful common case) is unchanged — a real selection still captures.
        session.surfaceRecorder?.selectionText = "let answer = 42"
        let captured = try XCTUnwrap(store.captureSendToChatContext(), "a live selection still yields a capture")
        XCTAssertEqual(captured.quoted, "let answer = 42", "the selection path is untouched by the fallback fix")
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
