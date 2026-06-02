#if canImport(SwiftUI)
import SwiftUI
import RworkInspector

// MARK: - PaneLeafView (WF5 — the real content seams per kind)

/// The content of a single leaf pane: the kind switch that wires the PROVEN seams (docs/22 §7),
/// re-parented from "one global session" (the retired `ClientRootView`) to "one per `PaneID`".
///
/// Its SIGNATURE is the stable WF4 contract — only the BODY is WF5:
/// - `.terminal`   → ``TerminalScreenView``(model: handle.terminalModel) + a per-pane
///   ``InputBarView``(model: handle.inputBar, client: handle.connection.activeClient), composed
///   exactly as the old `ClientRootView` did for ONE session.
/// - `.claudeCode` → the same terminal + a TOGGLEABLE ``InspectorPanel`` (per-pane VIEW state — an
///   inspector-visible toggle + a local split ratio; macOS side-by-side, iOS a bottom sheet —
///   mirroring the old `ClientRootView` platform branch). It is a SINGLE leaf, not a tree node.
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
    var focusCoordinator: PaneFocusCoordinator? = nil

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
            TerminalPaneView(live: live, spec: spec, focusCoordinator: focusCoordinator)
        case .claudeCode:
            ClaudeCodePaneView(live: live, spec: spec, focusCoordinator: focusCoordinator)
        case .remoteGUI:
            RemoteGUIPaneView(live: live)
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
        case .terminal:   return "terminal"
        case .claudeCode: return "claude"
        case .remoteGUI:  return "remote"
        }
    }

    private var endpointDescription: String? {
        if let e = spec.endpoint { return "\(e.host):\(e.port)" }
        if let v = spec.video { return "\(v.host) · \(v.title)" }
        return nil
    }

    // MARK: Shared kind glyph (reused by the chrome + sidebar)

    /// The canonical SF Symbol for a ``PaneKind`` — one source of truth for the glyph so the leaf,
    /// the chrome header, and the sidebar agree.
    static func icon(for kind: PaneKind) -> String {
        switch kind {
        case .terminal:   return "terminal"
        case .claudeCode: return "sparkles"
        case .remoteGUI:  return "macwindow.on.rectangle"
        }
    }
}

// MARK: - Terminal composition (shared by .terminal and .claudeCode)

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
/// Owns the (gated) connect-on-appear + the `RWORK_AUTOTYPE` OUT-path proof seam (both keyed off the
/// `LivePaneSession`'s own `connection`). Used directly for `.terminal` and embedded by
/// ``ClaudeCodePaneView`` for `.claudeCode`.
private struct TerminalContentView: View {
    let live: LivePaneSession
    /// The pure intent — read for `spec.endpoint` to decide auto-connect vs. the connect form.
    let spec: PaneSpec
    /// The single-focus arbiter forwarded to the iOS ``InputBarView`` → ``TerminalInputHost`` so the
    /// host registers under this pane's id (docs/22 §7). `nil` ⇒ direct-claim (compact / macOS).
    var focusCoordinator: PaneFocusCoordinator? = nil

    /// Whether this pane carries an explicit endpoint (restored / configured / automation). Only such
    /// a pane auto-connects on appear; a fresh user pane shows the connect form first.
    private var hasExplicitEndpoint: Bool { spec.endpoint != nil }

    var body: some View {
        Group {
            if showConnectForm {
                connectForm
            } else {
                terminalComposite
            }
        }
        // Lazy connect ONCE on appear (docs/22 §6) — but ONLY for a pane with an explicit endpoint.
        // A fresh user pane (no endpoint) waits for the user's Connect in the form. Not connected on
        // disappear — the session survives tab switches in the store registry. Re-entrancy-safe:
        // `connect()` tears down a prior session first, but we only call it from a fresh idle pane.
        .task { await connectIfNeeded() }
    }

    /// Show the connect form when this pane has no explicit endpoint AND is not yet live — i.e. a
    /// fresh user-created pane awaiting host/port. Once it connects (or while connecting/reconnecting)
    /// the terminal composite is shown instead. A pane with an explicit endpoint never shows the form
    /// (it auto-connects).
    private var showConnectForm: Bool {
        guard !hasExplicitEndpoint, let connection = live.connection else { return false }
        switch connection.status {
        case .disconnected, .failed: return true
        case .connecting, .connected, .reconnecting: return false
        }
    }

