#if canImport(SwiftUI)
import SwiftUI

// MARK: - TabBarView (the active session's tab strip — W5)

/// The slim coding-IDE tab strip for the active session (docs/42 W5): one pill per ``Tab`` (select /
/// close / double-click-to-rename), a rolled-up ``AgentStatusDot`` per tab, and a `+` to open a new tab.
/// Drives the store's tree ops (`selectTab` / `closeTab` / `newTab` / `renameTab`).
struct TabBarView: View {
    @Bindable var store: WorkspaceStore
    let session: Session

    /// The tab whose inline rename field is open (double-click / context-menu Rename), or `nil`.
    @State private var renamingTab: TabID?
    @State private var renameText: String = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabPill(tab: tab, index: index, isActive: index == session.activeTabIndex)
                }
                newTabButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Tab pill

    private func tabPill(tab: Tab, index: Int, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            AgentStatusDot(status: store.rollupStatus(forTab: tab.id), size: 6)
            if renamingTab == tab.id {
                TextField("Tab", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(minWidth: 60, maxWidth: 160)
                    .onSubmit { commitRename(tab.id) }
                    .onExitCommand { renamingTab = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            } else {
                Text(tabTitle(tab))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Close affordance (hidden inline rename keeps it out of the way).
            if renamingTab != tab.id {
                Button {
                    store.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close tab")
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1),
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(index) }
        .onTapGesture(count: 2) { beginRename(tab) }
        .contextMenu {
            Button("Rename…") { beginRename(tab) }
            Button("Close Tab", role: .destructive) { store.closeTab(tab.id) }
        }
    }

    private var newTabButton: some View {
        Button {
            store.newTab(kind: SettingsKey.defaultPaneKind)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("New tab (⌘T)")
        .accessibilityLabel("New tab")
    }

    // MARK: Title + rename

    /// The tab's title, deriving from the active pane's live OSC title when the tab has no explicit name.
    private func tabTitle(_ tab: Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let active = tab.activePane, let spec = store.tree.spec(for: active) {
            return PanePresentation.displayTitle(store.handle(for: active), spec: spec)
        }
        return "Tab"
    }

    private func beginRename(_ tab: Tab) {
        renameText = tabTitle(tab)
        renamingTab = tab.id
    }

    private func commitRename(_ id: TabID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameTab(id, to: trimmed)
        renamingTab = nil
    }
}
#endif
