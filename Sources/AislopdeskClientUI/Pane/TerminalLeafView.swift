// TerminalLeafView — the content of a terminal pane leaf (REBUILD-V2, L2 MINIMAL). Composes, top→bottom:
//   [ terminal surface seam (TerminalRendererFactory.make — the SEAM, else BuildStatusPlaceholderView) ]
//   [ PromptQueueStrip — chips above the Composer (E12; self-hides when the queue is empty)            ]
//   [ ComposerBar — the ⌘⇧E / ⌘⇧M Composer + Prompt-Queue input (E12; mounted only when visible)       ]
// The resting window shows NO persistent cwd chrome — the working-directory chip only appears in
// menus/overlays — so there is no bottom cwd pill here. The bottom command `InputBar` is likewise NOT
// persistently mounted: there is no persistent composer in the resting window; it toggles into view with ⌘⇧E.
// The E12 ``ComposerBar`` reflows in below the surface ONLY while the durable ``ComposerModel/isVisible``
// (and the queue strip while items are pending), exactly as `composer.png` shrinks the terminal to make room.
//
// SEAM usage: the terminal pixels come from `TerminalRendererFactory.make(model:isFocused:)`. The Xcode
// app target injects the production `GhosttyTerminalView`; a headless `swift build` registers no factory,
// so we mount `BuildStatusPlaceholderView` instead — this library NEVER imports libghostty/Metal.
//
// Lazy connect: `live.connection?.connect()` is called in a `.task` on appear (so restoring N panes does
// not slam N sockets). The whole leaf is keyed `.id(PaneID)` by the caller (PaneContainer) so the surface
// / connection is never reused across panes (identity hazard). SYSTEM colours only.
//
// E13 WI-4 (ES-E13-4): the `AgentInputFooterView` (Claude bottom bar) now mounts agent-gated at the pane
// bottom (just above the status bar) over a per-leaf `AgentInputFooterCoordinator`; its "File explorer" pill
// reveals an embedded file panel (so the side-panel-beside-the-surface idea is folded into the footer).
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L3): the `TerminalBlocksView` command-block decoration overlay.

