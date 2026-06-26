import Foundation

// MARK: - NewTabPosition (otty `new-tab-position` policy)

/// Where a newly opened tab is inserted into the active session's tab bar — the faithful clone of otty's
/// `new-tab-position` config (`spec/user-interface__window-tab-split.md`, values `auto` / `end` /
/// `after-current`).
///
/// - ``auto``: context-aware. otty's default; with no surrounding window context to consult the closest
///   faithful behaviour is to **append** — which is also exactly what `WorkspaceTreeOps.newTab` did before
///   E3, so `.auto` is byte-identical to the old `tabs.append(...)`.
/// - ``end``: always append to the end of the tab list.
/// - ``afterCurrent``: insert immediately after the active tab (its raw value is otty's `after-current`).
///
/// A pure value type: the placement math lives in ``insertionIndex(activeTabIndex:tabCount:)`` so it is
/// unit-testable apart from the `WorkspaceTreeOps` op that consumes it. `String`-raw + `CaseIterable` so it
/// bridges to `Defaults` (see `SettingsKey`) and a future settings picker can enumerate it.
public enum NewTabPosition: String, Codable, Sendable, CaseIterable {
    case auto
    case end
    /// Raw value matches otty's `after-current` config string (so the persisted setting round-trips with
    /// the otty value a future Shell-settings row writes).
    case afterCurrent = "after-current"

    /// The index at which a new tab should be inserted into a tab list of `tabCount` tabs whose active tab
    /// sits at `activeTabIndex`. Pure integer index arithmetic.
    ///
    /// - ``auto`` / ``end`` → `tabCount` (the end index = an append, byte-identical to `tabs.append`).
    /// - ``afterCurrent`` → `activeTabIndex + 1`, with `activeTabIndex` clamped into `0..<tabCount` first so
    ///   a stale / out-of-range active index can never produce an invalid `Array.insert(at:)` index. An
    ///   empty list always yields `0`.
    ///
    /// The result is always a valid insertion index in `0...tabCount`.
    public func insertionIndex(activeTabIndex: Int, tabCount: Int) -> Int {
        let count = max(tabCount, 0)
        switch self {
        case .auto,
             .end:
            return count
        case .afterCurrent:
            guard count > 0 else { return 0 }
            let clampedActive = min(max(activeTabIndex, 0), count - 1)
            return min(clampedActive + 1, count)
        }
    }
}
