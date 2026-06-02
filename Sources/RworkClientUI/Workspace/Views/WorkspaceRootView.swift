#if canImport(SwiftUI)
import SwiftUI

// MARK: - WorkspaceRootView (the native shell)

/// The root of the workspace UI: a `NavigationSplitView` whose sidebar is the tab rail
/// (``TabSidebarView``) and whose detail is the active tab's pane area (docs/22 §1.3, §4).
///
/// `NavigationSplitView` is the responsive spine (docs/22 §4): it gives the native macOS source-list
/// sidebar + detail for free on regular width, and collapses the sidebar into the navigation stack
/// on compact width. The ONLY size-class adaptation switch in the whole app lives in ``detail`` — it
/// computes `WorkspaceLayout.isCompact(...)` once and branches:
/// - **regular** → the full recursive ``PaneTreeView`` (splits, dividers, zoom, multi-pane).
/// - **compact** → a WF4 placeholder: just the focused leaf full-bleed. The polished
///   `TabView(.page)` carousel comes in WF6; rendering only the focused leaf here is the correct,
///   lossless interim (the same tree, projected to one visible pane — docs/22 §4).
///
/// The shell carries the macOS minimum size (`minWidth: 720`, `minHeight: 480`) so the floor lives on
/// the WINDOW, never on the pane views (docs/22 §3).
public struct WorkspaceRootView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The sidebar's visibility — `.all` (sidebar + detail) by default on regular width. Bound so the
    /// toolbar's sidebar toggle and the compact collapse both work natively.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    public init(store: WorkspaceStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TabSidebarView(store: store)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                #endif
        } detail: {
            detail
                .toolbar { detailToolbar }
                .navigationTitle(store.activeTab?.name ?? "Rwork")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }

    // MARK: Detail (the ONE responsive switch — docs/22 §4)

    @ViewBuilder
    private var detail: some View {
        GeometryReader { geo in
            let compact = WorkspaceLayout.isCompact(
                horizontalSizeClassCompact: horizontalSizeClass == .compact,
                width: geo.size.width
            )

            Group {
                if let tab = store.activeTab {
                    if compact {
                        compactDetail(for: tab)
                    } else {
                        PaneTreeView(node: tab.root, store: store, tab: tab.id)
                            .padding(6)
                    }
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(.background)
    }

    /// WF4 compact fallback (docs/22 §4): render only the focused leaf full-bleed. The polished
    /// swipe carousel (`TabView(.page)` bound to `focusedPane`) is WF6 — this interim keeps the tree
    /// identical and lossless, just projected to one visible pane. Wrapped in `PaneChromeView` so the
    /// pane controls (split/zoom/close) stay reachable on compact too.
    @ViewBuilder
    private func compactDetail(for tab: Tab) -> some View {
        if let spec = tab.root.spec(for: tab.focusedPane) {
            let id = tab.focusedPane
            PaneChromeView(
                id: id,
                spec: spec,
                handle: store.handle(for: id),
                isFocused: true,
                isZoomed: tab.zoomedPane == id,
                store: store
            ) {
                PaneLeafView(handle: store.handle(for: id), spec: spec, isFocused: true)
            }
            // Stable identity even in the compact projection — a regular↔compact flip must NOT tear
            // down the live session (docs/22 §4, §9.9).
            .id(id)
            .padding(8)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Pane", systemImage: "rectangle.dashed")
        } description: {
            Text("Add a tab to get started.")
        } actions: {
            Button("New Tab") { store.addTab(kind: .terminal) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { store.addTab(kind: .terminal) } label: {
                    Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
                }
                Button { store.addTab(kind: .claudeCode) } label: {
                    Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
                }
                Button { store.addTab(kind: .remoteGUI) } label: {
                    Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
                }
            } label: {
                Label("New Tab", systemImage: "plus")
            } primaryAction: {
                store.addTab(kind: .terminal)
            }
            .help("New tab")
        }
    }
}
#endif
