import Foundation

/// CLIENT-chrome appearance prefs (WS-D, D2) — the otty theme + density tier the GUI client renders.
///
/// CRITICAL invariant (golden-safety): unlike ``VideoPreferences`` / ``AgentPreferences``, appearance is
/// PURE client chrome. It is NEVER routed through ``EnvBridge/toEnv(_:)``, never folded into
/// ``EnvConfig/overlay``, and never serialised into the `video-prefs.json` sidecar — so a default install
/// (all-`nil`) leaves the env overlay EMPTY and the golden corpus byte-identical. It persists ONLY to
/// `UserDefaults` (key `settings.appearance.v1`) and applies ONLY to ``ThemeStore`` / ``SettingsKey/density``.
///
/// Default = all-`nil` ⇒ NO behaviour change: the theme stays the compile-time default (`.paper`) and the
/// density key is left untouched.
public struct AppearancePreferences: Codable, Sendable, Equatable {
    /// The active otty theme. `nil` ⇒ unset ⇒ keep the compile-time default (Paper).
    public var theme: ThemeChoice?
    /// The density tier rawValue (mirrors ``SettingsKey/density``). `nil` ⇒ unset ⇒ leave the key untouched.
    public var density: String?

    public init(theme: ThemeChoice? = nil, density: String? = nil) {
        self.theme = theme
        self.density = density
    }
}

/// The user-selectable otty theme. `.system` follows the OS appearance (→ Monokai Pro Classic dark /
/// Monokai Pro Light); the Monokai Pro filters and the legacy `.paper` / `.dark` pin a fixed theme. A
/// `String`-raw `Codable` enum so a stale / unknown persisted value decode-fails the whole
/// ``AppearancePreferences`` blob to its all-`nil` default (validate-then-default, no migration). A `nil`
/// stored theme (fresh install / reset) resolves to the compile-time default Monokai Pro Classic.
public enum ThemeChoice: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    // Monokai Pro filters — palette from monokai.pro/contribute.
    case monokaiProClassic // dark, the DEFAULT
    case monokaiProClassicLight // light
    case monokaiProOctagon
    case monokaiProMachine
    case monokaiProRistretto
    case monokaiProSpectrum
    // Legacy otty palettes — still selectable.
    case paper
    case dark
}
