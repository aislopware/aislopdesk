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
                out.append(RailRow(
                    id: paneID,
                    tabID: tab.id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    status: status,
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
}
