// WorkspaceKeyDispatcher — the LIVE keybinding dispatcher (WS-B / B3).
//
// THE re-scope: docs/DECISIONS.md previously recorded "there is no NSEvent monitor — a binding absent from
// the menu is a dead chord" (the ⌘⇧I sync-input note). That rule held while every workspace chord was a
// single ⌘/⌥-prefixed shortcut a SwiftUI `.commands` menu could express. The WS-B prefix engine breaks that
// premise: a tmux/zellij-style MULTI-KEY prefix (e.g. ⌃A then D) cannot be expressed by `.keyboardShortcut`,
// and — more importantly — a `.commands` menu cannot SWALLOW the follow-up key BEFORE the terminal first
// responder (libghostty's `GhosttyLayerBackedView`) sees it, so the second key of a sequence would leak into
// the PTY. Hence ONE app-level `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` installed at launch.
// docs/DECISIONS.md is updated to record this re-scope (per CLAUDE.md "update DECISIONS.md when re-scoping").
//
// CONTRACT (the load-bearing rule): a BARE unmodified key MUST pass through untouched — normal typing always
// reaches the PTY/video responder. The monitor only intercepts:
//   • the configured prefix (arm / send-prefix double-tap),
//   • armed-state follow-up keys (resolve a bound chord/sequence, or swallow an unbound one), and
//   • bound single chords (the existing ⌘D/⌘T/… table, override-aware via `resolvedChordTable`).
// Everything else returns the event UNCHANGED so it flows to the focused responder.
//
// PURITY: the NSEvent→`KeyChord` normalization is factored into the pure, AppKit-free `KeyChordNormalizer`
// (mirroring GhosttyTerminalView's `ghosttyMods` + `charactersIgnoringModifiers` for parity) so the chord
// mapping is unit-tested headlessly; the transition logic lives entirely in the pure `PrefixStateMachine`
// (B2). Only the thin NSEvent→intent wiring lives here.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit

/// Owns the app-level `.keyDown` local monitor and the pure `PrefixStateMachine`, turning each keystroke
/// into a `WorkspaceBindingRegistry.route(...)` call (single chord OR completed prefix sequence) or a
/// passthrough. `@MainActor` — installed once at app launch and retained for the process lifetime.
@MainActor
final class WorkspaceKeyDispatcher {
    private let store: WorkspaceStore
    /// The view-overlay toggles `route(...)` takes (palette / cheat sheet / find / peek-reply). The live app
    /// wires these to its `@State`; omitted here keeps those actions graceful no-ops. E1/WI-7 widens the
    /// construction so E2 can thread `toggleFind`/`togglePeekReply` without re-touching this seam (nil OK in
    /// E1 — those overlays don't exist yet, so the corresponding actions stay graceful no-ops via `route`).
    private let togglePalette: (() -> Void)?
    private let toggleCheatSheet: (() -> Void)?
    private let toggleFind: (() -> Void)?
    private let togglePeekReply: (() -> Void)?
    /// E5 / WI-4: the cross-tab Global Search overlay toggle (otty ⇧⌘F). View-overlay state (the
    /// ``OverlayCoordinator``), so it is passed in as a closure like `togglePalette`; `nil` (the headless /
    /// test default) keeps `.globalSearch` a graceful no-op via `route` — never a dead chord.
    private let toggleGlobalSearch: (() -> Void)?
    /// The Details/inspector panel toggle (otty ⌘⇧R). View-owned `@State` (`WorkspaceChromeState`), so it is
    /// passed in as a closure. The chrome state is created INSIDE `WorkspaceRootView` (after the dispatcher is
    /// built at app `init`), so the root view installs the real closure via ``setToggleDetailsPanel(_:)`` on
    /// appear; until then it is `nil` ⇒ `.toggleDetailsPanel` is a graceful no-op (never a dead chord).
    private var toggleDetailsPanel: (() -> Void)?
    /// The left sidebar / Tabs-panel toggle (otty ⌘⇧L). Same view-owned `@State` story as the Details toggle:
    /// the macOS sidebar collapse is `WorkspaceChromeState.sidebarCollapsed` (the native split reads it), NOT
    /// the legacy `store.sidebarCollapsed`, so the root view installs the real closure via
    /// ``setToggleSidebar(_:)`` on appear. Until then `nil` ⇒ `.toggleSidebar` falls back to the store flag in
    /// `route` (a non-trapping graceful op), never a dead chord.
    private var toggleSidebar: (() -> Void)?
    /// The four `Details: *` jump commands' tab selector (E9/WI-7, ES-E9-5). View-owned state
    /// (`DetailsPanelState` + the chrome reveal), so it is installed late by the root view via
    /// ``setSelectDetailsTab(_:)`` once those exist; until then `nil` ⇒ `.selectDetailsTab` is a graceful
    /// no-op (never a dead command).
    private var selectDetailsTab: ((DetailsPanelTab) -> Void)?

