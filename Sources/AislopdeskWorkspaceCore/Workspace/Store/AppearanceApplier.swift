import AislopdeskVideoProtocol
import Foundation

/// The seam by which the headless ``PreferencesStore`` (in `AislopdeskWorkspaceCore`) repoints the GUI
/// runtime theme without depending on `AislopdeskClientUI` (which owns `ThemeStore` — the SwiftUI/AppKit
/// layer that `WorkspaceCore` must not import). Mirrors the `TerminalRenderingView.shared` /
/// `VideoWindowFactory.shared` injected-closure pattern: `AislopdeskClientUI` registers a closure at app
/// launch that applies a ``ThemeChoice`` to its `ThemeStore.shared` + re-pins `NSWindow.appearance`.
///
/// Headless / no-store (the golden + ImageRenderer paths): the hook is `nil`, so applying appearance is a
/// no-op for the theme side — the density `UserDefaults` write still happens (it is pure `WorkspaceCore`
/// state), but no SwiftUI/AppKit token repoints, keeping headless renders byte-identical to today.
@preconcurrency
@MainActor
public enum AppearanceApplier {
    /// Registered by `AislopdeskClientUI` at app launch. Receives the selected ``ThemeChoice`` (or `nil`
    /// when appearance is reset to its default) so the GUI layer can repoint `ThemeStore.shared` + re-pin
    /// the window appearance. `nil` here ⇒ headless / pre-launch ⇒ the theme side is skipped.
    public static var apply: ((ThemeChoice?) -> Void)?

    /// Registered by `AislopdeskClientUI`: returns the libghostty `background`/`foreground` (6-hex, no `#`)
    /// of the CURRENTLY-active theme — read from `ThemeStore.shared.active`, which already resolves
    /// `.system` to a concrete light/dark palette. ``PreferencesStore`` consults this when rebuilding the
    /// terminal config so the terminal CELLS adopt the same flat background as the chrome (otty flat design).
    /// `nil` (headless / pre-launch) ⇒ the terminal keeps the ``TerminalPreferences`` colours, unchanged.
    public static var resolveTerminalColors: (() -> (background: String, foreground: String)?)?
}
