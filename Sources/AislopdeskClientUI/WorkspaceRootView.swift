// WorkspaceRootView — the top-level window composition (warp-window-chrome.md §9).
//
// Stack: 1pt WORKSPACE_PADDING inset → window background (theme.background) → a column of
// [WindowTopBar (35pt)] over a [body row: VerticalTabRail | 1pt PanelSeparator | SplitContainer]. The
// content area renders the active tab's pane tree (L3) via the `SplitTreeRenderModel` + the renderer seam.
//
// The rail is hidden when `store.sidebarCollapsed`. All chrome reads `@Environment(\.theme)`; mutations
// route through the store.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

public struct WorkspaceRootView: View {
    @Environment(\.theme) private var theme

    private let store: WorkspaceStore
    private let connection: AppConnection

    /// Hook to open the command palette (wired in L5). No-op at L2.
    var onOpenPalette: () -> Void = {}
    /// Hook to open settings (wired later). No-op at L2.
    var onOpenSettings: () -> Void = {}

    public init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTopBar(
                sidebarCollapsed: store.sidebarCollapsed,
                onToggleSidebar: { store.toggleSidebarCollapsed() },
                onOpenSettings: onOpenSettings,
                onOpenOmnibar: onOpenPalette,
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
        .background(theme.background)
        #if os(macOS)
            .background(WindowConfigurator())
        #endif
    }
}
