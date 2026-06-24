// NavigatorColumn — the left sidebar navigator (REBUILD-V2, L2 → L7 otty restyle).
//
// macOS: a clean otty-style sidebar — a `ScrollView` of `OttySidebarRow` buttons (one per visible pane of
// the active session's tabs, via the kept-pure `RailRowsBuilder`) under an `OttySectionHeader`. Background
// left CLEAR so the hosting `NSSplitViewItem`'s native sidebar vibrancy shows through (otty's "one shared
// material backdrop"); selection is a NEUTRAL gray plate (otty), not the system accent highlight.
//
// iOS: a `List(selection:)` so the NavigationSplitView actually PUSHES to the content column on a compact
// iPhone (a custom button list does not drive NavigationSplitView's column navigation). It is otty-styled
// (Paper background, accent tint, the same icon/title rows) but keeps the system list's navigation wiring.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI
#if os(macOS)
import SwiftUIIntrospect
#endif

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The active tab's active pane — drives which row reads as selected.
    private var selectedPane: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    var body: some View {
        #if os(macOS)
        macSidebar
        #else
        iosSidebar
        #endif
    }

    #if os(macOS)
    /// macOS: custom otty row list over the NSSplitViewItem vibrancy (neutral selection, full control).
    private var macSidebar: some View {
        let rows = RailRowsBuilder.rows(for: store)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                OttySectionHeader("Workspace") {
                    OttyPlateButton(symbol: .plus, help: "New tab", plate: 20) {
                        store.newTabDefault()
                    }
                }
                if rows.isEmpty {
                    Label("No tabs open", systemSymbol: .squareSplit2x1)
                        .font(.system(size: Otty.Typeface.base))
                        .foregroundStyle(Otty.Text.secondary)
                        .padding(.horizontal, Otty.Metric.space2)
                        .padding(.vertical, 5)
                } else {
                    ForEach(rows) { row in
                        OttySidebarRow(
                            symbol: Self.symbol(for: row.kind),
                            title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
                            subtitle: row.subtitle,
                            isSelected: row.id == selectedPane,
                            action: { select(row.id) },
                        )
                    }
                }
            }
            .padding(Otty.Metric.space2)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden) // otty's invisible scrollbars
        .background(.clear)
        // Let the NSSplitViewItem sidebar vibrancy show through cleanly (otty's shared material backdrop):
        // stop the NSScrollView from painting its own opaque background.
        .introspect(.scrollView, on: .macOS(.v26)) { (scrollView: NSScrollView) in
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
    }
    #else
    /// iOS: a system `List(selection:)` so NavigationSplitView pushes to content on compact; otty-styled.
    private var iosSidebar: some View {
        let rows = RailRowsBuilder.rows(for: store)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            Section("Workspace") {
                if rows.isEmpty {
                    Label("No tabs open", systemSymbol: .squareSplit2x1)
                        .foregroundStyle(Otty.Text.secondary)
                } else {
                    ForEach(rows) { row in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title.isEmpty ? defaultTitle(for: row.kind) : row.title)
                                    .lineLimit(1)
                                if let subtitle = row.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Otty.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        } icon: {
                            Image(systemSymbol: Self.symbol(for: row.kind))
                        }
                        .tag(row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Otty.Surface.sidebar)
        .tint(Otty.State.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.newTabDefault() } label: { Image(systemSymbol: .plus) }
            }
        }
    }
    #endif

    /// Make the row's tab active (if it isn't) then focus its pane. Both go through the store.
    private func select(_ paneID: PaneID) {
        if let session = store.tree.activeSession {
            for (index, tab) in session.tabs.enumerated()
                where tab.root.allPaneIDs().contains(paneID)
            {
                if index != session.activeTabIndex { store.selectTab(index) }
                break
            }
        }
        store.focusPaneTree(paneID)
    }

    private func defaultTitle(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "Terminal"
        case .remoteGUI: "Remote window"
        case .systemDialog: "System dialog"
        }
    }

    /// Type-safe SF Symbol for a pane kind (via SFSafeSymbols — compile-time availability-checked).
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        switch kind {
        case .terminal: .terminal
        case .remoteGUI: .display
        case .systemDialog: .lockShield
        }
    }
}
#endif
