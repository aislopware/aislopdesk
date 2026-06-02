#if canImport(SwiftUI)
import SwiftUI

// MARK: - FocusedValues bridge (the scene's "active store")

/// Bridges the focused scene's ``WorkspaceStore`` up to the app-level ``WorkspaceCommands`` so the
/// native menu-bar / `UIKeyCommand` shortcuts act on the window the user is actually in (docs/22 §5).
///
/// SwiftUI `Commands` live at the *scene* level, not inside any view, so they cannot reach into a
/// `WindowGroup`'s view tree directly. The bridge is `FocusedValues`: the root view publishes its
/// store with `.focusedSceneValue(\.workspaceStore, store)`, and the command builders read it back
/// with `@FocusedValue(\.workspaceStore)`. With one window today this is a single value; the moment a
/// second `WindowGroup` window exists each publishes its own store and the menu bar automatically
/// targets the key window's — no extra wiring (docs/22 §5).
///
/// The value is the `@MainActor @Observable` store reference itself (a reference type), so reading it
/// in a `Button` action and calling `apply(_:to:)` mutates the live workspace with no copy. We use
/// `focusedSceneValue` (not `focusedValue`) so the store stays reachable for the whole key *scene*
/// even when first-responder focus is inside a terminal — the workspace shortcuts must work while a
/// pane has keyboard focus, which is the entire point of the ⌘/⌥-prefixed conflict rule (§5).

extension FocusedValues {
    /// Key for the focused scene's ``WorkspaceStore``.
    private struct WorkspaceStoreKey: FocusedValueKey {
        typealias Value = WorkspaceStore
    }

    /// The ``WorkspaceStore`` of the currently key scene, or `nil` when no workspace window is key
    /// (the command builders then disable their items). Published by ``WorkspaceRootView`` via
    /// `.focusedSceneValue(\.workspaceStore, store)`.
    var workspaceStore: WorkspaceStore? {
        get { self[WorkspaceStoreKey.self] }
        set { self[WorkspaceStoreKey.self] = newValue }
    }
}

// MARK: - Root-view convenience

public extension View {
    /// Publishes `store` as the focused scene's workspace store so the menu-bar ``WorkspaceCommands``
    /// (and the iPad hardware-keyboard HUD) route every ``WorkspaceCommand`` to it. Attach this once,
    /// on the workspace root in each window (docs/22 §5).
    func publishingWorkspaceStore(_ store: WorkspaceStore) -> some View {
        focusedSceneValue(\.workspaceStore, store)
    }
}
#endif
