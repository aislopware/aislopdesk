// WorkspaceChromeState — the small @Observable chrome model the toolbar toggles drive (REBUILD-V2, L4a).
//
// Owns the two split-collapse flags the unified-toolbar sidebar/inspector buttons flip. The macOS
// `WorkspaceSplitRepresentable.updateNSViewController` reads these each update and animates the matching
// `NSSplitViewItem.isCollapsed`. Kept separate from `WorkspaceStore` (whose legacy `sidebarCollapsed`
// predates the native rebuild and isn't read by the new navigator) so the two collapse flags live in one
// place and reading them in the SwiftUI body re-invalidates the representable.
//
// `inspectorCollapsed` defaults `true` — otty hides the Details/inspector panel until ⌘⇧R, so the resting
// window is the two-column (sidebar | content) silhouette. The toolbar toggle reveals it.

#if canImport(SwiftUI)
import Foundation

@MainActor
@Observable
final class WorkspaceChromeState {
    /// Whether the left navigator (sidebar) split item is collapsed.
    var sidebarCollapsed = false
    /// Whether the right inspector split item is collapsed. `true` ⇒ HIDDEN by default (otty parity).
    var inspectorCollapsed = true

    func toggleSidebar() { sidebarCollapsed.toggle() }
    func toggleInspector() { inspectorCollapsed.toggle() }
}
#endif