#if canImport(SwiftUI)
import AislopdeskAgentDetect // E13 WI-4: `ClaudeStatus` — the agent-gate for the Claude bottom-bar mount.
import AislopdeskWorkspaceCore
import Defaults // E17 ES-E17-4 / WI-7: observe the Auto-Secure-Input / indicator defaults so the toggle is LIVE.
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct TerminalLeafView: View {
    /// The live session backing this pane (terminal model + input bar). When `nil` (no live handle yet, or
    /// a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// E10 WI-4 (ES-E10-3): the host-reported working directory (`PaneSpec.lastKnownCwd`, live-set from OSC 7)
    /// for the bottom status bar's left field. Resolved by ``PaneContainer`` from the store's spec so it stays
    /// reactive; `nil` until the host first reports a cwd.
    let cwd: String?
    /// E10 WI-4 (ES-E10-3): the app-global connection host (`ConnectionTarget.host`) for the status bar's
    /// right field. Empty when not yet connected / unknown (the strip then omits the host).
    let host: String

    /// E10 WI-10 (G8): the live workspace store — the only thing the per-pane Command Navigator (⌃⌘O) needs
    /// the leaf to carry. Its row jump routes through ``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)``
    /// (the shared ``BlockJump`` re-anchor engine, which resolves the ACTIVE pane = the pane the navigator is
    /// over). Passed down from ``PaneContainer`` (which already owns it).
    let store: WorkspaceStore

    /// E5 ES-E5-1..4: the in-pane ⌘F find bar's view-model (pure ``TerminalSearchController`` + the libghostty
    /// `search:` passthrough). Owned per-leaf and wired to the pane's `onRequestFind*` callbacks in `.task`;
    /// the leaf is `.id(PaneID)`-keyed by `PaneContainer`, so this `@State` is per-pane (no cross-pane bleed).
    @State private var findBar = TerminalFindBarModel()

    /// E12: the per-leaf Composer chrome (queue-input mode + focus token) the pane's `onRequestComposer` /
    /// `onRequestPromptQueue` callbacks mutate. Per-pane (`.id(PaneID)`-keyed leaf) — never the DURABLE
    /// ``ComposerModel``'s concern (that lives on the live session so the draft survives tab switches).
    @State private var composerChrome = ComposerLeafChrome()

    /// E17 ES-E17-4 / WI-7: the per-pane macOS Secure Keyboard Entry actuator. Driven (in `wirePaneCallbacks`)
    /// from the pane model's `onHostEchoChanged` (auto, on a host no-echo password prompt) + the manual
    /// `onManualSecureInputChanged` toggle, it engages / disengages process-global `EnableSecureEventInput`
    /// with a strict single-reference balance. It also observes the app-frontmost edge (see
    /// ``SecureKeyboardEntryController/observeAppActivity()``), so the lock is released whenever aislopdesk is
    /// backgrounded / window-resigned and re-acquired on return — never leaked to other apps' keyboards. Per-pane
    /// (`.id(PaneID)`-keyed leaf), torn down on disappear so the lock can never leak past a pane close either.
    /// Inert off macOS (the controller is a no-op).
    @State private var secureInput = SecureKeyboardEntryController()

    /// E17 ES-E17-4 / WI-7: the LIVE "Auto Secure Input" setting, OBSERVED here (not just read at wire time) so a
    /// Settings toggle reconciles every open pane immediately. Reading it as `@Default` registers observation, so
    /// the body re-renders on the change edge and ``onChange(of:)`` pushes the new value into this pane's
    /// ``SecureKeyboardEntryController`` (releasing an engaged process-global lock when turned OFF) AND the pane
    /// model's pill mirror — the "live" contract the Settings footer claims (the E17 carryover footgun).
    @Default(.autoSecureInput) private var autoSecureInput
    /// E17 ES-E17-4 / WI-7: the LIVE "Show Secure Input Indicator" setting. OBSERVED so flipping it re-renders the
    /// leaf and `showSecureInputPill` (which reads ``SettingsKey/secureInputIndicatorEnabled``) re-evaluates at
    /// once — turning the pill off mid-prompt without waiting for a pane swap or the next echo edge.
    @Default(.secureInputIndicator) private var secureInputIndicator

    /// E10 WI-10 (G8): the per-leaf Command Navigator (⌃⌘O) chrome the pane model's `onRequestBlockNavigator`
    /// callback TOGGLES (the seam doc: "show/hide"). A reference type so the `@MainActor` closure can flip it
    /// (the find-bar / Composer idiom); per-pane (`.id(PaneID)`-keyed leaf), so no cross-pane bleed, and the
    /// modal only ever opens over the pane whose model the store fired — i.e. the active pane.
    @State private var navigatorChrome = CommandNavigatorChrome()

    /// E10 WI-7 (ES-E10-2 / ES-E10-6): the single overlay coordinator, used ONLY to surface a transient
    /// error toast when a host open/reveal RPC fails (the path is gone / open failed / the reply dropped) —
    /// so the action is never a SILENT no-op. `nil` outside the app scene root (tests/previews) ⇒ the failure
    /// is simply swallowed there, never a crash.
    @Environment(\.overlayCoordinator) private var overlayCoordinator

    /// E13 WI-4: the single live ``PreferencesStore`` (injected once at the scene root) the
    /// ``AgentInputFooterCoordinator`` needs for the green-suggestion-chip enable/dismiss persistence (W4).
    /// `nil` outside the app scene (tests/previews) ⇒ the chip shows by default and a click is a no-op
    /// persistence-wise (the coordinator tolerates a `nil` store), never a crash.
    @Environment(\.preferencesStore) private var preferencesStore

    /// E13 WI-4: the per-leaf Claude bottom-bar coordinator (the single ``AgentInputFooterAction`` dispatch
    /// site). Built + wired in `wireAgentFooter()` on appear / live-session swap and torn down on disappear;
    /// the footer VIEW mounts over it only while this pane hosts a detected agent (`showAgentFooter`). Per-pane
    /// (`.id(PaneID)`-keyed leaf), so no cross-pane bleed.
    @State private var agentFooter: AgentInputFooterCoordinator?

    var body: some View {
        VStack(spacing: 0) {
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Inner breathing room so the terminal content doesn't sit flush against the pane edges /
                // the split divider (issue: "thêm padding vào các pane"). The `NativePaneColor.terminalBackground`
                // on the VStack fills the inset gutter, so the pane stays flat (no card). NB this insets the
                // libghostty surface, so the host PTY grid loses ~1 col/row each side — it reflows through the
                // existing PaneContainer.size → resize-scrim → host TIOCSWINSZ path, no new signal needed.
                .padding(Slate.Metric.space2)
            bottomComposer
            // E13 WI-4 (ES-E13-4): the Claude bottom bar — mounted agent-gated (`claudeStatus != .none`)
            // just ABOVE the status bar, so it reflows in below the surface exactly like the Composer. The
            // coordinator is built in `wireAgentFooter()`; the leaf-side `showAgentFooter` gate is the single
            // mount decision (an unmounted coordinator is a silent no-op — E2/OverlayCoordinator lesson).
            if showAgentFooter, let agentFooter {
                AgentInputFooterView(coordinator: agentFooter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // NO per-pane status strip on a TERMINAL pane (issue: "pane footer cho terminal không có giá trị
            // gì lắm, nên bỏ đi"). The cwd / exit / progress cues are low-value chrome; the host + connection
            // status — the only fields common to EVERY pane — now live ONCE in the sidebar's connection header
            // (`NavigatorColumn` → `ConnectionStatusPill`), not duplicated per pane. The GUI/window pane keeps
            // a bottom bar, but as a CONTROL bar (resize / lock / zoom), not a status strip.
        }
        .background(NativePaneColor.terminalBackground)
        .task(id: live?.id) { await connectIfNeeded() }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G + ⌘⇧E / ⌘⇧M callbacks on appear AND on every live-session swap
        // (`initial: true` fires once up-front, then on each `live?.id` change). A synchronous `@MainActor`
        // closure — no actor hop, unlike the `@Sendable async` `.task` action above.
        .onChange(of: live?.id, initial: true) { wirePaneCallbacks() }
        // E17 ES-E17-4 / WI-7: keep Secure Input LIVE to a Settings toggle. `wireSecureInputCallbacks()` only
        // re-syncs the controller on a pane swap (the `live?.id` change above), so without this an engaged
        // process-global lock + the pill would linger past the user turning "Auto Secure Input" OFF — the exact
        // carryover footgun. Pushing the new value into BOTH the controller (releases the lock on the OFF edge)
        // AND the model's pill mirror reconciles them immediately. The indicator change needs no push — reading
        // `secureInputIndicator` as `@Default` already re-renders `showSecureInputPill`; the reconcile keeps the
        // model mirror authoritative if a future read moves off the live setting.
        .onChange(of: autoSecureInput) { reconcileSecureInputSetting() }
        // E10 WI-5 (ES-E10-4): mirror the host-reported cwd onto the model so the AppKit renderer's ⌘-hover
        // hit-test can resolve a RELATIVE detected path to its absolute form for the status-bar preview. The
        // cwd arrives reactively from `PaneContainer` (OSC 7) and changes independently of the live-session id,
        // so it gets its own `onChange`; `initial: true` seeds it once on mount. No-op when no model yet.
        .onChange(of: cwd, initial: true) {
            live?.terminalModel?.linkCwd = cwd
            // E13 WI-4: keep the footer's file-explorer bound to the live cwd so an open panel follows `cd`.
            agentFooter?.updateCwd(cwd)
        }
        // Clear the callbacks when the leaf is torn down so a dead `@State` holder can't be driven by a
        // surviving model (the model is owned by the live session, which can outlive this `.id(PaneID)` leaf).
        .onDisappear { clearPaneCallbacks() }
        .animation(Slate.Anim.reveal, value: live?.composer?.isVisible)
        .animation(Slate.Anim.reveal, value: showAgentFooter)
    }

    /// The bottom Composer chrome — the Prompt-Queue chip strip + the ``ComposerBar``, reflowed in below the
    /// terminal surface. Mounted only when the durable Composer is visible OR has queued items, and ONLY when
    /// it is not pinned / floating (pin + float promote the Composer OUT of the pane subtree to a window-level
    /// / float mount, WI-6). The strip self-hides when the queue is empty, so a visible-but-empty Composer
    /// shows just the bar. Never in the static-mirror snapshot path.
    @ViewBuilder private var bottomComposer: some View {
        if let composer = live?.composer, mountBottomComposer(composer) {
            VStack(spacing: 0) {
                PromptQueueStrip(composer: composer)
                if composer.isVisible {
                    ComposerBar(composer: composer, chrome: composerChrome, maxLines: composerMaxLines)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Whether the Claude bottom bar (E13 WI-4) mounts: a live terminal pane, NOT the static-mirror snapshot
    /// path, and a detected agent in this pane (the host's type-27 verdict lifted ``LivePaneSession/claudeStatus``
    /// off `.none`). Reading the OBSERVABLE `claudeStatus` here re-renders the leaf so the footer reveals the
    /// instant a `claude` is detected (and tears down when it leaves). E13 is Claude-only, so the gate is the
    /// generic `claudeStatus != .none` (no `AgentKind.codex` is ever surfaced — carryover constraint #1).
    private var showAgentFooter: Bool {
        !staticMirror && live?.terminalModel != nil && live?.claudeStatus != ClaudeStatus.none && agentFooter != nil
    }

    /// Whether the in-pane Composer chrome should mount: a live terminal pane, not the static mirror, the
    /// Composer not promoted out (pin/float), and either visible or holding queued chips.
    private func mountBottomComposer(_ composer: ComposerModel) -> Bool {
        guard !staticMirror, live?.terminalModel != nil else { return false }
        guard !composer.isPinned, !composer.isFloating else { return false }
        return composer.isVisible || !composer.promptQueue.isEmpty
    }

    /// The Composer field's growing line budget, derived from the `composerMaxHeight` pref (a fraction of the
    /// pane height) against a reference pane of ~32 rows, clamped to a sane `4…24`. A geometry-exact
    /// pane-height fraction is a documented refinement (WI-5 keeps the InputBar line-limit idiom — lowest risk).
    private var composerMaxLines: Int {
        let lines = Int((SettingsKey.composerMaxHeightFraction * 32).rounded())
        return min(24, max(4, lines))
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam. The E17 vi-mode
    /// pill, the `🔒 READ ONLY ×` pill and the ⌘F find bar float top-trailing OVER the surface (none reflow the
    /// buffer), stacked in one overlay so they never collide; the E17 vi key-hint bar floats along the bottom —
    /// never in the static-mirror snapshot path.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                if TerminalRendererFactory.shared != nil {
                    TerminalRendererFactory.make(model: model, isFocused: isFocused)
                } else {
                    BuildStatusPlaceholderView(model: model)
                }
                // E10 WI-5 (ES-E10-1): the ⌘-hold link underline, layered as a DECORATION overlay over the
                // surface (never a content branch — libghostty-freeze guardrail). Coincident with the surface
                // (both fill this top-leading ZStack), so the WI-2 cell metrics (origin 0,0 = surface top-left)
                // map straight to the Canvas. Inert unless the renderer set `linkHighlightActive` (macOS ⌘);
                // a placeholder surface does not conform to the viewport seam, so it draws nothing.
                if !staticMirror {
                    LinkHighlightOverlay(model: model, cwd: cwd)
                }
                // E10 WI-9 (ES-E10-6): the Vimium Hint Mode overlay — dims the surface + draws yellow 2-letter
                // labels when armed (⌘⇧J open / ⌘⇧Y copy / reveal). Also a DECORATION overlay coincident with
                // the surface (origin 0,0). Inert unless the renderer armed `hintMode` (or an iOS tap-on-label);
                // a placeholder surface does not conform to the viewport seam, so it draws nothing.
                if !staticMirror {
                    HintModeOverlay(model: model)
                }
                // E10 WI-10 (G8): the Command Navigator (⌃⌘O) — a scrimmed, centered card over the surface
                // listing the pane's recent OSC-133 command blocks (search + All/Failed/Bookmarked filter),
                // jumping the scrollback on ↩. Toggled by the pane model's `onRequestBlockNavigator` (wired in
                // `wireNavigatorCallbacks`); the store fires that only on the ACTIVE pane, so this card only
                // mounts over the focused pane. Never in the static-mirror snapshot path.
                if !staticMirror, navigatorChrome.isVisible {
                    CommandNavigatorView(
                        model: model,
                        store: store,
                        onClose: { navigatorChrome.isVisible = false },
                    )
                    .transition(.opacity)
                }
                // TODO(L3): layer `TerminalBlocksView` here as a decoration OVERLAY (never a content
                // branch — libghostty-freeze guardrail).
            } else {
                Color.clear
            }
        }
        // ONE top-trailing overlay holds the vi-mode pill (E17 WI-5), the read-only pill (E17 WI-3), the
        // SECURE INPUT pill (E17 WI-7) and the find bar (E5), stacked top→down so an open find bar reflows
        // BELOW the persistent pills instead of overlapping them. aislopdesk has no persistent titlebar, so
        // the pane's top-trailing overlay hosts these pills directly (see `PaneStatusPills.swift` /
        // `ViModeOverlay.swift`). The vi pill and the read-only pill are mutually exclusive by construction —
        // `showReadOnlyPill` is gated `!copyModeBadgeActive`, so the lock pill steps aside while vi mode owns
        // the slot.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Slate.Metric.space2) {
                if !staticMirror, showViModePill, let model = live?.terminalModel {
                    ViModePill(model: model, onExit: { model.exitCopyMode() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, showReadOnlyPill {
                    ReadOnlyPill(onDeactivate: { live?.terminalModel?.exitReadOnly() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, showSecureInputPill {
                    SecureInputPill()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !staticMirror, findBar.visible, live?.terminalModel != nil {
                    TerminalFindBar(model: findBar)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(Slate.Metric.space2)
        }
        // The vi key-hint bar (E17 WI-5) floats along the pane BOTTOM (the vi-mode spec's likely position) when
        // `⌘/` has toggled it on during a vi session — `showViHintBar` gates it on `copyModeBadgeActive` so it
        // tears down the instant vi mode exits (which also resets `showViKeyHints`).
        .overlay(alignment: .bottom) {
            if !staticMirror, showViHintBar {
                ViKeyHintBar()
                    .padding(Slate.Metric.space2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // E16 WI-9: the command-replay banner floats along the pane TOP (clear of the top-trailing pills) while
        // a recipe replay in THIS pane is waiting on the user — Ask-Once (the default for opened files) before
        // its single run, Manually before each command, or a shell-handoff pause. It is the ONLY live caller of
        // `continueRecipeReplayInActivePane()`; without it those two modes queue their commands and never run.
        // `RecipeReplayHUD` self-hides when `recipeReplayPrompt` is nil, but the leaf-side `showReplayHUD` gate
        // drives the reveal/teardown animation (and keeps it out of the static-mirror snapshot path).
        .overlay(alignment: .top) {
            if showReplayHUD, let id = live?.id {
                RecipeReplayHUD(store: store, paneID: id)
                    .padding(Slate.Metric.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Slate.Anim.reveal, value: findBar.visible)
        .animation(Slate.Anim.reveal, value: showReadOnlyPill)
        .animation(Slate.Anim.reveal, value: showSecureInputPill)
        .animation(Slate.Anim.reveal, value: showViModePill)
        .animation(Slate.Anim.reveal, value: showViHintBar)
        .animation(Slate.Anim.reveal, value: showReplayHUD)
        .animation(Slate.Anim.reveal, value: navigatorChrome.isVisible)
    }

    /// Whether the command-replay banner (E16 WI-9) mounts over this pane: a live terminal pane, NOT the
    /// static-mirror snapshot path, and the store has a pending replay prompt for it (Ask-Once / Manually
    /// awaiting a confirm, or a shell-handoff pause). Reading the store's OBSERVABLE replay state here
    /// re-renders the leaf so the banner reveals / hides as the machine advances.
    private var showReplayHUD: Bool {
        guard !staticMirror, let id = live?.id, live?.terminalModel != nil else { return false }
        return store.recipeReplayPrompt(for: id) != nil
    }

    /// Whether the `🛡 SECURE INPUT` pill is shown (E17 ES-E17-4 / WI-7). Visible iff secure input is active for
    /// the pane (``TerminalViewModel/secureInputActive`` — the auto password-prompt path or the manual toggle),
    /// the indicator setting is on (``SettingsKey/secureInputIndicatorEnabled``), AND the pane is NOT read-only
    /// (under read-only no input path can fire, so the secure-input cue is moot — spec). `secureInputActive` is
    /// always `false` off macOS, so the cross-platform pill never lights on iOS. `false` for a not-yet-live pane.
    private var showSecureInputPill: Bool {
        guard let model = live?.terminalModel else { return false }
        // Read the OBSERVED `secureInputIndicator` default (not the bare `SettingsKey` accessor) so SwiftUI tracks
        // the dependency: toggling "Show Secure Input Indicator" in Settings re-renders this leaf and hides the
        // pill at once (E17 ES-E17-4 / WI-7) — the live-toggle contract — instead of waiting for a pane swap.
        return model.secureInputActive && secureInputIndicator && !model.readOnlyBadgeActive
    }

    /// Whether the `🔒 READ ONLY ×` pill is shown (E17 ES-E17-1 / WI-3). Reads the pane model's OBSERVABLE
    /// mirrors so it lights / clears reactively: visible iff the pane's input gate is armed
    /// (``TerminalViewModel/readOnlyBadgeActive``) AND it is NOT in vi / copy mode
    /// (``TerminalViewModel/copyModeBadgeActive``) — copy mode temporarily hides the pill per the spec (its
    /// keybindings drive selection, not the shell, so the lock is not needed while it is active). `false`
    /// for a non-terminal / not-yet-live pane.
    private var showReadOnlyPill: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.readOnlyBadgeActive && !model.copyModeBadgeActive
    }

    /// Whether the vi-mode pill (E17 ES-E17-2 / WI-5) is shown. Reads the pane model's OBSERVABLE
    /// ``TerminalViewModel/copyModeBadgeActive`` mirror (NOT the `@ObservationIgnored` `isCopyMode` the keyDown
    /// path reads) so the pill lights / clears reactively as copy-mode arms / exits. `false` for a non-terminal
    /// / not-yet-live pane.
    private var showViModePill: Bool {
        live?.terminalModel?.copyModeBadgeActive == true
    }

    /// Whether the vi key-hint bar (E17 ES-E17-2 / WI-5) is shown: in vi mode AND the per-session `⌘/` toggle is
    /// on. Both reads are OBSERVABLE mirrors, so the bar reveals / hides reactively; it is gated on
    /// `copyModeBadgeActive` too so it can never linger after vi mode exits (``TerminalViewModel/exitCopyMode()``
    /// resets ``TerminalViewModel/showViKeyHints``, but the extra gate makes the teardown unconditional).
    private var showViHintBar: Bool {
        guard let model = live?.terminalModel else { return false }
        return model.copyModeBadgeActive && model.showViKeyHints
    }

    /// Wire all per-pane view callbacks (find + Composer + secure input + hint mode + host path actions) on
    /// appear / live-session swap.
    private func wirePaneCallbacks() {
        wireFindCallbacks()
        wireComposerCallbacks()
        wireSecureInputCallbacks()
        wireHintCallbacks()
        wireNavigatorCallbacks()
        wirePathActionCallbacks()
        wireAgentFooter()
    }

    /// Clear all per-pane view callbacks on teardown so a surviving model can't drive a dead leaf's `@State`.
    private func clearPaneCallbacks() {
        clearFindCallbacks()
        clearComposerCallbacks()
        clearSecureInputCallbacks()
        clearHintCallbacks()
        clearNavigatorCallbacks()
        clearPathActionCallbacks()
        clearAgentFooter()
    }

    // MARK: - Claude bottom bar (E13 WI-4 / ES-E13-4)

    /// The agent display name surfaced on the footer's green-suggestion pill + used as its per-agent
    /// notification-persistence key. E13 is **Claude-only** (carryover constraint #1 — `AgentKind.codex` is
    /// never rendered), so the bar always names Claude Code.
    private static let agentDisplayName = "Claude Code"

    /// Build + wire the per-pane ``AgentInputFooterCoordinator`` for a terminal pane (rebuilt on every
    /// live-session swap). It is created EAGERLY for any terminal — not gated on the agent status — so when
    /// the host later detects a `claude` (``LivePaneSession/claudeStatus`` lifts off `.none`) the footer VIEW
    /// (gated by `showAgentFooter`) reveals over an already-wired coordinator with NO extra plumbing.
    ///
    /// Hooks (the parent-supplied seams the coordinator can't complete on its own):
    /// - `onOpenSettings`     → the Settings overlay (the Agents card lives there, E13 WI-2).
    /// - `onStartRemoteControl` → the existing remote-window picker (E13 reuses the L6 seam).
    /// - `onAddContext`       → toggles the file explorer (docs/30: the "+" pill "toggles the file explorer";
    ///   never a dead stub).
    /// - `onSelectFile`       → splice the chosen path into the pane's durable Composer (caret-aware insert).
    ///
    /// A no-op for a non-terminal / static-mirror leaf (the footer never mounts there).
    private func wireAgentFooter() {
        guard !staticMirror, live?.terminalModel != nil else {
            agentFooter = nil
            return
        }
        let footer = AgentInputFooterCoordinator(
            agentName: Self.agentDisplayName,
            inputBar: live?.inputBar,
            preferences: preferencesStore,
            cwd: cwd,
            isRemote: footerIsRemote,
        )
        let overlay = overlayCoordinator
        footer.onOpenSettings = { overlay?.openSettings() }
        footer.onStartRemoteControl = { overlay?.openRemotePicker() }
        // The "+" add-context pill has no menu yet (L4 stub) → toggle the file explorer, the one real
        // attach affordance, so it is a live action rather than a silent no-op (docs/30 mapping).
        footer.onAddContext = { [weak footer] in footer?.handle(.toggleFileExplorer) }
        // A file pick splices its absolute path into the durable Composer at the caret (the same `insert`
        // seam ⌘V / the context-menu paste use), revealing the Composer so the user sees it land.
        footer.onSelectFile = { [weak composer = live?.composer] path in composer?.insert(path) }
        agentFooter = footer
    }

    /// Drop the footer coordinator on teardown so a closed leaf's `@State` can't be driven (and the captured
    /// overlay / composer references are released with it).
    private func clearAgentFooter() {
        agentFooter = nil
    }

    /// Whether the footer's file explorer should treat the pane's cwd as living on a DIFFERENT machine (so it
    /// shows the honest "not available for remote panes" state rather than listing the client's own disk). The
    /// PTY runs on the host, so a connected non-loopback host is remote; an empty / loopback host (the local
    /// dev + same-machine GUI-verify case) lists the cwd directly. Mirrors ``FileExplorerLister``'s remote gate.
    private var footerIsRemote: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return !(trimmed.isEmpty || trimmed == "localhost" || trimmed == "127.0.0.1" || trimmed == "::1")
    }

    /// Wire the pane's host OPEN / REVEAL path callbacks (E10 WI-7 / ES-E10-2 / ES-E10-6) to the pane's live
    /// ``MetadataClient`` — the final connection that makes ⌘click "Open", ⌘⇧click "Reveal in Finder", the
    /// right-click Open / Reveal items, Jump-To open/reveal, and Hint-to-open/reveal on a detected PATH route
    /// to the HOST Mac's Finder/app (a path lives on the host, not the client). The client provider captures
    /// `live` WEAKLY (so the model-stored closure never retains the live session into a cycle) and reads the
    /// pane's CURRENT façade each fire (it is replaced on every reconnect — `activeMetadataClient` is `nil`
    /// while disconnected). A `.notFound`/`.error`/timeout result raises a transient error toast rather than
    /// being swallowed. No-op for a non-terminal / not-yet-live pane.
    private func wirePathActionCallbacks() {
        guard let model = live?.terminalModel else { return }
        let overlay = overlayCoordinator
        HostPathActions.wire(
            model: model,
            client: { [weak live] in live?.connection?.activeMetadataClient },
            onResult: { action, path, ok in
                guard !ok else { return }
                overlay?.pushToast(Toast(
                    id: "host-path-action",
                    flavor: .error,
                    title: action == .open ? "Couldn't open on host" : "Couldn't reveal on host",
                    body: path,
                ))
            },
        )
    }

    /// Nil the host path callbacks so the durable terminal model stops referencing this torn-down leaf.
    private func clearPathActionCallbacks() {
        guard let model = live?.terminalModel else { return }
        HostPathActions.clear(model: model)
    }

    /// Wire the pane's Command Navigator toggle (E10 WI-10 / G8): ⌃⌘O routes through the store
    /// (`requestBlockNavigatorInActivePane` → `activeTerminalModel.onRequestBlockNavigator`), so this closure
    /// fires only when THIS pane is active. It TOGGLES the per-leaf ``CommandNavigatorChrome`` (the seam doc:
    /// "show/hide"). `[weak chrome]`-free: the chrome is the leaf's own `@State` reference, not the model, so
    /// there is no model→leaf retain cycle (the closure captures the chrome, and `clearNavigatorCallbacks`
    /// nils the model's reference on teardown). No-op for a non-terminal / not-yet-live pane.
    private func wireNavigatorCallbacks() {
        guard let model = live?.terminalModel else { return }
        let chrome = navigatorChrome
        model.onRequestBlockNavigator = { chrome.isVisible.toggle() }
    }

    /// Nil the navigator callback so the durable terminal model stops referencing this torn-down leaf's
    /// `@State` chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearNavigatorCallbacks() {
        live?.terminalModel?.onRequestBlockNavigator = nil
    }

    /// Wire the pane's Hint Mode actuation (E10 WI-9 / ES-E10-6): the model resolves a label (macOS key-resolve
    /// or iOS tap-on-label) and fires ``TerminalViewModel/onHintConfirmed`` with the chosen target + intent; the
    /// view is the thin platform actuator (open path → host RPC, open URL → client, copy → client pasteboard,
    /// reveal → host RPC — the SAME `LinkActionPolicy` the ⌘click / Jump-To paths use). `[weak model]` so the
    /// model-stored closure never retains the model into a cycle (also nilled on teardown). No-op off-terminal.
    private func wireHintCallbacks() {
        guard let model = live?.terminalModel else { return }
        model.onHintConfirmed = { [weak model] target, intent in
            guard let model else { return }
            Self.performHintAction(target, intent: intent, model: model)
        }
    }

    /// Nil the hint callback so the durable terminal model stops referencing this torn-down leaf.
    private func clearHintCallbacks() {
        live?.terminalModel?.onHintConfirmed = nil
    }

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel == nil`);
    /// `terminalModel` is non-nil from session creation for a terminal pane, so this lands on first `.task`.
    private func wireFindCallbacks() {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        // E17 ES-E17-2 / WI-5: copy-mode `?` opens the SAME bar biased BACKWARD so its `n`/`N` step against the
        // forward sense (vim parity). Without this the `?` handler falls back to `onRequestFind` (forward) and
        // the backward bias never lands.
        model.onRequestFindBackward = { bar.open(backward: true) }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
        // E5 "search all tabs" (find.png's `rectangle.stack` button): escalate the in-pane find to cross-tab
        // Global Search (⇧⌘F), seeded with the live query. The coordinator is captured by value (a long-lived
        // scene object); `nil` outside the app scene (tests/previews) ⇒ the button just dismisses the bar.
        bar.onSearchAllTabs = { [overlayCoordinator] seed in
            overlayCoordinator?.openGlobalSearch(seed: seed)
        }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's `@State`.
    private func clearFindCallbacks() {
        findBar.attach(nil)
        findBar.onSearchAllTabs = nil
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindBackward = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    /// Wire the pane's ⌘⇧E / ⌘⇧M callbacks (the store fires these AFTER it has toggled / opened the durable
    /// ``ComposerModel`` via `requestComposerInActivePane()` / `requestPromptQueueInActivePane()`): the view's
    /// job is to switch the queue-input affordance and re-focus the field. Also wires the right-click
    /// "Paste and continue in Composer" seam (`onPasteToComposer`) — it reads the richest clipboard flavour,
    /// converts HTML/RTF→Markdown via the SAME ``ComposerPasteboard`` the in-field ⌘V uses, and splices it at
    /// the Composer's caret (so the context path converts AND inserts at the caret, just like ⌘V). No-op for a
    /// non-terminal pane. The chrome is leaf `@State` (per-pane); the Composer model is durable.
    private func wireComposerCallbacks() {
        guard let model = live?.terminalModel, let composer = live?.composer else { return }
        let chrome = composerChrome
        model.onRequestComposer = {
            chrome.queueMode = false
            chrome.focusToken &+= 1
        }
        model.onRequestPromptQueue = {
            chrome.queueMode = true
            chrome.focusToken &+= 1
        }
        model.onPasteToComposer = { [weak composer] in
            guard let markdown = ComposerPasteboard.richMarkdown() else { return }
            composer?.pasteRich(markdown)
        }
        // E13 / WI-5 (ES-E13-5): the right-click "Send to Chat" item focuses THIS pane (so the coordinator
        // captures the right pane's selection / last command) then opens the client Send-to-Chat dialog. `nil`
        // when no coordinator is in scope (tests / previews) ⇒ the menu row greys out honestly.
        if let overlay = overlayCoordinator, let paneID = live?.id {
            model.onRequestSendToChat = { [weak store] in
                store?.focusPaneTree(paneID)
                overlay.openSendToChat()
            }
        }
    }

    /// Nil the Composer callbacks so the durable terminal model stops referencing this torn-down leaf's
    /// `@State` chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearComposerCallbacks() {
        guard let model = live?.terminalModel else { return }
        model.onRequestComposer = nil
        model.onRequestPromptQueue = nil
        model.onPasteToComposer = nil
        model.onRequestSendToChat = nil
    }

    /// Wire the pane's SECURE-INPUT actuator (E17 ES-E17-4 / WI-7): sync the controller to the model's current
    /// secure-input inputs + the live Auto-Secure-Input setting, then drive it on each change so macOS
    /// process-global Secure Keyboard Entry engages on a host no-echo password prompt (auto) or the manual
    /// toggle, and disengages on the inverse edge. Also starts the controller observing the app-frontmost edge
    /// (idempotent) so an engaged lock is RELEASED whenever aislopdesk is backgrounded (the user ⌘-Tabs away
    /// while a remote prompt is still up) and re-acquired on return — never leaked process-wide to other apps'
    /// keyboards. No-op for a non-terminal / not-yet-live pane; inert off macOS (the controller is a stub there).
    private func wireSecureInputCallbacks() {
        guard let model = live?.terminalModel else { return }
        let controller = secureInput
        controller.setAutoSecureInput(SettingsKey.autoSecureInputEnabled)
        controller.setHostNoEcho(model.hostNoEcho)
        controller.setManualOn(model.manualSecureInput)
        controller.observeAppActivity()
        model.onHostEchoChanged = { controller.setHostNoEcho($0) }
        model.onManualSecureInputChanged = { controller.setManualOn($0) }
    }

    /// Reconcile this pane's Secure Input to a LIVE "Auto Secure Input" settings change (E17 ES-E17-4 / WI-7).
    /// Driven by `.onChange(of: autoSecureInput)`, it pushes the new value into BOTH the actuator and the pill
    /// mirror so an engaged process-global `EnableSecureEventInput` lock is RELEASED (and the pill hidden) the
    /// instant the user turns the setting OFF — never lingering until the next pane swap / echo edge. No-op for a
    /// not-yet-live pane; inert off macOS (the controller is a stub and the model mirror stays `false` there).
    private func reconcileSecureInputSetting() {
        guard let model = live?.terminalModel else { return }
        secureInput.setAutoSecureInput(autoSecureInput)
        model.reconcileSecureInputSetting()
    }

    /// Force-disengage secure input + nil the callbacks on teardown so the process-global `EnableSecureEventInput`
    /// reference is always released on a pane close (never leaked) and a surviving model can't drive a dead
    /// leaf's controller.
    private func clearSecureInputCallbacks() {
        secureInput.teardown()
        guard let model = live?.terminalModel else { return }
        model.onHostEchoChanged = nil
        model.onManualSecureInputChanged = nil
    }

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        await live?.connection?.connect()
    }

    // MARK: - Hint Mode actuation (E10 WI-9 / ES-E10-6)

    /// Actuate a resolved hint `target` for `intent`. A path/URL link routes through the SAME pure
    /// ``LinkActionPolicy`` the ⌘click / Jump-To paths use (so there is no parallel mapping to drift); an IP
    /// OPENS (`http://<ip>`) on Hint-to-Open and copies otherwise; a git-hash copies its text on every intent
    /// (no open target for a bare hash — a deliberate gap, see DECISIONS.md E10); a custom
    /// `hint-pattern` runs its `{0}` action template (a known-safe `open <url>` on the client, else verbatim on
    /// the HOST shell — the mapping note's "arbitrary shell strings run on the host"). `static` so the
    /// model-stored closure needs no leaf `self`.
    private static func performHintAction(_ target: HintTarget, intent: HintIntent, model: TerminalViewModel) {
        switch target.kind {
        case let .link(link):
            actuate(linkAction(for: intent, link: link), model: model)
        case .ipAddress:
            // Hint-to-OPEN on a bare IP browses to it, treating the dotted-quad as a host. `copy`/`reveal`
            // still copy the text — there is no Finder target for an IP. `http://` (not `https://`): a bare
            // IP almost always serves plain HTTP and a TLS cert won't match a raw address.
            switch intent {
            case .open: openURLString("http://" + target.raw)
            case .copy,
                 .reveal: copyToPasteboard(target.raw)
            }
        case .gitHash:
            // A bare commit hash has NO open target (no repo URL context to resolve it against), so every
            // intent copies the text — a useful fallback, never a dead action. Recorded as a deliberate gap
            // in docs/DECISIONS.md (E10) rather than faking an open.
            copyToPasteboard(target.raw)
        case let .custom(actionTemplate):
            switch intent {
            case .copy: copyToPasteboard(target.raw)
            case .open,
                 .reveal: runCustomHintAction(template: actionTemplate, raw: target.raw, model: model)
            }
        }
    }

    /// Map a hint `intent` on a detected `link` to a ``LinkAction`` through the SAME pure ``LinkActionPolicy``
    /// the Jump-To (copy) / ⌘⇧click (reveal) paths use — open = best handler, copy = copy path/URL, reveal =
    /// reveal-in-Finder (a no-op for a URL, which has no Finder target). The OPEN intent is an EXPLICIT open
    /// (⌘⇧J Hint-to-Open), so it routes through the config-INDEPENDENT ``LinkActionPolicy/explicitOpenAction``
    /// — NOT the configurable ⌘click gesture, which would silently copy / no-op under `link-cmd-click =
    /// copy/nothing` (the E10 review bug). The mouse ⌘click / ⌘⇧click in the renderer keeps the gesture path.
    private static func linkAction(for intent: HintIntent, link: DetectedLink) -> LinkAction {
        switch intent {
        case .open: LinkActionPolicy.explicitOpenAction(link: link)
        case .copy: LinkActionPolicy.action(for: .copyPath, link: link)
        case .reveal: LinkActionPolicy.action(for: .revealInFinder, link: link)
        }
    }

    /// The thin platform dispatch behind a resolved ``LinkAction`` (mirrors the renderer's `performLinkAction` /
    /// the Jump-To `actuate`): copy → client pasteboard; cd → verbatim-UTF-8 down the PTY; open/reveal → the
    /// host RPC seams on the model; URL → client open.
    private static func actuate(_ action: LinkAction, model: TerminalViewModel) {
        switch action {
        case .nothing:
            return
        case let .copyPathClient(text):
            copyToPasteboard(text)
        case let .changeDirectoryPTY(path):
            model.sendInput(Data(LinkActionPolicy.changeDirectoryCommandLine(path).utf8))
        case let .openURLClient(urlString):
            openURLString(urlString)
        case let .openHost(path):
            model.onRequestOpenHostPath?(path)
        case let .revealHost(path):
            model.onRequestRevealHostPath?(path)
        }
    }

    /// Run a custom `hint-pattern`'s action template with `{0}` replaced by the matched text. A known-safe
    /// `open <url>` opens the URL on the CLIENT; anything else runs on the HOST shell (the correct execution
    /// context per the hint-mode mapping note) by injecting it verbatim down the PTY. No template ⇒ copy the text.
    private static func runCustomHintAction(template: String?, raw: String, model: TerminalViewModel) {
        guard let template, !template.isEmpty else {
            copyToPasteboard(raw)
            return
        }
        let resolved = template.replacingOccurrences(of: "{0}", with: raw)
        if resolved.hasPrefix("open ") {
            let rest = String(resolved.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: rest), url.scheme != nil {
                openURLString(rest)
                return
            }
        }
        model.sendInput(Data((resolved + "\n").utf8))
    }

    /// Open a URL string on the CLIENT (a URL / IP is host-agnostic). A no-op for an unparseable string.
    private static func openURLString(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Copy text to the platform pasteboard (the Jump-To / context-menu idiom). A no-op for empty text.
    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
#endif
