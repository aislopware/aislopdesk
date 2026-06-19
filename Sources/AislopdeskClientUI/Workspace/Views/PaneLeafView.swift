#if canImport(SwiftUI)
import AislopdeskInspector
import Foundation
import SwiftUI

// MARK: - PaneLeafView (WF5 — the real content seams per kind)

/// The content of a single leaf pane: the kind switch that wires the PROVEN seams (docs/22 §7),
/// re-parented from "one global session" (the retired `ClientRootView`) to "one per `PaneID`".
///
/// Its SIGNATURE is the stable WF4 contract — only the BODY is WF5:
/// - `.terminal`   → ``TerminalScreenView``(model: handle.terminalModel) + a per-pane
///   ``InputBarView``(model: handle.inputBar, client: handle.connection.activeClient), composed
///   exactly as the old `ClientRootView` did for ONE session — PLUS a dynamically-revealed,
///   read-only ``InspectorPanel`` (W11) once a `claude` is detected running in it (the per-pane
///   `claudeStatus` lifts off `.none`); a plain terminal shows neither. SINGLE leaf, not a tree node.
/// - `.remoteGUI`  → ``RemoteWindowPanel``(model: handle.remoteWindow, showCloseButton: false) — the
///   pane chrome owns close; video decode activates on appear / deactivates on disappear (battery).
///
/// ### Connect-on-appear (docs/22 §6 RESTORED-vs-RECONNECTED, lazy connect)
/// `LivePaneSession.make` builds the `ConnectionViewModel` WITHOUT connecting. This view's `.task`
/// triggers `connect()` ONCE for the visible pane (idle → connecting). It does NOT disconnect on
/// `.onDisappear`: the session lives in the store registry and must survive tab switches; the OS-level
/// pause/resume is the store's scenePhase fan-out, not a view-lifecycle teardown.
///
/// ### The handle is `any PaneSessionHandle` (the store-level test seam, docs/22 §0)
/// The live wiring needs the concrete ``LivePaneSession`` (its `terminalModel` / `inputBar` /
/// `connection` / `inspector` / `remoteWindow`). We down-cast once; a faked handle (tests/previews)
/// has no live objects, so the leaf falls back to a kind-aware placeholder — correct for a
/// no-session render.
struct PaneLeafView: View {
    /// The live session backing this leaf, or `nil` if the registry has not materialized it yet.
    let handle: (any PaneSessionHandle)?
    /// The pure intent for this leaf (kind + title + endpoint).
    let spec: PaneSpec
    /// Whether this leaf is the focused pane of its tab (drives focus affordance + content dim).
    let isFocused: Bool
    /// The single-focus arbiter for the iOS multi-visible (iPad-regular) path (docs/22 §7). Passed by
    /// the regular ``PaneTreeView`` so each visible terminal host routes first-responder through it;
    /// `nil` on the compact single-host carousel (no race to coordinate).
    var focusCoordinator: PaneFocusCoordinator?
    /// The store, threaded so a `.remoteGUI` leaf routes video activation through
    /// ``WorkspaceStore/activateVideo(_:)`` (the cap-enforcing seam). Optional so faked-handle /
    /// preview paths still construct a leaf; when `nil` the remote-GUI leaf falls back to direct
    /// activation (no cap — only the no-store preview case).
    var store: WorkspaceStore?
    /// True when the OWNER already presents the `.failed`/`.unreachable` affordance (the canvas
    /// ``PaneDeadScrim``) — suppresses the in-leaf orange failure banner so the reason is stated
    /// once. The neutral "Session ended" banner is never suppressed (the scrim never covers it).
    var suppressFailureBanner: Bool = false

    /// The concrete live session, when this is a production handle (the only thing that owns the
    /// proven per-session objects). `nil` for a faked handle / not-yet-materialized leaf.
    private var live: LivePaneSession? { handle as? LivePaneSession }

    var body: some View {
        Group {
            if let live {
                content(for: live)
            } else {
                placeholder
            }
        }
        .opacity(isFocused ? 1 : 0.92)
    }

    // MARK: - Kind switch (the seams)

    @ViewBuilder
    private func content(for live: LivePaneSession) -> some View {
        switch live.kind {
        case .terminal:
            // W11: ONE terminal view. It auto-detects a `claude` running inside it (the per-pane
            // `claudeStatus`) and reveals the read-only inspector toggle dynamically — there is no
            // separate "Claude Code pane" any more.
            TerminalPaneView(
                live: live,
                spec: spec,
                isFocused: isFocused,
                focusCoordinator: focusCoordinator,
                suppressFailureBanner: suppressFailureBanner,
            )
        case .remoteGUI:
            RemoteGUIPaneView(live: live, store: store)
        case .systemDialog:
            // Same live video view as a remote-GUI pane. A secure (password/auth) prompt gets a small
            // lock chip — NOT a "view-only" restriction: HW-proven (2026-06-15) the host injects the
            // password into a SecurityAgent/coreauthd field via `CGEvent(.cghidEventTap)` and the keys
            // LAND even though `IsSecureEventInputEnabled() == true`, so typing from the client works.
            RemoteGUIPaneView(live: live, store: store)
                .overlay(alignment: .bottom) {
                    if live.isSecureDialog { SecureDialogHintBar() }
                }
        }
    }

