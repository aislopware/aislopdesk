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
///
/// TODO(iOS tree carousel — deferred, see DECISIONS #8): there is no compact/iPhone per-tab tree
/// projection yet. The regular `NavigationSplitView` shell here is the only tree projection; the iPhone
/// per-tab carousel is deliberately DEFERRED (and is currently blocked by pre-existing iOS UIKit rot —
/// not built in this pass). Do not treat its absence as an accident.
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
        if let session = store.tree.activeSession, let activeTab = session.activeTab {
            VStack(spacing: 0) {
                TabBarView(store: store, session: session)
                panesHost(activeTabID: activeTab.id)
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

    /// Mounts EVERY tab of every session at once, showing only the active one. Keeping the inactive tabs
    /// mounted (at `opacity 0`, hit-testing off — the same no-teardown trick `SplitTreeView` uses for zoom,
    /// here extended ACROSS tabs/sessions) means a pane's libghostty surface is NEVER torn down + recreated
    /// on a tab/session switch. That recreate — surface rebuilt at a possibly-different backing scale, byte
    /// ring replayed, grid reflowed — is exactly what dropped a segment of the prompt on switch (HW-found).
    /// Switching is now a pure visibility flip; the hidden surfaces keep rendering their live output, so a
    /// tab is already current the instant it is shown. (Creating/closing a tab still mounts/unmounts that
    /// one tab — only SWITCHING is teardown-free.)
    private func panesHost(activeTabID: TabID) -> some View {
        ZStack {
            ForEach(hostedTabs, id: \.tab.id) { hosted in
                let active = hosted.tab.id == activeTabID
                SplitTreeView(store: store, session: hosted.session, tab: hosted.tab, isActive: active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .zIndex(active ? 1 : 0)
            }
        }
    }

    /// Every (session, tab) pair across the whole workspace, in a stable order. `TabID` is globally unique,
    /// so the `ForEach` identity is stable → no view (and no surface) remounts on a switch.
    private var hostedTabs: [(session: Session, tab: Tab)] {
        store.tree.sessions.flatMap { session in session.tabs.map { (session: session, tab: $0) } }
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
