import Foundation

// MARK: - WorkspaceStore × Sequential pane cycle + reopen-closed (E1 ES-E1-2 store hooks)

/// The E1 sequential-pane-cycle (⌘]/⌘[) and reopen-closed-pane (⌘⇧T) store hooks, split into their own
/// extension so the (already large) ``WorkspaceStore`` body stays under the lint type-body ceiling — the
/// same reason ``WorkspaceStore+FontScroll`` and ``WorkspaceStore+Blocks`` exist.
public extension WorkspaceStore {
    /// Sequentially cycles focus through the ACTIVE TAB's panes in pre-order DFS — the ⌘]/⌘[ "focus next/
    /// previous pane" chord (E1 ES-E1-2; distinct from ⌘⇧]/⌘⇧[ tab cycling). `forward == true` steps to the
    /// next leaf in DFS order, `false` to the previous; the walk WRAPS (last → first / first → last). A no-op
    /// when the active tab has fewer than two panes (nothing to cycle to). Routes the resolved target through
    /// ``focusPaneTree(_:)`` so it shares the focus/raise/reconcile path of every other tree-focus change.
    func cyclePaneFocusTree(forward: Bool) {
        if let target = paneCycleTreeTarget(forward: forward) { focusPaneTree(target) }
    }

    /// The pane a ``cyclePaneFocusTree(forward:)`` step would focus, or `nil` when it is a no-op (no active
    /// tab, fewer than two panes, or no resolvable active pane to step from). Pure (no focus side effect) so
    /// the `count > 1` wrap guard is unit-testable in isolation — mirrors ``recentPaneTarget(forward:)`` /
    /// ``inGroupCycleTarget(forward:)``. The order is the active tab's ``Tab/allPaneIDs()`` (pre-order DFS +
    /// the floating layer), the same order the reconcile diff + carousel read.
    internal func paneCycleTreeTarget(forward: Bool) -> PaneID? {
        guard let tab = tree.activeSession?.activeTab else { return nil }
        let ids = tab.allPaneIDs()
        guard ids.count > 1 else { return nil }
        // Step from the active pane; an unresolved active (absent from the list) starts the walk at the front.
        let current = tab.activePane.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
        return ids[next]
    }

    /// Reopens the most recently CLOSED tree pane (the ⌘⇧T "Reopen Closed Pane" chord). EMPTY stub for E1 —
    /// the routing case is live (no dead chord) but the LIFO of closed-pane records the reopen restores from
    /// lands in E3 (per the E1 plan: register + route now, behaviour later). A documented graceful no-op
    /// until then. (The canvas path's single-slot ``reopenClosedPane()`` is a separate, retained-but-dead
    /// mechanism; the tree shell gets its own LIFO in E3.)
    func reopenLastClosedPane() {
        // E3 fills the closed-pane LIFO + the restore. Intentionally empty for now.
    }
}
