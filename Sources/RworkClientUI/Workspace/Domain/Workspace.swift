import Foundation

// MARK: - Workspace (the whole tree of intent)

/// The entire **tree of intent** (docs/22 §1.1): a versioned list of ``Tab``s plus which one is
/// active. This pure value type *is* the persistence format (docs/22 §6) — `Codable`,
/// round-trippable, holding no live object. The later `WorkspaceStore` owns one of these as its
/// single source of truth and reconciles the liveness registry against it after every mutation.
///
/// All tab-level arithmetic lives here as **pure functions returning a new `Workspace`**
/// (`adding`, `closing`, `moving`, `selecting`, `renaming`). The store calls these and then
/// reconciles — the store contributes the side effects, this type contributes the deterministic,
/// unit-testable shape math (docs/22 §8 `WorkspaceTests`).
public struct Workspace: Codable, Sendable, Equatable {
    /// The current schema version for forward migration (docs/22 §6). Bumped when the persisted
    /// shape changes; a decode of an unknown/old version falls back to the default workspace
    /// rather than crashing.
    public var schemaVersion: Int
    public var tabs: [Tab]
    /// The active tab, or `nil` when there are no tabs. Kept valid by the ops below (closing the
    /// active tab reselects a neighbour).
    public var activeTabID: TabID?

