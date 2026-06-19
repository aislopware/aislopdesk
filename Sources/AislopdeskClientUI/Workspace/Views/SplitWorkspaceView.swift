#if canImport(SwiftUI)
import SwiftUI

// MARK: - SplitWorkspaceView (the IDE shell root — W5)

/// The coding-IDE shell that replaces `CanvasView` as the live workspace content (docs/41 §3.4,
/// docs/42 W5): a **sessions sidebar** (``SessionSidebarView``, grouped by host with rolled-up agent
/// status dots) + a **detail** that stacks the active session's **tab bar** (``TabBarView``) over the
/// **recursive split content** (``SplitTreeView``). Binds the LIVE ``WorkspaceStore/tree``.
///
/// `WorkspaceRootView` presents this for the regular-width macOS/iPad path; the compact (iPhone)
/// projection keeps the existing carousel for now (a full iOS tree shell is a later item — see the
/// `SplitWorkspaceView.compact` note).
struct SplitWorkspaceView: View {
    @Bindable var store: WorkspaceStore

    /// The sidebar visibility — bound so the toolbar toggle and the hidden-titlebar traffic-light overlap
    /// both behave; `.automatic` shows the sidebar on regular width.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(store: store)
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            #endif
        } detail: {
            detail
        }
    }

    // MARK: Detail (tab bar over recursive split content)

    @ViewBuilder
    private var detail: some View {
        if let session = store.tree.activeSession, let tab = session.activeTab {
            VStack(spacing: 0) {
                TabBarView(store: store, session: session)
                SplitTreeView(store: store, session: session, tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 360)
            #endif
        } else {
            // A live tree is never empty (the ops re-seed a default), so this is only a transient
            // pre-materialize state.
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session", systemImage: "rectangle.split.3x1")
        } description: {
            Text("Create a session to get started.")
        } actions: {
            Button("New Session") {
                store.newSession(name: "Local", kind: SettingsKey.defaultPaneKind)
            }
        }
    }
}
#endif
