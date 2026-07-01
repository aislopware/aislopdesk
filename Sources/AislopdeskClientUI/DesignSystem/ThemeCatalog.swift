// ThemeCatalog (E15 WI-6) — the single ClientUI-side theme directory: the shipped built-in `SlateTheme`s
// (keyed by their stable id) PLUS the scanned custom `.aislopdesktheme` documents, and the one resolver that turns
// a `ThemeRef` slot reference into a concrete `SlateTheme`.
//
// WHY a catalog distinct from `ThemeStore`: `ThemeStore` owns the ACTIVE theme + the cross-`NSHostingController`
// repaint seam; the catalog owns the AVAILABLE themes (the Theme picker lists `customThemes`, and the
// `ThemeStore` custom-resolution seam — `resolveCustomDocument` — points at `customDocument(slug:)` so a
// `.custom` slot resolves to its scanned document on the very first frame). Keeping the two apart lets the
// catalog be rebuilt (re-scanned on import) WITHOUT re-pointing the active theme, and lets a test drive the
// scan deterministically (the injected `scan` closure) with no filesystem.
//
// GOLDEN-SAFE: a scanned `ThemeDocument` is pure client chrome — nothing here reaches `EnvConfig` / the
// sidecar / the wire (the `AppearancePreferences` invariant). The macOS-only folder scan lives behind
// `ThemeLibrary` (`#if os(macOS)`); on iOS `customThemes` is simply empty (built-ins only).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import Foundation
import Observation

/// The available-themes directory: built-in `SlateTheme`s + scanned custom `ThemeDocument`s, and the
/// `ThemeRef` → `SlateTheme` resolver ClientUI uses. `@Observable` so the Settings Theme picker re-renders when
/// ``reloadCustom()`` re-scans (e.g. after an import).
@MainActor
@Observable
final class ThemeCatalog {
    /// The process-wide catalog. Wired into `ThemeStore.shared.resolveCustomDocument` at app launch and read
    /// by the Settings Theme picker.
    static let shared = ThemeCatalog()

    /// The scanned custom themes (slug-deduplicated, deterministic scan order). Empty until ``reloadCustom()``;
    /// always empty on iOS (no `~/.config` folder scan).
    private(set) var customThemes: [ThemeDocument] = []

    /// The themes-folder scan seam (injectable for tests). Default scans `~/.config/aislopdesk/themes/` on
    /// macOS, `[]` elsewhere — a test supplies a stub to drive ``reloadCustom()`` with NO filesystem. `@MainActor`
    /// because the catalog (and its only caller, ``reloadCustom()``) is main-actor isolated.
    @ObservationIgnored private let scan: @MainActor ([String: String]) -> [ThemeDocument]
    /// The environment passed to ``scan`` (so a test can point the default scan at a temp `$HOME`/`$XDG…`).
    @ObservationIgnored private let environment: [String: String]

    init(
        scan: @escaping @MainActor ([String: String]) -> [ThemeDocument] = ThemeCatalog.defaultScan,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        self.scan = scan
        self.environment = environment
    }

    // MARK: - Built-ins

    /// Every shipped built-in theme, in the Theme-picker order. Pure list (the picker reads it for labels /
    /// preview; resolution goes through ``builtin(id:)`` / ``ThemeStore/builtin(id:)``).
    static let builtinThemes: [SlateTheme] = [
        .monokaiProClassic,
        .monokaiProClassicLight,
        .monokaiProOctagon,
        .monokaiProMachine,
        .monokaiProRistretto,
        .monokaiProSpectrum,
        .paper,
        .dark,
    ]

    /// The shipped `SlateTheme` for a stable built-in id, or `nil` for an unknown id. Delegates to
    /// ``ThemeStore/builtin(id:)`` so there is ONE built-in id→theme table.
    func builtin(id: String) -> SlateTheme? { ThemeStore.builtin(id: id) }

    // MARK: - Customs

    /// The scanned ``ThemeDocument`` for a slug, or `nil` (since-deleted / not-yet-scanned). This is the seam
    /// `ThemeStore.resolveCustomDocument` points at, so a `.custom` slot resolves through the SAME table the
    /// picker lists from.
    func customDocument(slug: String) -> ThemeDocument? {
        customThemes.first { $0.slug == slug }
    }

    // MARK: - Resolve

    /// Resolve a ``ThemeRef`` slot reference → a concrete ``SlateTheme``: a built-in by id (unknown ⇒ the
    /// default Monokai Pro Classic), a custom by slug through ``customDocument(slug:)`` (absent ⇒ the default).
    /// Total + graceful — a stale slot never crashes, it falls back to the default theme.
    func resolve(_ ref: ThemeRef) -> SlateTheme {
        switch ref {
        case let .builtin(id):
            return ThemeStore.builtin(id: id) ?? .monokaiProClassic
        case let .custom(slug):
            if let document = customDocument(slug: slug) { return SlateTheme(document: document) }
            return .monokaiProClassic
        }
    }

    // MARK: - Reload

    /// Re-scan the custom-themes folder and repoint ``customThemes``. Called once at launch (before the first
    /// `PreferencesStore` apply) and again after an import so the new theme appears in the picker live.
    @discardableResult
    func reloadCustom() -> [ThemeDocument] {
        customThemes = scan(environment)
        return customThemes
    }

    /// The default scan: the macOS themes-folder scan, `[]` on iOS (no `~/.config`).
    static func defaultScan(_ environment: [String: String]) -> [ThemeDocument] {
        #if os(macOS)
        return ThemeLibrary.scan(environment: environment)
        #else
        return []
        #endif
    }
}
#endif
