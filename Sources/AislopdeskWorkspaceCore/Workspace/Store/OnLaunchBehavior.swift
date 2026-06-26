import Foundation

// MARK: - OnLaunchBehavior (otty `On Launch` general setting — O1)

/// What the app does when it opens — the faithful clone of otty's **On Launch** setting
/// (`spec/getting-started__first-launch.md`, Settings → General). Two choices:
///
/// - ``restoreLastSession``: restore the persisted workspace tree (scrollback + the still-running
///   detached host sessions resume on reconnect — see `DetachedSessionStore`). This is the EXISTING
///   aislopdesk launch behaviour (the store already restores the persisted tree), so it is the default —
///   byte-identical to today. otty's recommended value.
/// - ``newWindow``: open a fresh empty window instead of restoring.
///
/// PURE: a `String`-raw + `CaseIterable` enum so it bridges to `Defaults` (see `SettingsKey`) and the
/// General-settings picker can enumerate it. ``init(rawValue:)`` is validate-then-repair (a stale /
/// hostile persisted string falls back to ``restoreLastSession`` rather than trapping) — the same
/// non-failable shape as ``CloseConfirmationPolicy/init(rawValue:)`` so the
/// `Defaults.PreferRawRepresentable` bridge keeps working.
public enum OnLaunchBehavior: String, Codable, Sendable, CaseIterable {
    /// Restore the persisted workspace tree on launch (the current default behaviour). Raw value
    /// `restore-last-session` matches otty's config string so the persisted setting round-trips.
    case restoreLastSession = "restore-last-session"
    /// Open a fresh empty window on launch. Raw value `new-window` matches otty's config string.
    case newWindow = "new-window"

    /// Decodes the stored otty `On Launch` config string. Validate-then-repair: a recognized raw value
    /// maps to its case; anything else (a stale / hostile persisted string) repairs to
    /// ``restoreLastSession`` rather than trapping. Non-failable so it satisfies `RawRepresentable`
    /// without ever returning `nil` (the `Defaults.PreferRawRepresentable` bridge relies on this).
    public init(rawValue: String) {
        switch rawValue {
        case "restore-last-session": self = .restoreLastSession
        case "new-window": self = .newWindow
        default: self = .restoreLastSession
        }
    }
}
