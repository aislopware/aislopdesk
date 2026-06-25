// ThemeStore — the runtime theme holder that defeats the STATIC `Otty.theme` across the AppKit
// `NSSplitViewController` boundary (REBUILD-V2, WS-D / D3).
//
// WHY a store and not a SwiftUI Environment value: the three columns are hosted in `NSHostingController`s
// inside `AislopdeskSplitViewController`, so a `.preferredColorScheme` / `@Environment` set on
// `WorkspaceRootView` does NOT cross into them (OttyDesign documents this; DECISIONS records the
// half-repaint bug). The `Otty.*` colour accessors therefore read this @Observable store instead of a
// compile-time `static let theme`. On a theme change the GUI must (a) repoint `active` here so SwiftUI
// re-reads the tokens, AND (b) re-inject each `NSHostingController` + re-pin `NSWindow.appearance`
// (handled in `AislopdeskSplitViewController`) — otherwise the window half-repaints.
//
// DEFAULT `.monokaiProClassic`: a headless / no-store render resolves `Otty.theme` to the Monokai Pro
// Classic palette. The golden corpus is unaffected — chrome colour never crosses into the wire vectors
// (appearance is pure client chrome, never folded into `EnvConfig`/the sidecar).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import Foundation
import Observation
import SwiftUI

/// The single live owner of the active ``OttyTheme``. Read by ``Otty/theme`` (so every token resolves the
/// runtime theme) and repointed by the appearance apply path. Default `.paper` ⇒ byte-identical headless.
@MainActor
@Observable
final class ThemeStore {
    /// The process-wide active store. `Otty.theme` reads `ThemeStore.shared.active`.
    static let shared = ThemeStore()

    /// Posted AFTER ``active`` changes so the AppKit shell (``AislopdeskSplitViewController``) can re-pin
    /// `NSWindow.appearance` + nudge the hosted columns — the cross-`NSHostingController` repaint SwiftUI's
    /// `@Observable` observation does not reach (D3).
    static let didChangeNotification = Notification.Name("AislopdeskThemeStoreDidChange")

    /// The active theme. Default Monokai Pro Classic (dark) — the product default; a no-store / headless
    /// render resolves the same Classic palette.
    var active: OttyTheme = .monokaiProClassic

    init() {}

    /// Apply a ``ThemeChoice`` (the persisted client-chrome selection) to ``active``. `.system` follows the
    /// OS appearance; `nil` (appearance reset / unset) falls back to the compile-time default Monokai Pro
    /// Classic.
    func apply(_ choice: ThemeChoice?) {
        let resolved: OttyTheme =
            switch choice {
            case .monokaiProClassic: .monokaiProClassic
            case .monokaiProClassicLight: .monokaiProClassicLight
            case .monokaiProOctagon: .monokaiProOctagon
            case .monokaiProMachine: .monokaiProMachine
            case .monokaiProRistretto: .monokaiProRistretto
            case .monokaiProSpectrum: .monokaiProSpectrum
            case .paper: .paper
            case .dark: .dark
            case .system: Self.systemTheme()
            case nil: .monokaiProClassic
            }
        // Compare on the theme IDENTITY (not just `isLight`) so a SAME-lightness variant switch (e.g. Classic
        // → Spectrum) still posts the cross-boundary repaint — the AppKit columns won't re-pin / nudge
        // otherwise. An idempotent re-apply of the SAME theme still posts nothing.
        let changed = resolved.id != active.id
        active = resolved
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Resolve the OS appearance to an ``OttyTheme`` (Dark mode ⇒ Monokai Pro Classic, else Monokai Pro Light).
    static func systemTheme() -> OttyTheme {
        #if os(macOS)
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .monokaiProClassic : .monokaiProClassicLight
        #else
        return .monokaiProClassic
        #endif
    }
}
#endif
