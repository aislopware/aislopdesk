import Foundation

// MARK: - SessionRowModel (the pure session-switcher row derivation)

/// One row of the multi-session switcher (E19 A32) — a flat, presentational projection of a ``Session``:
/// its `id`, display `name`, whether it is the `active` (selected) session, and its `tabCount`. A pure
/// `Identifiable`/`Equatable`/`Sendable` value with **no SwiftUI import**, so the switcher's row derivation
/// is headless-testable (mirrors ``OrderedTabGroup`` / the rail-row models).
///
/// The switcher view (``SessionSwitcherView`` in `AislopdeskClientUI`) renders these and routes the live
/// actions back through the EXISTING store ops (`selectSession` / `renameSession` / `closeSession` /
/// `newSessionDefault`); this model carries none of that — it is just the derived display state.
public struct SessionRowModel: Identifiable, Equatable, Sendable {
    /// The session's stable identity (the `selectSession`/`renameSession`/`closeSession` argument).
    public let id: SessionID
    /// The session's display name (``Session/name``).
    public let name: String
    /// Whether this is the active (selected) session — exactly one row is active in a non-empty workspace.
    public let active: Bool
    /// How many tabs this session owns (``Session/tabs`` count).
    public let tabCount: Int

    public init(id: SessionID, name: String, active: Bool, tabCount: Int) {
        self.id = id
        self.name = name
        self.active = active
        self.tabCount = tabCount
    }

    /// Derive the switcher rows from `tree` — one row per ``TreeWorkspace/sessions`` entry, in sidebar
    /// order, with the **resolved** active session marked (``TreeWorkspace/activeSession`` resolves the
    /// `nil`/stale-id fallback to the first session, so the highlight matches what `selectSession` lands
    /// on). An empty workspace yields an empty list. Pure.
    public static func rows(for tree: TreeWorkspace) -> [Self] {
        let activeID = tree.activeSession?.id
        return tree.sessions.map { session in
            Self(
                id: session.id,
                name: session.name,
                active: session.id == activeID,
                tabCount: session.tabs.count,
            )
        }
    }
}
