// ContentColumn — the centre content area (REBUILD-V2, L2). Renders the active tab's pane tree via the
// identity-preserving `SplitContainer`; a native `ContentUnavailableView` empty-state when no session/tab.
// SYSTEM colours only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection

    private var hasActiveTab: Bool { store.tree.activeSession?.activeTab != nil }

    var body: some View {
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
        .background(NativePaneColor.window)
    }
}
#endif