    /// The pure prefix machine (B2). Its sequence resolver reads the override-aware `resolvedSequenceTable`
    /// (single-chord fallback to `resolvedChordTable`) so a rebind — single OR multi-key — takes effect; the
    /// prefix chord itself is configurable (defaults to the store's live `workspaceKeyPrefix`).
    private let machine: PrefixStateMachine

    private var monitor: Any?

    /// - Parameter prefix: the configured prefix chord. Pass `nil` (the default) to adopt the store's live
    ///   ``WorkspaceStore/workspaceKeyPrefix`` so the app monitor and the per-surface ``TerminalKeyInterceptor``
    ///   arm on ONE shared, configured prefix (no split-brain when the prefix is moved off ⌃A). An explicit
    ///   value overrides the store (test seam).
    init(
        store: WorkspaceStore,
        prefix: KeyChord? = nil,
        togglePalette: (() -> Void)? = nil,
        toggleCheatSheet: (() -> Void)? = nil,
        toggleFind: (() -> Void)? = nil,
        togglePeekReply: (() -> Void)? = nil,
        toggleDetailsPanel: (() -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        toggleGlobalSearch: (() -> Void)? = nil,
        selectDetailsTab: ((DetailsPanelTab) -> Void)? = nil,
    ) {
        self.store = store
        self.togglePalette = togglePalette
        self.toggleCheatSheet = toggleCheatSheet
        self.toggleFind = toggleFind
        self.togglePeekReply = togglePeekReply
        self.toggleDetailsPanel = toggleDetailsPanel
        self.toggleSidebar = toggleSidebar
        self.toggleGlobalSearch = toggleGlobalSearch
        self.selectDetailsTab = selectDetailsTab
        // The prefix machine resolves a post-prefix key against the override-aware SEQUENCE table FIRST (so a
        // multi-key prefix sequence whose tail key is not a standalone binding still fires), falling back to
        // the SINGLE-CHORD table (so the seeded ⌃A→⌘D, where ⌘D is also a standalone chord, keeps working and
        // an override is honoured). The prefix itself defaults to the store's live `workspaceKeyPrefix`.
        machine = PrefixStateMachine(
            prefix: prefix ?? store.workspaceKeyPrefix,
            resolveAfterPrefix: { chord in WorkspaceBindingRegistry.resolvedChordTable[chord] },
            resolveSequenceAfterPrefix: { sequence in WorkspaceBindingRegistry.resolvedSequenceTable[sequence] },
        )
    }

    /// Re-point the configured prefix (a settings change moved it off ⌃A). Keeps the app monitor and the
    /// per-surface interceptors arming on ONE shared prefix.
    func setPrefix(_ chord: KeyChord) { machine.prefix = chord }

    /// Install the Details/inspector toggle once the `WorkspaceChromeState` exists (the root view wires this
    /// to `chrome.toggleInspector` on appear). Without it, ⌘⇧R resolves to `.toggleDetailsPanel` and is
    /// swallowed but no-ops — so the titlebar SwiftUI shortcut can't own it either; this closure makes ⌘⇧R
    /// actually toggle the Details panel (otty parity).
    func setToggleDetailsPanel(_ toggle: @escaping () -> Void) { toggleDetailsPanel = toggle }

    /// Install the left sidebar / Tabs-panel toggle once the `WorkspaceChromeState` exists (the root view
    /// wires this to `chrome.toggleSidebar` on appear). Without it, ⌘⇧L resolves to `.toggleSidebar` and
    /// `route` falls back to the legacy `store.sidebarCollapsed` (which nothing reads on macOS) — so this
    /// closure makes ⌘⇧L actually collapse the native sidebar item (otty "Toggle Tabs Panel" parity).
    func setToggleSidebar(_ toggle: @escaping () -> Void) { toggleSidebar = toggle }

    /// Install the `Details: *` tab selector once the `DetailsPanelState` + `WorkspaceChromeState` exist (the
    /// root view wires this to a closure that sets the tab AND reveals the panel). Without it, a routed
    /// `.selectDetailsTab(_:)` resolves but no-ops — so the four commands stay live (never dead) yet inert
    /// until the view installs the closure.
    func setSelectDetailsTab(_ select: @escaping (DetailsPanelTab) -> Void) { selectDetailsTab = select }

    /// Install the `.keyDown` local monitor. Returning `nil` from the handler SWALLOWS the event; returning
    /// the event passes it through to the focused responder (the terminal / video pane).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
    }