    /// The new-pane empty state: the proven ``ConnectionView`` (host/port + Connect) over this pane's
    /// own ``ConnectionViewModel``. Centered so it reads as an empty state, not a toolbar.
    @ViewBuilder
    private var connectForm: some View {
        if let connection = live.connection {
            VStack(spacing: 12) {
                Image(systemName: PaneLeafView.icon(for: spec.kind))
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Connect to a host")
                    .font(.headline)
                ConnectionView(model: connection)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            Color.clear
        }
    }

    /// The proven terminal composite (renderer + input bar), shown once the pane is connecting/live or
    /// when it carries an explicit endpoint.
    private var terminalComposite: some View {
        VStack(spacing: 0) {
            if let terminalModel = live.terminalModel {
                TerminalScreenView(model: terminalModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
            if let inputBar = live.inputBar {
                Divider()
                // The input bar binds the SAME connection's live client (nil while disconnected, so
                // the bar disables send). The proven OUT path: bar → client.sendInput → ordered drain.
                // The pane id + coordinator drive the iOS first-responder arbiter (docs/22 §7).
                InputBarView(
                    model: inputBar,
                    client: live.connection?.activeClient,
                    paneID: live.id,
                    focusCoordinator: focusCoordinator
                )
            }
        }
    }

    /// Triggers the connection's lazy `connect()` for a fresh idle pane that carries an EXPLICIT
    /// endpoint, then runs the `RWORK_AUTOTYPE` OUT-path proof if this is the automation target
    /// (tab0/pane0). A pane with no explicit endpoint is NOT auto-dialed — the user drives Connect via
    /// the form (docs/22 WF6 DECISIONS).
    private func connectIfNeeded() async {
        guard hasExplicitEndpoint, let connection = live.connection else { return }
        // Only connect a freshly-materialized idle pane; never re-dial a live/connecting one (a tab
        // switch re-runs `.task`, and `.id(PaneID)` keeps this view stable across reshapes).
        if connection.status == .disconnected {
            await connection.connect()
        }
        await runAutotypeIfRequested(connection: connection)
    }

    /// The `RWORK_AUTOTYPE` OUT-path proof seam (docs/22 §7), migrated verbatim from the retired
    /// `RworkClientApp.autoConnectIfRequested`. After tab0/pane0's terminal connects, if `RWORK_AUTOTYPE`
    /// is set, push the command bytes through the REAL OUT path — `terminalModel.sendInput` →
    /// `inputSink` → the ordered drain in `ConnectionViewModel` → `RworkClient.sendInput` → host PTY:
    /// the EXACT keystroke→host chain `GhosttyTerminalView` drives, so a typed command actually
    /// executes on the host and renders back. `scripts/check-macos.sh --connect` asserts this round
    /// trip (a host-side marker file with a COMPUTED value), not just a live TCP socket. Unset in
    /// normal use, so a production launch is unaffected.
    @MainActor
    private func runAutotypeIfRequested(connection: ConnectionViewModel) async {
        guard live.isAutotypeTarget else { return }
        let env = ProcessInfo.processInfo.environment
        guard case .connected = connection.status,
              let cmd = env["RWORK_AUTOTYPE"], !cmd.isEmpty,
              let terminalModel = live.terminalModel else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the remote prompt come up
        terminalModel.sendInput(Data((cmd + "\n").utf8))
    }
}

/// A `.terminal` leaf: the terminal composition, full-bleed.
private struct TerminalPaneView: View {
    let live: LivePaneSession
    let spec: PaneSpec
    var focusCoordinator: PaneFocusCoordinator? = nil
    var body: some View { TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator) }
}

// MARK: - Claude Code composition (terminal + toggleable inspector)

/// A `.claudeCode` leaf: the proven terminal composition PLUS a TOGGLEABLE read-only ``InspectorPanel``
/// fed by the pane's own inspector second channel (NWConnection #2). The inspector-visible toggle + the
/// local split ratio are per-pane VIEW state — NOT a tree node (a Claude Code pane is a single leaf,
/// docs/22 §2.3). Platform branch mirrors the retired `ClientRootView`:
/// - **macOS**: terminal + inspector side-by-side, divider toggled by a header button.
/// - **iOS**: terminal full-bleed, inspector as a bottom sheet.
private struct ClaudeCodePaneView: View {
    let live: LivePaneSession
    /// The pure intent — forwarded to ``TerminalContentView`` so a fresh Claude Code pane shows the
    /// connect form until it is dialed in (docs/22 WF6 new-pane connection flow).
    let spec: PaneSpec
    /// The single-focus arbiter forwarded to the embedded terminal composition (docs/22 §7).
    var focusCoordinator: PaneFocusCoordinator? = nil
    /// Per-pane VIEW state: whether the inspector is shown. Local to this leaf — lost on a true
    /// session swap (a new `PaneID`), preserved across reshape/zoom/focus (stable `.id`).
    @State private var showInspector = false

    var body: some View {
        VStack(spacing: 0) {
            inspectorToggleBar
            Divider()
            content
        }
        // Open + fold the inspector second channel once (full replay → live), via the session's single
        // fold point. Mirrors `LivePaneSession.subscribeInspector` (idempotent; re-tail-safe). We do
        // NOT also pass the client to `InspectorPanel` — that would double-subscribe the same stream.
        .task { await live.subscribeInspector() }
    }

    /// macOS: terminal + (optional) inspector side-by-side. iOS: terminal full-bleed; inspector sheet.
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, let model = live.inspector {
                Divider()
                InspectorPanel(model: model)
                    .frame(minWidth: 280, maxWidth: 420)
            }
        }
        #else
        TerminalContentView(live: live, spec: spec, focusCoordinator: focusCoordinator)
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
                    systemImage: showInspector ? "sidebar.right" : "sidebar.squares.right"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide inspector" : "Show inspector")
            .disabled(live.inspector == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Remote GUI composition (video)

/// A `.remoteGUI` leaf: the live ``RemoteWindowPanel`` with the pane-chrome owning close
/// (`showCloseButton: false`). Video decode activates on appear / deactivates on disappear so a
/// hidden / torn-down pane holds no decode stack (docs/22 §7 the video resource ceiling).
private struct RemoteGUIPaneView: View {
    let live: LivePaneSession

    var body: some View {
        Group {
            if let model = live.remoteWindow {
                RemoteWindowPanel(model: model, showCloseButton: false)
            } else {
                Color.clear
            }
        }
        // Activate on appear (decode only the on-screen pane), deactivate on disappear (battery). The
        // session mirrors `isVideoActive`; the store reads that flag to enforce `liveVideoCap`.
        .onAppear { live.setVideoActive(true) }
        .onDisappear { live.setVideoActive(false) }
    }
}
#endif
