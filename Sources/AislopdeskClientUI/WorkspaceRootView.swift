// WorkspaceRootView — the top-level window composition (warp-window-chrome.md §9).
//
// Stack: 1pt WORKSPACE_PADDING inset → window background (theme.background) → a column of
// [WindowTopBar (35pt)] over a [body row: VerticalTabRail | 1pt PanelSeparator | SplitContainer]. The
// content area renders the active tab's pane tree (L3) via the `SplitTreeRenderModel` + the renderer seam.
//
// L5: the whole window is wrapped in a ZStack with the `OverlayLayer` (command palette / busy-close confirm
// modal / Settings overlay / toast stack) floating above. The single `OverlayCoordinator` owns the
// palette/settings/toast state; the Omnibar tap + ⌘⇧P / ⌘K open the palette; the top-bar settings icon +
// the palette "Open Settings" row open the Settings overlay. Store notifications are bridged to toasts.
//
// The rail is hidden when `store.sidebarCollapsed`. All chrome reads `@Environment(\.theme)`; mutations
// route through the store.

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

public struct WorkspaceRootView: View {
    @Environment(\.theme) private var theme

    private let store: WorkspaceStore
    private let connection: AppConnection

    /// The single overlay coordinator (palette / settings / toasts). Built once here, attached to the store.
    @State private var overlay: OverlayCoordinator
    /// UserDefaults-backed settings model for the Settings overlay (persists across opens).
    @State private var settings = SettingsModel()

    public init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
        _overlay = State(initialValue: OverlayCoordinator(store: store))
    }

    public var body: some View {
        ZStack {
            chrome
            OverlayLayer(coordinator: overlay, store: store, settings: settings)
        }
        .overlayCoordinator(overlay)
        .background(theme.background)
        #if os(macOS)
            .background(WindowConfigurator())
        #endif
            .onAppear {
                overlay.attach(store)
                // L6: the Remote-Window picker discovers against the live app host.
                overlay.connectionTarget = { [weak connection] in connection?.target ?? .default }
                bridgeNotificationsToToasts()
            }
        // Keyboard entry points for the palette. ⌘⇧P (toggle, Command mode) + ⌘K (open). Both ⌘-prefixed
        // and never bare ⌘A/C/V/W (repo guardrail). The buttons are zero-size; SwiftUI routes the shortcut.
        #if os(macOS) || os(iOS)
            .background {
                Group {
                    Button("") { overlay.togglePalette(mode: .command) }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("") { overlay.openPalette(mode: .command) }
                        .keyboardShortcut("k", modifiers: [.command])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        #endif
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            WindowTopBar(
                sidebarCollapsed: store.sidebarCollapsed,
                onToggleSidebar: { store.toggleSidebarCollapsed() },
                onOpenSettings: { overlay.openSettings() },
                onOpenOmnibar: { overlay.openPalette(mode: .titleBarSearch) },
            )
            HStack(spacing: 0) {
                if !store.sidebarCollapsed {
                    VerticalTabRail(store: store)
                    PanelSeparator()
                }
                SplitContainer(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(WarpSpace.workspacePadding)
    }

    /// Bridge the store's pane-notification / long-command / agent-attention sinks to toasts. These sinks
    /// are also wired (on macOS) to OS notifications in the App scene; here we ADD an in-app toast so the
    /// overlay layer surfaces them even when the app is foregrounded. Idempotent re-wire is safe (last
    /// writer wins) — we chain to keep the existing OS-notification behavior.
    @MainActor
    private func bridgeNotificationsToToasts() {
        let priorPane = store.onPaneNotification
        store.onPaneNotification = { [weak overlay = overlay] paneID, paneTitle, title, body in
            priorPane?(paneID, paneTitle, title, body)
            overlay?.pushToast(Toast(
                id: "pane.\(paneID.raw.uuidString)", flavor: .default,
                title: title.isEmpty ? paneTitle : title, body: body,
            ))
        }
        let priorLong = store.onLongCommandNotify
        store.onLongCommandNotify = { [weak overlay = overlay] paneIDKey, paneTitle, exitCode, durationMS in
            priorLong?(paneIDKey, paneTitle, exitCode, durationMS)
            let ok = (exitCode ?? 0) == 0
            let codeText = exitCode.map { "Exit \($0)" } ?? "Done"
            overlay?.pushToast(Toast(
                id: "long.\(paneIDKey)", flavor: ok ? .success : .error,
                title: paneTitle.isEmpty ? "Command finished" : paneTitle,
                body: "\(codeText) · \(durationMS) ms",
            ))
        }
        let priorAttn = store.onAgentAttention
        store.onAgentAttention = { [weak overlay = overlay] paneIDKey, name, needsInput, detail in
            priorAttn?(paneIDKey, name, needsInput, detail)
            overlay?.pushToast(Toast(
                id: "attn.\(paneIDKey)", flavor: .attention,
                title: name, body: needsInput ? "needs your input" : (detail ?? "finished"),
                autoDismiss: needsInput ? nil : .seconds(4),
            ))
        }
    }
}
