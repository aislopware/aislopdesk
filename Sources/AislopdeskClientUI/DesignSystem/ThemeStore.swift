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
//
// E15 WI-3 — DUAL-SLOT FOLLOW-OS: `apply(appearance:)` resolves the active `ThemeRef` for the CURRENT OS
// appearance (via the pure leaf `ThemeResolution`) and repoints `active`. A macOS OS-appearance observer
// re-resolves LIVE on a system light/dark switch, so a follow-OS (or legacy `.system`) user sees the theme
// flip without a restart. Custom (`.custom(slug)`) refs resolve through the injected `resolveCustomDocument`
// seam (WI-6 wires the `ThemeCatalog`); pre-catalog / a since-deleted slug falls back to the default theme.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import Foundation
import Observation
import SwiftUI

/// The single live owner of the active ``OttyTheme``. Read by ``Otty/theme`` (so every token resolves the
/// runtime theme) and repointed by the appearance apply path. Default `.monokaiProClassic` ⇒ byte-identical
/// headless.
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

    /// The appearance prefs last applied — re-resolved on an OS-appearance flip so a dual-slot / `.system`
    /// user follows the system colour scheme LIVE. `nil` until the first ``apply(appearance:)`` (the OS
    /// observer is then a no-op — there is nothing to re-resolve).
    @ObservationIgnored private var lastAppearance: AppearancePreferences?

    /// CUSTOM-theme resolution seam (E15 WI-6 wires the `ThemeCatalog` here). Maps a `.custom` slot's slug →
    /// its parsed ``ThemeDocument``; `nil` (the default, pre-catalog) ⇒ a `.custom` slot falls back to the
    /// built-in default theme — so a slot pointing at a since-deleted / not-yet-scanned theme is GRACEFUL, not
    /// a crash. Set ONCE at app launch after the themes-folder scan.
    @ObservationIgnored var resolveCustomDocument: ((String) -> ThemeDocument?)?

    /// OS-appearance probe (injectable for tests). Default reads `NSApp.effectiveAppearance` on macOS; a test
    /// supplies a stub to drive the dual-slot / live-switch logic with NO `NSApp`.
    @ObservationIgnored var osIsDark: () -> Bool = { ThemeStore.systemIsDark() }

    /// The live macOS OS-appearance observer token (`AppleInterfaceThemeChangedNotification`). Installed only
    /// on the singleton via ``observeOSAppearanceChanges()`` — never in a test instance, so no distributed
    /// observer leaks per test. Unconditional (NSObjectProtocol exists on every platform) to keep the
    /// `@Observable` body free of a `#if`-conditional stored property; iOS leaves it `nil`.
    @ObservationIgnored private var osObserverToken: NSObjectProtocol?

    init() {}

    // MARK: - Apply

    /// Apply the whole ``AppearancePreferences`` (E15 WI-3): resolve the active ``ThemeRef`` for the CURRENT OS
    /// appearance (dual-slot / custom-slug / follow-OS — ``ThemeResolution``) and repoint ``active``. Remembers
    /// the model so the OS observer can re-resolve live on a system light/dark switch.
    func apply(appearance: AppearancePreferences) {
        lastAppearance = appearance
        applyResolved(for: appearance)
    }

    /// Apply a bare ``ThemeChoice`` (the legacy single-slot selection). A thin convenience over
    /// ``apply(appearance:)`` — wraps the choice in a primary-slot-only ``AppearancePreferences`` so it routes
    /// through the SAME dual-slot resolution (`.system` still follows the OS, `nil` ⇒ the compile-time default
    /// Monokai Pro Classic).
    func apply(_ choice: ThemeChoice?) {
        apply(appearance: AppearancePreferences(theme: choice))
    }

    /// Re-resolve the active theme from the LAST-applied appearance under the (now-changed) OS appearance.
    /// Invoked by the macOS OS-appearance observer AND directly by tests (with a stubbed ``osIsDark``). A no-op
    /// before the first ``apply(appearance:)``. Posts ``didChangeNotification`` only on a real identity change,
    /// so a non-follow-OS user's flip is a silent no-op (the resolved theme doesn't depend on the OS).
    func reresolveForOSAppearance() {
        guard let lastAppearance else { return }
        applyResolved(for: lastAppearance)
    }

    /// Resolve `appearance` → a concrete ``OttyTheme`` for the current OS appearance and repoint ``active``.
    private func applyResolved(for appearance: AppearancePreferences) {
        let ref = ThemeResolution.activeRef(appearance: appearance, osIsDark: osIsDark())
        setActive(resolve(ref))
    }

    /// Resolve a ``ThemeRef`` → an ``OttyTheme``: a built-in by its stable id (unknown id ⇒ the default), a
    /// custom by its slug through the ``resolveCustomDocument`` seam (absent / unresolved ⇒ the default).
    private func resolve(_ ref: ThemeRef) -> OttyTheme {
        switch ref {
        case let .builtin(id):
            return Self.builtin(id: id) ?? .monokaiProClassic
        case let .custom(slug):
            if let doc = resolveCustomDocument?(slug) { return OttyTheme(document: doc) }
            return .monokaiProClassic
        }
    }

    /// Repoint ``active`` and post the cross-boundary repaint notification on a theme IDENTITY change (not just
    /// `isLight`) — so a SAME-lightness variant switch (e.g. Classic → Spectrum) still re-pins the AppKit
    /// columns, while an idempotent re-apply of the SAME theme posts nothing.
    private func setActive(_ resolved: OttyTheme) {
        let changed = resolved.id != active.id
        active = resolved
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    // MARK: - Built-in lookup

    /// The shipped ``OttyTheme`` for a stable built-in id (the inverse of ``ThemeChoice/builtinID`` /
    /// `OttyTheme.id`), or `nil` for an unknown id (the caller substitutes the default). MIRRORS the
    /// `ThemeChoice` → id mapping; the end-to-end `ThemeStoreTests` round-trip pins both halves.
    static func builtin(id: String) -> OttyTheme? {
        switch id {
        case "monokai-classic": .monokaiProClassic
        case "monokai-classic-light": .monokaiProClassicLight
        case "monokai-octagon": .monokaiProOctagon
        case "monokai-machine": .monokaiProMachine
        case "monokai-ristretto": .monokaiProRistretto
        case "monokai-spectrum": .monokaiProSpectrum
        case "paper": .paper
        case "dark": .dark
        default: nil
        }
    }

    // MARK: - OS appearance

    /// Whether the OS is currently in dark mode (macOS: `NSApp.effectiveAppearance`; other platforms: `false`).
    /// The default backing for ``osIsDark``; a test overrides the closure instead of touching `NSApp`.
    static func systemIsDark() -> Bool {
        #if os(macOS)
        return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        return false
        #endif
    }

    /// Resolve the OS appearance to an ``OttyTheme`` (Dark mode ⇒ Monokai Pro Classic, else Monokai Pro Light).
    /// Kept for the legacy `.system` built-in resolution path / any non-dual-slot caller.
    static func systemTheme() -> OttyTheme {
        systemIsDark() ? .monokaiProClassic : .monokaiProClassicLight
    }

    /// Install the live macOS OS-appearance observer (idempotent). On a system light/dark switch it
    /// re-resolves the active slot from the last-applied appearance, so a dual-slot / `.system` user follows
    /// the system colour scheme LIVE (the ``didChangeNotification`` then re-pins the AppKit columns). Called
    /// ONCE on ``shared`` at app launch; NOT in tests (they drive ``reresolveForOSAppearance()`` directly with
    /// a stubbed ``osIsDark``), so no distributed observer leaks per test instance. A no-op on iOS (no
    /// distributed interface-style notification — the iOS appearance flip is a view-trait concern).
    func observeOSAppearanceChanges() {
        #if os(macOS)
        guard osObserverToken == nil else { return }
        osObserverToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            // The distributed notification can arrive a hair BEFORE `NSApp.effectiveAppearance` flips; hop to
            // the next main-actor tick so the probe reads the SETTLED appearance, then re-resolve.
            Task { @MainActor in self?.reresolveForOSAppearance() }
        }
        #endif
    }
}
#endif
