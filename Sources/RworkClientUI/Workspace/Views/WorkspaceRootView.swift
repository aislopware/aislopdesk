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
/// - **compact** → the ``PaneCarouselView``: the SAME tree projected to one swipeable leaf at a time
///   (an always-on zoom — docs/22 §4). The flip is view-only: it swaps the projection without calling
///   `reconcile()`, dropping focus, or tearing down sessions.
///
/// It also publishes its store as the focused scene value (so the menu-bar / iPad ``WorkspaceCommands``
/// target THIS window — docs/22 §5) and hosts the ⌘K ``CommandPaletteView`` overlay.
///
/// The shell carries the macOS minimum size (`minWidth: 720`, `minHeight: 480`) so the floor lives on
/// the WINDOW, never on the pane views (docs/22 §3).
public struct WorkspaceRootView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The sidebar's visibility — `.automatic` by default (the system shows sidebar + detail on regular
    /// width and collapses on compact). Bound so the toolbar's sidebar toggle and the compact collapse
    /// both work natively. The compact carousel's "show tabs" affordance flips this to `.all` to reveal
    /// the tab drawer.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Whether the ⌘K command palette is presented (docs/22 §5). Window-level UI state: the palette is
    /// overlaid on the whole shell and toggled by the ⌘K chord below — a ⌘-prefixed shortcut, so the
    /// focused terminal never sees it (the §5 conflict rule). `false` ⇒ the overlay renders an empty,
    /// zero-cost branch.
    @State private var showCommandPalette = false

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
        // Publish the store so the scene-level ``WorkspaceCommands`` (menu bar / iPad ⌘-HUD) resolve
        // THIS window's store via `@FocusedValue(\.workspaceStore)` — one window today, the key window
        // automatically with multi-window later (docs/22 §5).
        .publishingWorkspaceStore(store)
        // The ⌘K command palette overlay (docs/22 §5): a Spotlight-style floating card with its own
        // dimming backdrop, top-third placement. An unconditional overlay because the view renders an
        // empty branch when hidden (zero cost) — and an overlay, not a `.sheet`, so it owns its own
        // backdrop + placement rather than fighting sheet chrome.
        .overlay { CommandPaletteView(store: store, isPresented: $showCommandPalette) }
        // Toggle the palette with ⌘K. A ⌘-prefixed chord ⇒ obeys the §5 conflict rule (the terminal
        // never receives it). The hidden button keeps the chord scoped to the workspace window.
        .background {
            Button("Command Palette") { showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
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
                if store.activeTab != nil {
                    if compact {
                        // Compact (iPhone / iPad-compact): the SAME tree projected to one swipeable
                        // leaf at a time (docs/22 §4). The carousel's "show tabs" reveals the shell
                        // sidebar by flipping `columnVisibility`. A regular↔compact flip swaps ONLY
                        // this branch — view-only, no reconcile / focus drop / session teardown.
                        PaneCarouselView(store: store, onShowTabs: { columnVisibility = .all })
                    } else {
                        PaneTreeView(node: store.activeTab!.root, store: store, tab: store.activeTab!.id)
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
