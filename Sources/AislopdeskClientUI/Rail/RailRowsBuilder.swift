// RailRowsBuilder — the pure mapping from the live WorkspaceStore tree → the rail's `[RailRow]` (V1
// "Panes" granularity: one row per visible pane of the active session's tabs). Kept pure + static so
// AislopdeskClientUITests can pin the mapping (selection, title/subtitle, agent status) without a view.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore

/// The data a single rail row binds to (derived from a pane within the active session's tabs). A pure value
/// type — kept with the builder logic (it previously lived in the deleted `TabRow` view, but carries no view
/// / design-system coupling). The native rail in L1+ rebuilds the row VIEW over this same model.
struct RailRow: Identifiable, Equatable {
    let id: PaneID
    let tabID: TabID
    let kind: PaneKind
    let title: String
    let subtitle: String?
    let status: ClaudeStatus
    /// The 1-based tab shortcut number — the ⌘1…⌘9 target = tab index+1 (E6 WI-2). Split-tab panes share
    /// the same `#N` (it is a TAB number, not a pane number), per the per-pane→per-tab mapping (plan Design #1).
    let tabNumber: Int
    /// The single fused status badge for the row (E6 WI-1 `TabBadgeResolver`), or `nil` when all-clear.
    let badge: TabBadgeKind?
    /// The coarse host-reported foreground-process name (wire type 26), shown trailing on the active row; `nil`
    /// when the host has not reported one.
    let processLabel: String?
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    let isSelected: Bool
}

enum RailRowsBuilder {
    /// Build the rail rows for the active session. One row per visible (non-floating) pane of each tab,
    /// in tab order then pre-order pane order. `selected` = the tab is active AND the pane is that tab's
    /// active pane. Agent status comes from the store's per-pane mirror (`.none` ⇒ plain terminal).
    @MainActor
    static func rows(for store: WorkspaceStore) -> [RailRow] {
        guard let session = store.tree.activeSession else { return [] }
        let activeTabIndex = session.activeTabIndex
        var out: [RailRow] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            let tabIsActive = tabIndex == activeTabIndex
            for paneID in tab.root.allPaneIDs() {
                let spec = session.specs[paneID]
                let kind = spec?.kind ?? .terminal
                let title = spec?.lastKnownTitle ?? spec?.title ?? ""
                let subtitle = spec?.lastKnownCwd
                let status = store.paneAgentStatus[paneID] ?? .none
                let isSelected = tabIsActive && tab.activePane == paneID
                // E6 WI-2: the `#N` is the TAB shortcut number (1-based), the trailing label is the host's
                // coarse foreground process, and the row carries ONE fused badge from the pure resolver.
                let processLabel = store.paneForegroundProcess[paneID]
                let badge = TabBadgeResolver.badge(
                    agent: status,
                    completion: store.panePendingCompletion[paneID],
                    isBusy: store.paneIsBusy(paneID),
                    foregroundProcess: processLabel,
                )
                out.append(RailRow(
                    id: paneID,
                    tabID: tab.id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    status: status,
                    tabNumber: tabIndex + 1,
                    badge: badge,
                    processLabel: processLabel,
                    isSelected: isSelected,
                ))
            }
        }
        return out
    }

    /// Filter rows by a lower-cased search query against the title + subtitle (empty query ⇒ all).
    static func filtered(_ rows: [RailRow], query: String) -> [RailRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    /// Compose the sidebar search filter with the store-derived tab grouping (E6 WI-5): narrow `rows` by
    /// `query`, then bucket the survivors into sections following `groups` (``TabOrderingEngine`` tab order, as
    /// returned by ``WorkspaceStore/orderedTabGroups(now:)``). A group whose rows all filter out is DROPPED (no
    /// empty header). Pane order within a tab is preserved (`Dictionary(grouping:)` keeps element order). Pure +
    /// static so the navigator's glue is unit-testable without a SwiftUI view.
    static func sectioned(_ rows: [RailRow], groups: [OrderedTabGroup], query: String) -> [RailRowGroup] {
        let survivors = filtered(rows, query: query)
        let byTab = Dictionary(grouping: survivors, by: \.tabID)
        var out: [RailRowGroup] = []
        for group in groups {
            var groupRows: [RailRow] = []
            for tabID in group.tabIDs {
                groupRows.append(contentsOf: byTab[tabID] ?? [])
            }
            guard !groupRows.isEmpty else { continue }
            out.append(RailRowGroup(header: group.header, rows: groupRows))
        }
        return out
    }
}

/// One rendered sidebar section: an optional `header` (the group title, `nil` ⇒ the ungrouped flat list) and
/// the rows in render order. A pure value (`Equatable`) so ``RailRowsBuilder/sectioned(_:groups:query:)`` is
/// pinnable headlessly; the navigator wraps it in an `Identifiable` row for `ForEach`.
struct RailRowGroup: Equatable {
    let header: String?
    let rows: [RailRow]
}
