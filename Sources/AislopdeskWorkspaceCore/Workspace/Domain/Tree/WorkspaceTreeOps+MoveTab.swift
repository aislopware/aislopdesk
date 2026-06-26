import Foundation

// MARK: - moveTab (manual drag-reorder — pure permutation of the active session's tab array)

/// The pure tab-reorder op behind otty's manual drag-to-reorder in the vertical sidebar (E6 plan WI-3 /
/// Design #4). It ONLY permutes the active session's ``Session/tabs`` array — the **leaf set is
/// unchanged**, so the store wrapper's ``WorkspaceStore/reconcileTree()`` is a registry no-op (no
/// `teardown`, no surface rebuild; the memory rule "never tear down surface"). Selection follows the SAME
/// tab id across the move, mirroring ``WorkspaceTreeOps/selectTab(_:in:)``'s active-state shape.
public extension WorkspaceTreeOps {
    /// Moves the tab at `from` to index `to` in the ACTIVE session, clamping `to` into the valid range and
    /// keeping `activeTabIndex` pointed at the tab that was selected before the move. No-op (returns `ws`
    /// unchanged) when there is no active session, fewer than two tabs, an out-of-range `from`, or the move
    /// is a no-op (`to` clamps back to `from`). Pure — preserves the specs == leafIDs invariant (no leaf is
    /// added/removed) and the active-selection invariants.
    static func moveTab(from: Int, to: Int, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var session = ws.sessions[sIdx]
        let count = session.tabs.count
        // Need ≥ 2 tabs and a real source index; a single-tab session can't reorder.
        guard count > 1, session.tabs.indices.contains(from) else { return ws }
        // Clamp the destination into [0, count - 1] (validate-then-clamp on an untrusted drag index).
        let dest = min(max(to, 0), count - 1)
        guard dest != from else { return ws }
        // Remember the selected tab's IDENTITY so selection follows it across the permutation.
        let activeID = session.tabs.indices.contains(session.activeTabIndex)
            ? session.tabs[session.activeTabIndex].id
            : nil
        let moving = session.tabs.remove(at: from)
        session.tabs.insert(moving, at: dest)
        if let activeID, let newActive = session.tabs.firstIndex(where: { $0.id == activeID }) {
            session.activeTabIndex = newActive
        }
        var copy = ws
        copy.sessions[sIdx] = session
        return copy
    }
}
