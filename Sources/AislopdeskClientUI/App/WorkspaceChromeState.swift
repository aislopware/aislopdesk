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
    /// E19/A30: whether the window is PINNED (otty View ▸ Pin Window — keep-on-top). Lives with the other
    /// chrome flags so reading it in the SwiftUI scene body re-invalidates the introspect-bearing scene; the
    /// macOS `NSWindow` glue (E19 WI-4) maps it to `NSWindow.level` (`.floating` ⇄ `.normal`). Pure view
    /// state — `false` resting (a fresh window is not pinned), no wire / persistence. iOS has no resizable
    /// floating window, so the flag is inert there (documented no-op, never a dead toggle).
    var pinned = false

    func toggleSidebar() { sidebarCollapsed.toggle() }
    func toggleInspector() { inspectorCollapsed.toggle() }
    /// Flip the window-pin flag (otty "Pin Window"). The macOS scene's `.onChange(of: chrome.pinned)` actuates
    /// `NSWindow.level`; on iOS this is an inert flag flip (no floating-window concept).
    func togglePin() { pinned.toggle() }
}
#endif
