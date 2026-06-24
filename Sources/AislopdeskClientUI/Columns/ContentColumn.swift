// ContentColumn — the centre content area (otty port). Renders the active tab's pane tree via the
// identity-preserving `SplitContainer` (a native `ContentUnavailableView` empty-state when no session/tab),
// with otty's hover-reveal titlebar floating as a TOP overlay. The titlebar lives here (not at window level)
// so its centred title menu centres over the content area for free, and the terminal extends under it
// (otty's clean resting silhouette). The shared `WorkspaceChromeState` drives the sidebar/Details toggles.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Otty.Surface.window)
        #if os(macOS)
            .overlay(alignment: .top) { OttyTitlebar(store: store, chrome: chrome) }
        #endif
    }

    /// On macOS the pane area is pushed below the hover-reveal titlebar strip (so the terminal starts under
    /// it, not under the centred title); iOS has no titlebar so the pane area fills directly.
    private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Color.clear.frame(height: Otty.Metric.titlebarHeight)
            paneArea
        }
        #else
        paneArea
        #endif
    }

    private var paneArea: some View {
        Group {
            if hasActiveTab {
                SplitContainer(store: store)
            } else {
                ContentUnavailableView(
                    "No Session",
                    systemImage: "terminal",
                    description: Text("Connect to a host or open a tab"),
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