    /// Remove the monitor (app-lifetime in practice, so rarely called — exposed for completeness / tests).
    /// No `deinit`-time removal: the monitor captures `self` weakly and the dispatcher lives for the whole
    /// process, and a `nonisolated deinit` cannot touch the non-`Sendable` monitor token anyway.
    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Map one `NSEvent` keystroke to swallow (`nil`) or pass-through (the event), routing any resolved
    /// action through `WorkspaceBindingRegistry.route(...)`. Pure transition logic lives in the machine; this
    /// only does NSEvent→chord normalization + the intent→effect wiring.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // A keystroke that does not normalize to a chord we model (a pure modifier, a dead key, …) is left
        // untouched — never swallow what we cannot classify.
        guard let chord = KeyChordNormalizer.chord(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifierFlags: KeyChordNormalizer.Modifiers(
                shift: event.modifierFlags.contains(.shift),
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                command: event.modifierFlags.contains(.command),
            ),
        ) else { return event }

        switch machine.feed(chord, at: ProcessInfo.processInfo.systemUptime) {
        case let .passthrough(passed):
            // E1/WI-7: a user `text:`/`csi:`/`esc:` config binding (otty literal-byte bindings) resolves
            // BEFORE the action table — the chord sends its already-resolved bytes (ESC/CSI lead bytes baked
            // in by `KeybindGrammar`) to the focused pane and is swallowed.
            if let textBinding = WorkspaceBindingRegistry.textBinding(for: passed) {
                if let active = activePaneID {
                    store.handle(for: active)?.sendBytes(textBinding.payload)
                }
                return nil // swallow — the text binding owns this chord
            }
            // An `unbind:` target suppresses its DEFAULT action: pass the event straight through to the
            // focused responder (the terminal/video pane handles it) instead of firing the registry action.
            if WorkspaceBindingRegistry.isUnbound(passed) {
                return event
            }
            // Idle + an unbound key: a workspace single chord still resolves here (the machine only owns the
            // prefix-sequence path). A plain/Ctrl-letter the table does not bind falls through to the PTY.
            if let action = WorkspaceBindingRegistry.resolvedChordTable[passed] {
                dispatch(action)
                return nil // swallow — the workspace owns this chord
            }
            return event // bare typing / unbound chord → reaches the focused responder UNCHANGED

        case .consumedArm:
            return nil // armed on the prefix; swallow it (never leak the prefix to the terminal)

        case let .resolved(action):
            dispatch(action)
            return nil // a bound key resolved while armed → run + swallow

        case .sendPrefixLiteral:
            // Double-tap the prefix (tmux `send-prefix`): emit the literal prefix byte to the focused pane,
            // then swallow. The prefix chord's C0 byte is what the terminal would have received raw.
            if let bytes = KeyChordNormalizer.literalBytes(for: machine.prefix),
               let active = activePaneID
            {
                store.handle(for: active)?.sendBytes(bytes)
            }
            return nil

        case .disarmSwallow:
            return nil // an unbound key while armed (tmux-faithful: disarm + eat the key, prefix not replayed)
        }
    }

    /// The active pane id (the send-prefix-literal target). `nil` when no pane is focused (the send is then a
    /// no-op, which is correct — there is nothing to type into).
    private var activePaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func dispatch(_ action: WorkspaceAction) {
        WorkspaceBindingRegistry.route(
            action,
            to: store,
            togglePalette: togglePalette,
            toggleCheatSheet: toggleCheatSheet,
            toggleFind: toggleFind,
            togglePeekReply: togglePeekReply,
            toggleDetailsPanel: toggleDetailsPanel,
            toggleSidebar: toggleSidebar,
            toggleGlobalSearch: toggleGlobalSearch,
            selectDetailsTab: selectDetailsTab,
        )
    }
}
#endif
