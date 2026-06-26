// NavigatorColumn — the left sidebar navigator (otty port). macOS renders otty's flat "TABS" panel: a warm
// `Otty.Surface.sidebar` background (NOT the native `.sidebar` vibrancy/inset-grouped selection — the host
// split item is a PLAIN item now), a "TABS" header with the sort hamburger, a flat search field, and the
// active session's tabs rendered as `OttyTabRow`s — grouped into `OttySectionHeader` sections when the
// hamburger's Group-By is set (E6 WI-5). The top 40pt is reserved for the traffic lights under the hidden
// titlebar.
//
// E6 WI-5 wires the panel to the STORE as the single source of row order:
//   • a flat search field filters via the pure ``RailRowsBuilder/filtered(_:query:)`` (reused, not rebuilt);
//   • the rendered SECTIONS are ``WorkspaceStore/orderedTabGroups(now:)`` (a pure derivation of the store's
//     ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` / recency), so the hamburger's choice — and
//     a manual drag — mutate the STORE, never local `@State` (the E6-carryover binding constraint);
//   • each row carries the new ``RailRow`` chrome (`#N` / cwd subtitle / fused badge / process label);
//   • dragging a row reorders the session's tabs via ``WorkspaceStore/moveTab(from:to:)`` (which flips Sort to
//     Manual) — the leaf set is unchanged, so reconcile is a registry no-op (no surface teardown).
//
// iOS: a `List(selection:)` so NavigationSplitView pushes to the content column on a compact iPhone (a custom
// button list does not drive column navigation). otty-styled but keeps the system list's navigation wiring;
// it gains the same search field, grouped `Section`s, badge + `#N`, and drag reorder under `#if os(iOS)`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct NavigatorColumn: View {
    let store: WorkspaceStore

    /// The transient sidebar search query — narrows the rows via the pure ``RailRowsBuilder/filtered`` (E6
    /// WI-5). View-local `@State`: it is a presentational filter, NOT row order (which lives on the store).
    @State private var query = ""

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

    // MARK: - Sections (store-derived order × pane rows × search filter)

    /// One rendered sidebar section: an optional `header` (the group title, `nil` ⇒ the ungrouped flat list)
    /// and the rows in render order. A pure presentational value — identity is the group's stable key so the
    /// `ForEach` does not churn when a sibling section's contents change.
    private struct RowSection: Identifiable {
        let id: String
        let header: String?
        let rows: [RailRow]
    }

    /// Map the store's ordered tab groups (``WorkspaceStore/orderedTabGroups(now:)``) onto the FILTERED rail
    /// rows via the pure ``RailRowsBuilder/sectioned(_:groups:query:)`` (search × grouping composition, unit-
    /// pinned), then attach a stable `ForEach` identity to each surviving section.
    private func buildSections(_ rows: [RailRow], query: String) -> [RowSection] {
        RailRowsBuilder.sectioned(rows, groups: store.orderedTabGroups(), query: query)
            .enumerated()
            .map { index, group in
                RowSection(id: "\(index)|\(group.header ?? "")", header: group.header, rows: group.rows)
            }
    }

    /// Apply a manual drag-reorder: the payload is the dragged tab's ABSOLUTE `session.tabs` index (the row's
    /// `#N` − 1), the target is the dropped-on row's tab. Routes through ``WorkspaceStore/moveTab(from:to:)``
    /// (which flips Sort → Manual and permutes only the tabs array — no surface teardown). A self / OOB drop is
    /// a no-op (validate-then-drop; never trust the decoded index).
    private func handleTabDrop(_ items: [String], onto target: RailRow) -> Bool {
        guard let raw = items.first, let from = Int(raw) else { return false }
        let to = target.tabNumber - 1
        guard from >= 0, from != to else { return false }
        store.moveTab(from: from, to: to)
        return true
    }

    #if os(macOS)
    /// otty's flat macOS search field: a filled, hairline-bordered plate with a leading magnifier and a
    /// trailing clear `×` (only when non-empty). Binds the view-local `query`. (iOS uses the system
    /// `.searchable` instead, so this custom field is macOS-only.)
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.icon)
            TextField("Search tabs", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.icon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Otty.Surface.card, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
        )
    }

    /// macOS: otty's flat "TABS" panel — name rows + white-card active, hamburger sort, search field, grouped
    /// sections. Paints its own warm background (the host `NSSplitViewItem` is a plain item, so there is no
    /// native vibrancy/rounding).
    private var macSidebar: some View {
        let allRows = RailRowsBuilder.rows(for: store)
        let sections = buildSections(allRows, query: query)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40) // reserve the titlebar / traffic-light strip
            HStack(spacing: 0) {
                Text("TABS")
                    .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Otty.State.header)
                Spacer(minLength: 0)
                OttySortMenuButton(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if allRows.isEmpty {
                        emptyLabel("No tabs open")
                    } else if sections.isEmpty {
                        emptyLabel("No matches")
                    } else {
                        ForEach(sections) { section in
                            if let header = section.header {
                                OttySectionHeader(header)
                            }
                            ForEach(section.rows) { row in
                                macRow(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden) // otty's invisible scrollbars
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Otty.Surface.sidebar)
    }

    /// One macOS tab row: the full otty chrome (badge / `#N` / cwd subtitle / process label) plus the
    /// drag-reorder source + drop target wired to ``WorkspaceStore/moveTab``.
    private func macRow(_ row: RailRow) -> some View {
        OttyTabRow(
            title: row.title.isEmpty ? defaultTitle(for: row.kind) : row.title,
            active: row.id == selectedPane,
            number: row.tabNumber,
            subtitle: row.subtitle,
            processLabel: row.processLabel,
            badge: row.badge,
            onSelect: { select(row.id) },
            onClose: { store.requestClosePaneTree(row.id) },
        )
        .draggable(String(row.tabNumber - 1))
        .dropDestination(for: String.self) { items, _ in handleTabDrop(items, onto: row) }
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }
    #else
    /// iOS: a system `List(selection:)` so NavigationSplitView pushes to content on compact; otty-styled. Gains
    /// the system `.searchable` field (keeps the `List` as the column root so the navigation push is unchanged),
    /// grouped `Section`s, badge + `#N`, and drag reorder (E6 WI-5).
    private var iosSidebar: some View {
        let allRows = RailRowsBuilder.rows(for: store)
        let sections = buildSections(allRows, query: query)
        let selection = Binding<PaneID?>(
            get: { selectedPane },
            set: { if let paneID = $0 { select(paneID) } },
        )
        return List(selection: selection) {
            if allRows.isEmpty {
                Label("No tabs open", systemSymbol: .squareSplit2x1)
                    .foregroundStyle(Otty.Text.secondary)
            } else if sections.isEmpty {
                Label("No matches", systemSymbol: .magnifyingglass)
                    .foregroundStyle(Otty.Text.secondary)
            } else {
                ForEach(sections) { section in
                    Section(section.header ?? "Tabs") {
                        ForEach(section.rows) { row in
                            iosRow(row)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Otty.Surface.sidebar)
        .tint(Otty.State.accent)
        .searchable(text: $query, prompt: "Search tabs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
            }
        }
    }

    /// One iOS list row: the system `Label` (navigation wiring via `.tag`) plus the trailing fused badge and
    /// monospaced `#N`, and the same drag-reorder source/target as macOS.
    private func iosRow(_ row: RailRow) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(row.title.isEmpty ? defaultTitle(for: row.kind) : row.title)
                    .lineLimit(1)
            } icon: {
                Image(systemSymbol: Self.symbol(for: row.kind))
            }
            Spacer(minLength: 6)
            if let badge = row.badge {
                TabBadgeView(kind: badge)
            }
            if row.tabNumber > 0 {
                Text("#\(row.tabNumber)")
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
                    .foregroundStyle(Otty.Text.secondary)
            }
        }
        .tag(row.id)
        .draggable(String(row.tabNumber - 1))
        .dropDestination(for: String.self) { items, _ in handleTabDrop(items, onto: row) }
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
        PaneChooserRegistry.option(for: kind).title
    }

    /// Type-safe SF Symbol for a pane kind (iOS rows only; macOS otty rows are name-only). Reads the
    /// symbol *name* from the shared ``PaneChooserRegistry`` and wraps it in a type-safe `SFSymbol`.
    private static func symbol(for kind: PaneKind) -> SFSymbol {
        SFSymbol(rawValue: PaneChooserRegistry.option(for: kind).symbol)
    }
}
#endif