    public init(schemaVersion: Int = Workspace.currentSchemaVersion, tabs: [Tab], activeTabID: TabID?) {
        self.schemaVersion = schemaVersion
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

// MARK: - Schema + default

public extension Workspace {
    /// The schema version this build writes (the pan-only infinite ``Canvas`` shape). A
    /// higher/unrecognized version — or any older, incompatible on-disk shape that no longer decodes —
    /// falls back to ``defaultWorkspace()`` (the app has no released persisted format to migrate from,
    /// so there is deliberately no backward-compatibility path; docs/30 §4).
    static let currentSchemaVersion = 2

    /// The fresh-launch / decode-failure fallback: a single tab with one terminal pane, active.
    static func defaultWorkspace() -> Workspace {
        let tab = Tab.make(kind: .terminal, title: "Terminal")
        return Workspace(tabs: [tab], activeTabID: tab.id)
    }
}

// MARK: - Lookups

public extension Workspace {
    /// The active tab, or `nil`. A computed convenience over `activeTabID`.
    var activeTab: Tab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The index of the tab with `id`, or `nil`.
    func index(of id: TabID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    /// Repairs the `activeTabID` invariant: if it is nil or points at a tab that no longer exists,
    /// repoint it at the first tab (or `nil` when there are none). Applied on persistence load so a
    /// dangling active-tab id in ANY schema version restores with a selected tab, not a blank detail
    /// pane — `activeTab` returns nil for a dangling id, leaving the detail empty (R13). Identity for a
    /// valid id and for the empty-tabs case.
    func normalizingActiveTab() -> Workspace {
        let valid = activeTabID.map { id in tabs.contains { $0.id == id } } ?? false
        guard !valid else { return self }
        var copy = self
        copy.activeTabID = tabs.first?.id
        return copy
    }

    /// Repairs each tab's `focusedPane` invariant: if it points at a leaf that no longer exists in that
    /// tab's tree (a corrupt / hand-edited persisted file), repoint it at the tab's first leaf so keyboard
    /// focus is never pinned to a ghost pane. Applied on load alongside ``normalizingActiveTab()`` —
    /// completing the same corrupt-file repair (R13): the active tab AND the focus inside every tab.
    func normalizingTabFocus() -> Workspace {
        var copy = self
        for i in copy.tabs.indices {
            let ids = copy.tabs[i].canvas.allIDs()
            if !ids.contains(copy.tabs[i].focusedPane), let first = ids.first {
                copy.tabs[i].focusedPane = first
            }
            // Symmetric repair for the parallel presentation pointer: a dangling `maximizedPane` (a
            // re-minted / hand-edited id no longer in this tab's canvas) is cleared so a restored tab
            // never carries a stale maximize that points at a ghost pane.
            if let maximized = copy.tabs[i].maximizedPane, !ids.contains(maximized) {
                copy.tabs[i].maximizedPane = nil
            }
        }
        return copy
    }
}

// MARK: - Pure tab arithmetic (each returns a NEW workspace)

public extension Workspace {
    /// Appends a fresh single-leaf tab of `kind` and makes it active, returning the new
    /// workspace. The new tab's `TabID` is minted here.
    ///
    /// - Parameter endpoint: pre-fill the leaf's endpoint (connect-once inheritance). `nil` (the
    ///   default) leaves the pane in the unconfigured state so existing callers are unaffected.
    func adding(kind: PaneKind, title: String, endpoint: Endpoint? = nil) -> Workspace {
        var copy = self
        let tab = Tab.make(kind: kind, title: title, endpoint: endpoint)
        copy.tabs.append(tab)
        copy.activeTabID = tab.id
        return copy
    }

    /// Inserts an already-built `tab` (e.g. one restored or constructed elsewhere) and makes it
    /// active, returning the new workspace.
    func adding(_ tab: Tab) -> Workspace {
        var copy = self
        copy.tabs.append(tab)
        copy.activeTabID = tab.id
        return copy
    }

    /// Closes the tab `id`, returning the new workspace. If the closed tab was active, the
    /// **neighbour** becomes active (the tab that took its slot, else the new last tab, else
    /// `nil` when the workspace empties). A no-op if `id` is absent.
    func closing(_ id: TabID) -> Workspace {
        guard let removeIndex = index(of: id) else { return self }
        var copy = self
        copy.tabs.remove(at: removeIndex)

        if activeTabID == id {
            if copy.tabs.isEmpty {
                copy.activeTabID = nil
            } else {
                // Prefer the tab that slid into the removed slot; clamp to the last tab.
                let neighbour = min(removeIndex, copy.tabs.count - 1)
                copy.activeTabID = copy.tabs[neighbour].id
            }
        }
        return copy
    }

    /// Makes the tab `id` active (no-op if absent), returning the new workspace.
    func selecting(_ id: TabID) -> Workspace {
        guard index(of: id) != nil else { return self }
        var copy = self
        copy.activeTabID = id
        return copy
    }

    /// Selects the tab at the given **1-based menu position** (⌘1…⌘9 semantics, docs/22 §5),
    /// returning the new workspace. Out-of-range positions are a no-op. Position `9` is special:
    /// when there are more than nine tabs it selects the *last* tab (the macOS tab convention).
    func selecting(position: Int) -> Workspace {
        guard position >= 1, !tabs.isEmpty else { return self }
        let zeroBased: Int
        if position == 9 {
            zeroBased = tabs.count - 1 // ⌘9 = last tab
        } else {
            zeroBased = position - 1
        }
        guard tabs.indices.contains(zeroBased) else { return self }
        return selecting(tabs[zeroBased].id)
    }

    /// Activates the next / previous tab with wrap (⌃⇥ / ⌃⇧⇥), returning the new workspace.
    /// A no-op when there are fewer than two tabs or no active tab.
    func selectingAdjacent(forward: Bool) -> Workspace {
        guard tabs.count > 1, let current = activeTabID, let currentIndex = index(of: current) else { return self }
        let count = tabs.count
        let nextIndex = forward
            ? (currentIndex + 1) % count
            : (currentIndex - 1 + count) % count
        return selecting(tabs[nextIndex].id)
    }

    /// Moves tabs from `source` index set to `destination`, returning the new workspace. Matches
    /// SwiftUI `onMove` / `moveTab(from:to:)` semantics so the sidebar reorder binds directly. The
    /// active tab is preserved by identity (its `TabID` is unchanged by a reorder).
    func moving(from source: IndexSet, to destination: Int) -> Workspace {
        var copy = self
        copy.tabs.move(fromOffsets: source, toOffset: destination)
        return copy
    }

    /// Renames the tab `id` to `name`, returning the new workspace (no-op if absent).
    func renaming(_ id: TabID, to name: String) -> Workspace {
        guard let i = index(of: id) else { return self }
        var copy = self
        copy.tabs[i].name = name
        return copy
    }
}

// MARK: - Active-tab delegations (pure tree edits routed to the active tab)

public extension Workspace {
    /// Applies a pure mutation to a specific tab's `root`/focus/zoom in place, returning the new
    /// workspace. The single funnel the leaf-level ops below route through.
    func updatingTab(_ id: TabID, _ transform: (inout Tab) -> Void) -> Workspace {
        guard let i = index(of: id) else { return self }
        var copy = self
        transform(&copy.tabs[i])
        return copy
    }

    /// Convenience: apply a transform to the *active* tab.
    func updatingActiveTab(_ transform: (inout Tab) -> Void) -> Workspace {
        guard let id = activeTabID else { return self }
        return updatingTab(id, transform)
    }
}