    // MARK: - Placeholder (faked handle / pre-materialize)

    /// A clean kind-aware placeholder for a faked handle or a leaf the registry has not materialized
    /// yet — keeps the shell laid out and the identity/zoom/focus plumbing exercised.
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 10) {
                Image(systemName: Self.icon(for: spec.kind))
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(spec.title).font(.headline).lineLimit(1)
                Text(kindLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let endpoint = endpointDescription {
                    Text(endpoint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kindLabel: String {
        switch spec.kind {
        case .terminal: "terminal"
        case .remoteGUI: "remote"
        case .systemDialog: "dialog"
        }
    }

    private var endpointDescription: String? {
        if let v = spec.video { return v.title }
        return nil
    }

    // MARK: Shared kind glyph (reused by the chrome + sidebar)

    /// The canonical SF Symbol for a ``PaneKind`` — one source of truth for the glyph so the leaf,
    /// the chrome header, and the sidebar agree.
    static func icon(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .remoteGUI: "macwindow.on.rectangle"
        case .systemDialog: "lock.shield"
        }
    }
}

/// A small lock chip flagging a SECURE system-dialog pane (a SecurityAgent/coreauthd password/auth
/// prompt) as a credential field — NOT a "view-only" restriction. macOS raises Secure Event Input for
/// these, but HW-proven (2026-06-15, Tahoe 26.5.1): the host's `CGEvent(.cghidEventTap)` keystroke
/// injection LANDS in the field anyway (the SecurityAgent password fills with dots + authenticates),
/// so typing the password from the client works — Secure Event Input does NOT block this injection
/// path. The earlier "view-only — type on the host" wording was therefore wrong and is removed; this
/// chip just signals "you are typing into a secure credential prompt".
private struct SecureDialogHintBar: View {
    var body: some View {
        Label("Secure prompt", systemImage: "lock.fill")
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            .allowsHitTesting(false) // never swallow a click meant for the dialog's Cancel/OK
    }
}

// MARK: - Terminal composition (the .terminal content; the inspector is layered by TerminalPaneView)

/// The proven terminal composition for ONE pane: the renderer seam over the per-pane
/// ``TerminalViewModel`` + the per-pane ``InputBarView`` bound to the SAME connection's live client,
/// composed exactly as the retired `ClientRootView` did for a single session (docs/22 §7).
///
/// ### New-pane empty state (docs/22 WF6 DECISIONS — new-pane connection flow)
/// A freshly user-created pane has NO explicit endpoint (`spec.endpoint == nil` — `store.split` /
/// `addTab` build an unconfigured spec). While such a pane is still disconnected it shows the proven
/// ``ConnectionView`` (host/port + Connect) bound to its own ``ConnectionViewModel`` — the user dials
/// in. Once connected it swaps to the terminal composite. A pane that DOES carry an explicit endpoint
/// (a restored/configured pane, or the automation seam) skips the form and AUTO-connects on appear —
/// we never blindly auto-dial a default for a user-created pane.
///
/// Owns the (gated) connect-on-appear + the `AISLOPDESK_AUTOTYPE` OUT-path proof seam (both keyed off the
/// `LivePaneSession`'s own `connection`). Embedded by ``TerminalPaneView`` (which layers the dynamic
/// inspector on top once a `claude` is detected, W11).
private struct TerminalContentView: View {
    let live: LivePaneSession
    /// The pure intent (kind + title). The host/port live on the app-global connection — the pane just
    /// opens a channel on it.
    let spec: PaneSpec
    /// Whether this pane is the active tab's focused pane — threaded to the renderer so only the
    /// focused pane takes the macOS keyboard first responder (unfocused split siblings keep repainting
    /// but do not steal the keyboard).
    var isFocused: Bool = true
    /// The single-focus arbiter forwarded to the iOS ``InputBarView`` → ``TerminalInputHost`` so the
    /// host registers under this pane's id (docs/22 §7). `nil` ⇒ direct-claim (compact / macOS).
    var focusCoordinator: PaneFocusCoordinator?
    /// True when the canvas ``PaneDeadScrim`` already presents the failure (suppresses the orange
    /// banner branch only — the neutral "Session ended" notice always shows).
    var suppressFailureBanner: Bool = false

    var body: some View {
        // Always the terminal composite (the app-global connect-gate guarantees the mux is up before the
        // canvas is shown, so a pane never owns a host/port form — docs/31). The channel-level recovery
        // banner is an OVERLAY, never a content branch: replacing `terminalComposite` would unmount
        // `TerminalScreenView` on every drop/retry crossing, churning the libghostty surface (the
        // documented focus/teardown freeze class). The overlay keeps the renderer mounted with stable id.
        terminalComposite
            .overlay(alignment: .top) { recoveryBanner }
            // Open this pane's channel ONCE on appear. The shared mux is already up (the gate pinned it),
            // so this just acquires a channel. Not closed on disappear — the session survives in the store
            // registry. Re-entrancy-safe: `connect()` flips `.connecting` synchronously + shields the
            // handshake in an unstructured Task, so a re-run never double-dials or tears the channel down.
            .task { await connectIfNeeded() }
    }

    /// The proven terminal composite, shown once the pane is connecting/live or when it carries an
    /// explicit endpoint. PLATFORM-SPLIT — the renderer is shared, but the keyboard-input surface is NOT:
    ///
    /// - **macOS**: renderer ONLY — you type DIRECTLY into the terminal (`GhosttyLayerBackedView.keyDown`
    ///   → `surface.key` → host PTY, the natural desktop terminal UX). The GUI "shell command" bar was
    ///   removed here (commit d2d382f): on macOS that bar grabbed keyboard focus, which UNFOCUSED the
    ///   libghostty surface (`GhosttyLayerBackedView.resignFirstResponder` → `surface.setFocus(false)`),
    ///   idling its renderer loop so the screen FROZE. The full-bleed, auto-focused terminal keeps the
    ///   surface focused and repainting. DO NOT add the bar back on macOS.
    ///
    /// - **iOS**: renderer + a per-pane ``InputBarView`` pinned at the BOTTOM (the standard mobile
    ///   terminal layout — terminal fills, keyboard bar docked). This is REQUIRED, not optional: the iOS
    ///   `GhosttyLayerBackedView` is a PASSIVE `CAMetalLayer` display — it is not a first responder and
    ///   implements no `UIKeyInput`, so it has NO keyboard path of its own. The keyboard/IME/accessory/
    ///   floating-cursor stack lives entirely in ``InputBarView`` → ``TerminalInputHost`` (doc 17 §2.5);
    ///   d2d382f dropped this bar from the live tree (it only ever survived in the retired
    ///   `ClientRootView`), so iOS users lost ALL keyboard input. Re-mounting it here restores the path,
    ///   exactly as `ClientRootView` did for one session (docs/22 §7), now keyed per ``PaneID``.
    ///
    /// REPAINT-SAFE on iOS (unlike macOS): the iOS surface sets `surface.setFocus(true)` once in
    /// `attach()` and NEVER calls `setFocus(false)` — it has no `resignFirstResponder` tied to render
    /// focus. So when ``TerminalInputHost``'s IME proxy takes the keyboard first responder, the surface
    /// keeps its render focus + 60fps `CADisplayLink` tick and keeps repainting. The macOS freeze cannot
    /// recur here.
    private var terminalComposite: some View {
        Group {
            if let terminalModel = live.terminalModel {
                #if os(iOS)
                // Terminal fills; the keyboard input bar is docked at the bottom (mobile layout). The bar
                // binds the SAME connection's live client (nil while disconnected → it disables send) via
                // `live.connection?.activeClient` — the proven OUT path is bar → `AislopdeskClient.sendInput`
                // → the ordered drain. `paneID` + `focusCoordinator` route the iOS first-responder
                // arbiter so multiple visible iPad-regular panes don't fight over the keyboard (docs/22
                // §7). Guarded on `live.inputBar` (present for any terminal/Claude pane; mirrors the
                // `if let terminalModel` guard) so an idle/remote pane never shows a stray bar.
                VStack(spacing: 0) {
                    TerminalScreenView(model: terminalModel, isFocused: isFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let inputBar = live.inputBar {
                        Divider()
                        InputBarView(
                            model: inputBar,
                            client: live.connection?.activeClient,
                            paneID: live.id,
                            focusCoordinator: focusCoordinator,
                        )
                    }
                }
                #else
                // macOS: renderer ONLY — type directly into the terminal (no bar; see the doc comment).
                TerminalScreenView(model: terminalModel, isFocused: isFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            } else {
                Color.clear
            }
        }
    }

    /// A recovery affordance shown OVER the (still-mounted) terminal when an explicit-endpoint pane has
    /// no on-screen connect form to fall back to: a `.failed`/`.unreachable` pane otherwise renders a
    /// dead/blank terminal whose only failure cue is a 7pt dot + a tiny chrome caption, and whose only
    /// recovery is the off-screen ⇧⌘R / palette "Reconnect Pane". This puts the reason + a Retry button
    /// where the user is already looking. `.reconnecting` is deliberately EXCLUDED — it is auto-healing
    /// and already shows a live countdown in the chrome. Reuses the proven `connect()` recovery path.
    @ViewBuilder
    private var recoveryBanner: some View {
        if let connection = live.connection {
            if let reason = PaneRecoveryBanner.reason(for: connection.status) {
                // The canvas dead scrim states the same reason + reconnect for these states — never
                // both at once (the iOS-compact carousel has no scrim and keeps the banner).
                if !suppressFailureBanner {
                    PaneRecoveryBanner(reason: reason) {
                        Task { await connection.connect() }
                    }
                    .padding(8)
                }
            } else if let endedReason = PaneRecoveryBanner.sessionEndedReason(for: connection.status) {
                // A cleanly-exited shell on an explicit-endpoint pane: a NEUTRAL "Session ended" notice +
                // Reconnect, where the user is looking — instead of a frozen terminal dead-end (pass-3 #1).
                PaneRecoveryBanner(reason: endedReason, isNeutral: true) {
                    Task { await connection.connect() }
                }
                .padding(8)
            }
        }
    }

    /// Opens this pane's channel on the app-global connection (lazy, once on appear), then runs the
    /// `AISLOPDESK_AUTOTYPE` OUT-path proof if this is the automation target (pane0). Every terminal pane now
    /// rides the one app connection, so there is no per-pane "explicit endpoint" gate — the channel opens
    /// against the app target the gate dialled.
    private func connectIfNeeded() async {
        func clog(_ m: @autoclosure () -> String) {
            if ProcessInfo.processInfo.environment["AISLOPDESK_RENDER_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[CONN] \(m())\n".utf8))
            }
        }
        // The pane's `connection` (its `ConnectionViewModel`) is materialized by the store's
        // reconcile, which can RACE this `.task`: when the view wins, `live.connection` is still nil.
        // The old code (`guard ... let connection else { return }`) gave up immediately, so an
        // explicit-endpoint pane that lost the race was stranded at "idle" forever and never
        // auto-connected. Wait briefly for the session to materialize (no-op when already ready).
        var connection = live.connection
        var spins = 0
        while connection == nil, spins < 100 { // up to ~2s
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled { return }
            connection = live.connection
            spins += 1
        }
        guard let connection else { clog("connection nil after \(spins) spins → return")
            return
        }
        clog("ready after \(spins) spins, status=\(String(describing: connection.status))")
        // Only connect a freshly-materialized idle pane; never re-dial a live/connecting one (a tab
        // switch re-runs `.task`, and `.id(PaneID)` keeps this view stable across reshapes). The
        // cancellation shield that keeps a canvas-churned `.task` from tearing the just-acquired mux
        // channel back down lives INSIDE `ConnectionViewModel.connect()` (it also flips `status` to
        // `.connecting` synchronously there, so a re-entrant `.task` sees `.connecting` and never
        // double-dials).
        if connection.status == .disconnected {
            await connection.connect()
            clog("connect() returned, status=\(String(describing: connection.status))")
        } else {
            clog("status \(String(describing: connection.status)) ≠ .disconnected → not dialing")
        }
        await runAutotypeIfRequested(connection: connection)
    }

    /// The `AISLOPDESK_AUTOTYPE` OUT-path proof seam (docs/22 §7), migrated verbatim from the retired
    /// `AislopdeskClientApp.autoConnectIfRequested`. After tab0/pane0's terminal connects, if `AISLOPDESK_AUTOTYPE`
    /// is set, push the command bytes through the REAL OUT path — `terminalModel.sendInput` →
    /// `inputSink` → the ordered drain in `ConnectionViewModel` → `AislopdeskClient.sendInput` → host PTY:
    /// the EXACT keystroke→host chain `GhosttyTerminalView` drives, so a typed command actually
    /// executes on the host and renders back. `scripts/check-macos.sh --connect` asserts this round
    /// trip (a host-side marker file with a COMPUTED value), not just a live TCP socket. Unset in
    /// normal use, so a production launch is unaffected.
    @MainActor
    private func runAutotypeIfRequested(connection: ConnectionViewModel) async {
        guard live.isAutotypeTarget else { return }
        let env = ProcessInfo.processInfo.environment
        guard case .connected = connection.status,
              let cmd = env["AISLOPDESK_AUTOTYPE"], !cmd.isEmpty,
              let terminalModel = live.terminalModel else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000) // let the remote prompt come up
        terminalModel.sendInput(Data((cmd + "\n").utf8))
    }
}

/// A `.terminal` leaf: the proven terminal composition, full-bleed — PLUS the dynamically-revealed,
/// read-only ``InspectorPanel`` (W11). Claude Code is no longer a stored `PaneKind`: ANY terminal that
/// the host detects is running `claude` (the per-pane ``LivePaneSession/claudeStatus`` lifts off `.none`)
/// gains the inspector toggle + its second channel; a plain terminal shows neither. The toggle + the
/// local split ratio are per-pane VIEW state (NOT a tree node — one leaf, docs/22 §2.3). Platform branch:
/// - **macOS**: terminal + inspector side-by-side, divider toggled by a header button.
/// - **iOS**: terminal full-bleed, inspector as a bottom sheet.
private struct TerminalPaneView: View {
    let live: LivePaneSession
    let spec: PaneSpec
    var isFocused: Bool = true
    var focusCoordinator: PaneFocusCoordinator?
    var suppressFailureBanner: Bool = false
    /// Per-pane VIEW state: whether the inspector is shown. Local to this leaf — lost on a true session
    /// swap (a new `PaneID`), preserved across reshape/zoom/focus (stable `.id`).
    @State private var showInspector = false

    /// Whether a `claude` is currently detected in this terminal (the inspector affordance gate, W11).
    private var claudeDetected: Bool { live.claudeStatus != .none }

    var body: some View {
        VStack(spacing: 0) {
            // The inspector toggle strip only appears once a claude is detected — a plain terminal is
            // full-bleed (no chrome). subscribeInspector() is gated on the same runtime status, so a
            // plain terminal opens NO inspector socket.
            if claudeDetected {
                inspectorToggleBar
                Divider()
            }
            content
        }
        // Re-drive the dynamic subscribe whenever the detection status crosses (idempotent; the session
        // also opens/closes the channel itself in feedAgentSignal — this is the view-appear safety net).
        .task(id: claudeDetected) { await live.subscribeInspector() }
    }

    /// macOS: terminal + (optional) inspector side-by-side. iOS: terminal full-bleed; inspector sheet.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            TerminalContentView(
                live: live,
                spec: spec,
                isFocused: isFocused,
                focusCoordinator: focusCoordinator,
                suppressFailureBanner: suppressFailureBanner,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, claudeDetected, let model = live.inspector {
                Divider()
                InspectorPanel(model: model)
                    .frame(minWidth: 280, maxWidth: 420)
            }
        }
        #else
        TerminalContentView(
            live: live,
            spec: spec,
            isFocused: isFocused,
            focusCoordinator: focusCoordinator,
            suppressFailureBanner: suppressFailureBanner,
        )
        .sheet(isPresented: $showInspector) {
            if let model = live.inspector {
                InspectorPanel(model: model)
                    .presentationDetents([.medium, .large])
            }
        }
        #endif
    }

    /// The inspector-visible toggle (per-pane). A thin strip above the content so the affordance is
    /// reachable on both platforms without depending on the global toolbar.
    private var inspectorToggleBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                showInspector.toggle()
            } label: {
                Label(
                    "Inspector",
                    systemImage: showInspector ? "sidebar.right" : "sidebar.squares.right",
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide inspector" : "Show inspector")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
            .disabled(live.inspector == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Remote GUI composition (video)

/// The three things a `.remoteGUI` leaf can show, decided PURELY from
/// `(admitted, configured, hasFreeSlot)` so the branch is unit-testable without a SwiftUI render
/// (BUG-A + the F1 regression fix).
enum RemoteGUIDisplay: Equatable {
    /// The live ``RemoteWindowPanel`` (admitted to a cap slot — its decode stack may run).
    case live
    /// The ``RemoteWindowPanel`` entry FORM: either the model is not yet configured (no host/port — the
    /// user must dial it in), OR it just became configured while a cap slot IS free (so admission is
    /// about to be auto-attempted and flip the pane to `.live` — the form must NOT vanish before then).
    /// Holds NO decode stack (`model.active == nil`).
    case entryForm
    /// The cap-saturated placeholder: the model IS configured AND no slot is free, so admission was
    /// refused specifically because ``WorkspaceStore/liveVideoCap`` is saturated (BUG-A — distinct from
    /// the unconfigured / free-slot `.entryForm`).
    case gated

    /// The PURE display decision (BUG-A + F1) — free of any SwiftUI / store state so it is unit-tested
    /// directly:
    /// - `admitted` ⇒ `.live`;
    /// - else NOT configured ⇒ `.entryForm` (let the user dial in — never gate an unconfigured pane);
    /// - else configured AND a slot IS free ⇒ `.entryForm` (the form stays until the reactive retry
    ///   admits the now-configured pane and flips `admitted` true — F1: the form must not disappear
    ///   the instant the endpoint becomes valid);
    /// - else (configured AND no free slot) ⇒ `.gated` (admission was genuinely refused by the cap).
    static func resolve(admitted: Bool, configured: Bool, hasFreeSlot: Bool) -> Self {
        if admitted { return .live }
        guard configured else { return .entryForm }
        return hasFreeSlot ? .entryForm : .gated
    }
}

/// A `.remoteGUI` leaf: the live ``RemoteWindowPanel`` with the pane-chrome owning close
/// (`showCloseButton: false`). Video decode activates on appear / deactivates on disappear so a
/// hidden / torn-down pane holds no decode stack (docs/22 §7 the video resource ceiling).
///
/// Activation is routed through ``WorkspaceStore/activateVideo(_:)`` so the `liveVideoCap` is actually
/// enforced at runtime (the store self-excludes this pane + counts other active video panes). Without a
/// store (preview / faked path) it falls back to direct, un-capped activation.
///
/// ### Two reasons admission can be `false` (BUG-A) + the F1 regression fix
/// `activateVideo` (and direct activation) can decline for two very different reasons, which this view
/// MUST distinguish — otherwise an unconfigured pane is stuck forever on a wrong "too many windows"
/// placeholder with no way to enter host/port:
/// - the model is **not yet configured** (`remoteWindow.canOpen == false` — a fresh New-Tab/split
///   Remote Window has `video: nil` → `RemoteWindowModel()` with empty fields) ⇒ show the
///   ``RemoteWindowPanel`` ENTRY FORM so the user can dial in the endpoint (it holds no decode stack
///   until they open it);
/// - the model **is configured** (`canOpen == true`) but the cap is saturated ⇒ show the gated
///   placeholder (and re-attempt when a slot frees, ITEM #2).
///
/// The store's `false` alone cannot tell those apart (`activateVideo` returns `false` for both). So the
/// display is decided by ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)`` fed BOTH
/// `configured` (the model's `canOpen`) and `hasFreeSlot` (the store's pure
/// ``WorkspaceStore/hasFreeVideoSlot(for:)`` read mirroring the admission guard): a configured pane with
/// a slot still FREE keeps showing the entry form (F1 — the form must not vanish the instant the
/// endpoint becomes valid), and only a configured pane refused because the cap is genuinely saturated
/// shows `.gated`.
///
/// ### Reactive admission (ITEM #2 + F1)
/// The store cannot flip a pane's liveness itself — admission is view-driven. Two reactive re-attempts:
/// - **F1 — became configured**: a fresh pane's `.onAppear` ran while `canOpen` was still false, so it
///   never admitted. When the user finishes typing a valid endpoint `configured` flips true; this view
///   observes it via `.onChange(of: configured)` and re-runs `activate()` (→ `activateVideo`, still
///   cap-checked) so a configured pane with a free slot goes live without a manual nudge.
/// - **ITEM #2 — a slot freed**: when a slot frees the store bumps
///   ``WorkspaceStore/videoPromotionGeneration``; this view observes it via `.onChange` and re-attempts
///   admission through `activateVideo`, so a previously-gated on-screen pane promotes itself the moment
///   a slot opens.
private struct RemoteGUIPaneView: View {
    let live: LivePaneSession
    /// The cap-enforcing store. `nil` only on the no-store preview path.
    var store: WorkspaceStore?
    /// Whether this pane was admitted to hold live video (the store said yes, or the no-store fallback
    /// activated it). When `false` the pane shows the entry form (unconfigured) or the gated placeholder
    /// (configured but over-cap) per ``RemoteGUIDisplay``.
    @State private var admitted = false

    /// Debounced video teardown (the autoconnect-connect fix). SwiftUI fires a SPURIOUS
    /// `.onDisappear` on this pane during the initial NavigationSplitView layout settle — even
    /// though the pane stays on screen. The battery "deactivate on disappear" optimization then
    /// ran `model.close()` (active=nil) → the `VideoWindowView` was dismantled → its UDP session
    /// `stop()`'d WHILE `session.start()` was mid-`await transport.start`, so `stateMachine.start()`
    /// saw `.stopped` and produced ZERO effects → the `hello` was never sent → autoconnect never
    /// connected. (The manual dial-in flow opens the video AFTER the shell has settled, so it never
    /// saw the spurious disappear — which is why it always worked.) We DEFER the teardown by a short
    /// delay and CANCEL it if the pane re-appears (or activates) in the meantime; only a disappear
    /// that actually persists (a real tab switch) tears the decode stack down.
    @State private var teardownTask: Task<Void, Never>?

    /// Whether the remote-window model parses to a complete endpoint (host/port/window all valid). A
    /// fresh user-created `.remoteGUI` pane is NOT configured (empty fields → `canOpen == false`). This
    /// reads the `@Observable` ``RemoteWindowModel`` fields, so it re-evaluates on the keystroke that
    /// completes a valid endpoint — which drives the F1 reactive retry below.
    private var configured: Bool { live.remoteWindow?.canOpen == true }

    /// Whether the store currently has a free live-video slot for THIS pane (mirrors `activateVideo`'s
    /// guard with no mutation). The no-store preview path has no cap, so it is always free there. Fed
    /// into ``RemoteGUIDisplay/resolve(admitted:configured:hasFreeSlot:)`` so a configured-but-unadmitted
    /// pane shows the entry form while a slot is free (F1 — the form must stay until the retry admits it)
    /// and only the gated placeholder once the cap is genuinely saturated.
    private var hasFreeSlot: Bool { store?.hasFreeVideoSlot(for: live.id) ?? true }

    /// Canvas behaviour for this remote-GUI pane, threaded to the gated video view: only the ACTIVE
    /// (focused) pane consumes pointer/scroll; a click ACTIVATES it (and the video view raises the host
    /// window via its own `focusWindow`); a scroll over a NON-active pane pans the canvas instead of being
    /// swallowed. `nil` store (no-store preview) → `.standalone` (always active, no-op callbacks).
    private var paneContext: RemotePaneContext {
        guard let store else { return .standalone }
        let id = live.id
        return RemotePaneContext(
            isActive: store.isFocused(id),
            onActivate: { [weak store] in store?.focus(id) },
            onCanvasScroll: { [weak store] delta in
                // Debounced live accumulator (not a per-step commitCamera) — a scroll over a GUI pane pans
                // the canvas smoothly without the re-render cascade that froze the stream (BUG-2/BUG-1).
                store?.scrollPan(by: delta)
            },
            onStreamNativeSize: { [weak store] target, current in
                // 1:1 SNAP: the stream's native point size became known (first decoded frame) or
                // changed (host-side resize). Grow/shrink the pane by the VIDEO-CONTENT delta so
                // the stream renders pixel-for-pixel — the chrome inset rides along untouched.
                store?.snapPaneToContentSize(id, target: target, current: current)
            },
            onKeyInjectorReady: { [weak model = live.remoteWindow] injector in
                // PASTE AS KEYSTROKES: the live video view hands us its key-injection closure when its
                // session comes up (and nil on teardown). Park it on the pane's model so the pill's
                // "Paste as Keystrokes" can drive the secure-input-aware key path.
                model?.keyInjector = injector
            },
        )
    }

    var body: some View {
        Group {
            if let model = live.remoteWindow {
                // `.entryForm` and `.live` render the IDENTICAL `RemoteWindowPanel`; only `.gated`
                // differs. They MUST share ONE stable SwiftUI identity — rendering the panel from two
                // separate `switch` branches makes SwiftUI RECREATE the `VideoWindowView` when
                // `admitted` flips `entryForm→live`, tearing down its just-built UDP session before the
                // queued `hello` flushes (the synchronous cursor-prime survives, the hello does not), so
                // the AUTOCONNECT path never connects. The panel itself shows the form vs. live video off
                // `model.active`; admission only gates whether `open()` was allowed to run. (The manual
                // dial-in flow stays in `.live` throughout, which is why it was never affected.)
                if RemoteGUIDisplay
                    .resolve(admitted: admitted, configured: configured, hasFreeSlot: hasFreeSlot) == .gated
                {
                    gatedPlaceholder
                } else {
                    // Thread the canvas pane behaviour through: only the ACTIVE pane swallows
                    // pointer/scroll; a NON-active GUI pane routes scroll to canvas-pan and ignores
                    // hover. Without this argument the panel falls back to `.standalone`
                    // (`isActive: true` always), so every GUI pane keeps swallowing the pointer.
                    RemoteWindowPanel(model: model, showCloseButton: false, paneContext: paneContext)
                }
            } else {
                Color.clear
            }
        }
        // Activate on appear (decode only the on-screen pane), deactivate on disappear (battery).
        // Routed through the store so `liveVideoCap` is enforced; the no-store preview path activates
        // directly. The store reads `isVideoActive` to count concurrent live video panes.
        .onAppear { cancelPendingTeardown()
            activate()
        }
        // Backstop for .onAppear: a configured (restored / autoconnect) pane is ALREADY configured at
        // mount, so `.onChange(of: configured)` never fires, and `.onAppear` alone is unreliable — it is
        // deferred until the NavigationSplitView detail subtree is actually displayed, so an autoconnect
        // launch (and any launch where the window isn't front yet) sits on the form instead of going
        // live. `.task` runs reliably on view-install; `activate()` is cap-checked + the `!admitted`
        // guard makes the double-trigger idempotent (an unconfigured pane still no-ops → entry form, so
        // the manual dial-in flow is unchanged). This is the one-shot autoconnect fix.
        .task { cancelPendingTeardown()
            if !admitted { activate() }
        }
        .onDisappear { scheduleTeardown() }
        // F1 — a fresh pane's .onAppear ran while the model was still UNconfigured (`canOpen == false`),
        // so `activate()` never admitted it and there was no re-attempt once the user finished typing a
        // valid endpoint. Re-attempt admission the instant the model becomes configured: the keystroke
        // that flips `canOpen` true flips `configured`, and this re-runs `activate()` (→ `activateVideo`,
        // still cap-checked). If a slot is free the pane goes live; if not it falls to the gated
        // placeholder — correct, because now admission was genuinely refused by the cap.
        .onChange(of: configured) { _, nowConfigured in
            if nowConfigured { activate() }
        }
        // ITEM #2 — when the store nudges `videoPromotionGeneration` (a slot freed), an on-screen pane
        // that was previously gated re-attempts admission. Cap-safe: the retry flows through
        // `activateVideo`. `nil` (no-store preview) never bumps, so this is inert there.
        .onChange(of: store?.videoPromotionGeneration) { _, _ in retryIfGated() }
        // CANVAS — release/re-admit the cap slot by VIEWPORT MEMBERSHIP, not just by mount lifetime.
        // A canvas keeps a video pane MOUNTED while it is within the cull margin (so `.onDisappear`
        // does not fire), but the pane can be off the actual viewport (panned aside, or hidden behind a
        // maximized sibling). `isPaneVisible` flips false then → free the slot (debounced teardown, so a
        // brief scroll-past does not churn the decode stack); flips true → re-admit. Inert on the
        // no-store preview path (`isPaneVisible` is nil there → neither branch).
        .onChange(of: store?.isPaneVisible(live.id)) { _, visible in
            if visible == false {
                scheduleTeardown()
            } else if visible == true {
                cancelPendingTeardown()
                if !admitted { activate() }
            }
        }
    }

    /// Requests a cap slot for this pane (store path) or activates directly (no-store preview path).
    private func activate() {
        if let store {
            admitted = store.activateVideo(live.id)
        } else {
            live.setVideoActive(true)
            admitted = live.isVideoActive
        }
    }

    /// Cancels a pending debounced teardown — the pane re-appeared (or re-activated), so the
    /// `.onDisappear` that scheduled it was spurious and the decode stack must stay up.
    private func cancelPendingTeardown() {
        teardownTask?.cancel()
        teardownTask = nil
    }

    /// Schedules the video teardown after a short grace period instead of running it inline on
    /// `.onDisappear`. A spurious initial-layout disappear is followed immediately by a re-appear
    /// (or the `.task`) which cancels this; only a disappear that OUTLASTS the grace period (a real
    /// tab switch / pane close) actually deactivates. This is the autoconnect-connect fix — the
    /// inline teardown used to stop the session mid-`start()` so the hello was never sent.
    private func scheduleTeardown() {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            // The disappear was SPURIOUS if the pane is still VISIBLE — on the active tab AND inside the
            // reported viewport (SwiftUI sent a lone `.onDisappear` during the initial layout settle but
            // the pane never left the screen, and `.onAppear` does NOT re-fire to cancel us). A REAL
            // disappear — a tab switch / close OR a canvas CULL (the pane was panned off-viewport) —
            // tears down (freeing the `liveVideoCap` slot). `isPaneVisible` falls back to
            // `isPaneOnActiveTab` on the compact / pre-report paths, so those stay byte-identical.
            if let store, store.isPaneVisible(live.id) {
                teardownTask = nil
                return
            }
            if let store {
                store.deactivateVideo(live.id)
            } else {
                live.setVideoActive(false)
            }
            admitted = false
            teardownTask = nil
        }
    }

    /// Re-attempts admission for a gated pane when the store signals a freed slot (ITEM #2). A no-op for
    /// an already-admitted pane (so an unrelated bump never re-churns a live pane) and for the no-store
    /// preview path. The retry still flows through `activateVideo`, so the cap is never breached.
    private func retryIfGated() {
        guard !admitted, let store else { return }
        admitted = store.activateVideo(live.id)
    }

    /// Shown when the cap is saturated AND the model is configured (BUG-A): the pane is on-screen but
    /// NOT decoding (no UDP / VTDecompress / CADisplayLink) because no slot is free. An UNconfigured
    /// pane never reaches here — it shows the entry form instead.
    private var gatedPlaceholder: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 10) {
                Image(systemName: "pause.rectangle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Video paused")
                    .font(.headline)
                Text("waiting for a free video slot")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A compact failure-recovery banner overlaid on a `.failed`/`.unreachable` terminal pane: the reason
/// plus a Retry button. Kept to the top edge + hit-testing only itself, so it never steals the
/// terminal's keyboard focus (the macOS unfocused-surface freeze hazard).
struct PaneRecoveryBanner: View {
    let reason: String
    /// `true` = a NEUTRAL "session ended" notice (a clean shell exit), styled without the orange error
    /// affordance; `false` (default) = the orange `.failed`/`.unreachable` recovery banner.
    var isNeutral: Bool = false
    let retry: () -> Void

    /// The user-facing reason for a recoverable (`.failed`/`.unreachable`) status, or `nil` when the
    /// status is not a recovery state (so the overlay is absent for connecting/connected/reconnecting —
    /// `.reconnecting` is auto-healing and already shows a live countdown in the chrome). Static + on
    /// this internal type so the projection is unit-testable without rendering the view.
    static func reason(for status: ConnectionViewModel.Status) -> String? {
        switch status {
        case let .failed(message): message
        case .unreachable: "Host unreachable — the connection could not be re-established."
        case .disconnected,
             .connecting,
             .connected,
             .reconnecting: nil
        }
    }

    /// A NEUTRAL "the shell exited" notice for a cleanly `.disconnected` explicit-endpoint pane (the
    /// remote shell ran `exit` / the process died). DISTINCT from the orange error `reason(for:)` — a
    /// clean exit is not a failure and must not read as an alarm. Returns nil for every other status. Was
    /// a silent dead-end (frozen terminal, grey dot, no message, no Retry) before pass-3 #1.
    static func sessionEndedReason(for status: ConnectionViewModel.Status) -> String? {
        if case .disconnected = status { return "Session ended — the shell on the host exited." }
        return nil
    }

    var body: some View {
        let accent: Color = isNeutral ? .secondary : .orange
        HStack(spacing: 8) {
            Image(systemName: isNeutral ? "power" : "exclamationmark.triangle.fill")
                .foregroundStyle(accent)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(isNeutral ? "Reconnect" : "Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.5)))
        .frame(maxWidth: 460)
        .accessibilityElement(children: .combine)
    }
}
#endif
