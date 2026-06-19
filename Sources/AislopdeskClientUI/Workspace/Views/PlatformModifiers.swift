#if canImport(SwiftUI)
import SwiftUI

// MARK: - Cross-platform view modifiers (the macOS-only SwiftUI affordances, no-op on iOS)

/// The handful of macOS-only SwiftUI modifiers the IDE-shell views reach for, wrapped so the shared view
/// tree (sidebar / tabs / split content) compiles on iOS too. Each is the real AppKit affordance on macOS
/// and a sensible no-op on iOS, where touch supplies the equivalent gesture (tap-away to cancel; no cursor
/// to restyle). Keeping these in ONE place means a new macOS-only modifier the shell needs has a single,
/// obvious home — and the `#if os(macOS)` lives here, not scattered through the views.
extension View {
    /// Run `action` when the user presses ⎋ while this view (or a descendant) has focus.
    ///
    /// macOS: `onExitCommand(perform:)` — the standard "escape cancels" hook (e.g. dismiss an inline rename
    /// field). iOS: a no-op — there is no hardware ⎋ on the touch path and tapping away already cancels an
    /// inline edit, so the escape affordance is simply not needed.
    func onEscapeKey(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        return onExitCommand(perform: action)
        #else
        return self
        #endif
    }
}
#endif
