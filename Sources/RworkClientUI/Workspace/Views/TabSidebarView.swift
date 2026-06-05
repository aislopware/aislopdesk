#if canImport(SwiftUI)
import SwiftUI

// MARK: - TabSidebarView (the native source-list tab rail)

/// The vertical tab manager — a native source-list rail (docs/22 §1.3, the cmux/herdr/muxy-style
/// vertical tab list). One row per ``Tab``, named, with an SF Symbol for its dominant pane kind, a
/// per-row context menu (rename / close), drag-reorder, and a footer "New tab" control.
///
/// Selection is bound to `workspace.activeTabID` through a computed `Binding` that routes a tap to
/// the store's `selectTab` mutation (so selection stays the store's responsibility, not a stray
/// `@State`). Rename is an inline `TextField` swapped in for the row label while editing, committing
/// through `renameTab`.
struct TabSidebarView: View {
    let store: WorkspaceStore

    /// The id of the tab currently being renamed inline, or `nil`. Local editing state only — the
    /// committed name flows to the store via `renameTab`.
    @State private var renamingTab: TabID?
    /// The working text for the inline rename field.
    @State private var draftName: String = ""
    /// Focus for the inline rename field so it grabs the keyboard the instant it appears.
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        List(selection: selectionBinding) {
            Section("Tabs") {
                ForEach(store.workspace.tabs) { tab in
                    row(for: tab)
                        .tag(tab.id)
                }
                .onMove { source, destination in
                    store.moveTab(from: source, to: destination)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .safeAreaInset(edge: .bottom) { footer }
        .navigationTitle("Workspace")
    }

    // MARK: Row

    @ViewBuilder
    private func row(for tab: Tab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: PaneLeafView.icon(for: dominantKind(of: tab)))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)   // decorative — the tab name Text carries the row's label

            // Tab-level aggregate status dot (research B1): the most salient connection state across
            // the tab's panes, so a single reconnecting/unreachable pane is visible on the rail even
            // when siblings are connected. No dot for an all-video / unconnected tab (`.none`).
            PaneStatusDot(status: tabStatus(tab))

            if renamingTab == tab.id {
                TextField("Tab name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(tab) }
                    #if os(macOS)
                    .onExitCommand { renamingTab = nil }      // Esc cancels (macOS only)
                    #endif
            } else {
                Text(tab.name)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // A small pane-count chip so a multi-pane tab reads as such at a glance.
            let count = tab.root.leafCount
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { beginRename(tab) }
            Button("Close Tab", role: .destructive) { store.closeTab(tab.id) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
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
                // A plain click adds the common case (a terminal); the menu offers the other kinds.
                store.addTab(kind: .terminal)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Selection binding (routes through the store)

    /// A `Binding` over the active tab: reads `workspace.activeTabID`, writes via `selectTab`. Using a
    /// computed binding (not a `@State`) keeps the store the single source of truth for selection so a
    /// programmatic activation (e.g. a new tab) updates the list highlight with no extra wiring.
    private var selectionBinding: Binding<TabID?> {
        Binding(
            get: { store.workspace.activeTabID },
            set: { newValue in
                if let id = newValue { store.selectTab(id) }
            }
        )
    }

    // MARK: Rename flow

    private func beginRename(_ tab: Tab) {
        draftName = tab.name
        renamingTab = tab.id
        renameFieldFocused = true
    }

    private func commitRename(_ tab: Tab) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renameTab(tab.id, trimmed)
        }
        renamingTab = nil
    }

    // MARK: Tab-level status (the row dot)

    /// The aggregate connection status for `tab`'s rail dot: the most salient state across its leaves,
    /// resolved live from the store registry so a reconnecting / unreachable pane surfaces on the rail
    /// even when its siblings are green (the at-a-glance point of the sidebar). Pure fold in
    /// ``PaneConnectionStatus/fold(_:)`` — view-free testable; a `.remoteGUI` / unmaterialized leaf
    /// contributes `.none`.
    private func tabStatus(_ tab: Tab) -> PaneConnectionStatus {
        let statuses = tab.root.allLeafIDs().map { id -> ConnectionViewModel.Status? in
            (store.handle(for: id) as? LivePaneSession)?.connection?.status
        }
        return PaneConnectionStatus.fold(statuses)
    }

    // MARK: Dominant kind (the row glyph)

    /// The kind to represent the whole tab by in the rail. Picks the kind of the focused pane if it
    /// is in the tree, else the first leaf's — a simple, stable heuristic for the row icon.
    private func dominantKind(of tab: Tab) -> PaneKind {
        if let spec = tab.root.spec(for: tab.focusedPane) { return spec.kind }
        if let first = tab.root.allLeafIDs().first, let spec = tab.root.spec(for: first) { return spec.kind }
        return .terminal
    }
}
#endif
