// PaneContainer — one placed leaf = a 34pt PaneHeader over the pane content (warp-panes-blocks.md §1.3).
//
// Focus signals (NOT a border, spec §1.3):
//   - an UNFOCUSED pane that is in a split gets a `inactive_pane_overlay` (fg@10%) dim overlay, and
//   - the FOCUSED pane gets a 16pt accent corner triangle at the top-leading corner.
// Tap anywhere in the pane focuses it via the store (`focusPaneTree`).
//
// The whole pane is keyed `.id(PaneID)` by the SplitContainer so the surface/connection are never reused
// across panes (identity hazard, logic-api §9).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneContainer: View {
    @Environment(\.theme) private var theme
    /// The single live preferences owner (injected at the scene root) — the agent footer's W4
    /// notification dismissal/enable persistence. `nil` outside the app scene (tests/previews).
    @Environment(\.preferencesStore) private var preferences

    let store: WorkspaceStore
    let paneID: PaneID
    /// Whether this pane is the active tab's active (focused) pane.
    let isFocused: Bool
    /// Whether this pane lives in a split (≥2 panes in the tab) — gates the dim overlay + close button.
    let isInSplit: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// The Claude-Code bottom-bar coordinator — built lazily once per pane (PaneContainer is `.id`-keyed
    /// so a fresh `@State` is fine). `nil` until first built.
    @State private var footerCoordinator: AgentInputFooterCoordinator?

    /// The live session for this pane (terminal model / input bar / claude status), if materialized.
    private var live: LivePaneSession? { store.handle(for: paneID) as? LivePaneSession }

    private var spec: PaneSpec? {
        store.tree.activeSession?.specs[paneID]
    }

    /// The agent display-name (the green pill label + the persistence key). Prefer the detected
    /// foreground process name, else "Claude Code".
    private var agentName: String {
        let name = live?.foregroundProcessName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Claude Code" : name
    }

    /// Build (or rebuild) the footer coordinator for this pane, wiring the parent-side hooks.
    private func ensureCoordinator() {
        guard footerCoordinator == nil else { return }
        let coordinator = AgentInputFooterCoordinator(
            agentName: agentName,
            inputBar: live?.inputBar,
            preferences: preferences,
            cwd: spec?.lastKnownCwd,
            isRemote: false, // terminal pane — local cwd listing (remote stub handled in the model)
        )
        // W1: open the remote-window picker (the full video pane mount is L6). For now this surfaces the
        // intent; TODO(L6): route to RemoteWindowModel.open / the host window picker + video pane mount.
        coordinator.onStartRemoteControl = {}
        // Route to the coding-agent settings (Settings overlay lands in L5). TODO(L5).
        coordinator.onOpenSettings = {}
        coordinator.onAddContext = {}
        // A file chosen in the explorer → insert its path into the prompt (the input-bar compose buffer).
        coordinator.onSelectFile = { [weak inputBar = live?.inputBar] path in
            guard let inputBar else { return }
            inputBar.compose += (inputBar.compose.isEmpty ? "" : " ") + path
        }
        footerCoordinator = coordinator
    }

    private var title: String {
        let t = spec?.lastKnownTitle ?? live?.terminalModel?.title ?? spec?.title ?? ""
        return t.isEmpty ? "Terminal" : t
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: title,
                isActive: isFocused,
                isInSplit: isInSplit,
                onClose: { store.requestClosePaneTree(paneID) },
                onOverflow: {}, // pane overflow menu wired in L5
            )
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                cwd: spec?.lastKnownCwd,
                footerCoordinator: footerCoordinator,
                staticMirror: staticMirror,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .onAppear { ensureCoordinator() }
        // Keep the coordinator's cwd current so the file explorer lists the right directory.
        .onChange(of: spec?.lastKnownCwd) { _, newCwd in footerCoordinator?.cwd = newCwd }
        // Dim an unfocused pane that is in a split (spec §1.3) — a foreground overlay, never a content swap.
        .overlay {
            if isInSplit, !isFocused {
                theme.inactivePaneOverlay.allowsHitTesting(false)
            }
        }
        // The focused-pane corner triangle (16pt accent, top-leading) — NOT a border (spec §2.4).
        .overlay(alignment: .topLeading) {
            if isFocused, isInSplit {
                CornerTriangle().fill(theme.accent).frame(width: 16, height: 16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focusPaneTree(paneID) }
    }
}

/// An upper-left right-triangle (the active-pane indicator, spec §2.4): a filled corner notch.
struct CornerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
