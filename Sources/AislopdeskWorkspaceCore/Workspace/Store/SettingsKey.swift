import Defaults
import Foundation

// L0: extracted from the deleted SwiftUI `SettingsScene.swift`. `SettingsKey` is the pure
// `UserDefaults`-key namespace + the fire-time boolean/`PaneKind` accessors that the headless logic
// (CommandCompletionNotifier, AppLaunchMonitor, WorkspaceStore+Completion, the monitors) reads. The
// new Settings UI binds the SAME keys via `@Default(.key)` (the typed `Defaults.Keys` below).
//
// G2 / Defaults: the fire-time accessors now read sindresorhus/Defaults typed keys — the per-key default
// lives ONCE in the `Defaults.Keys` declaration instead of being repeated in each `?? true`. The wire
// STRING constants stay (the `Defaults.Key` names reuse them, so there is one source of truth that
// `SettingsKeyTests` pins and the `@Default`/`@AppStorage` consumers share). No SwiftUI import — headless.
public enum SettingsKey {
    // Canvas
    public static let snapPanes = "canvas.snapPanes"
    public static let snapGrid = "canvas.snapGrid"
    public static let showGrid = "canvas.showGrid"
    public static let nonOverlap = "canvas.nonOverlap"
    public static let defaultPaneKindKey = "canvas.defaultPaneKind" // PaneKind.rawValue
    // Notifications
    public static let oscNotifications = "notifications.osc"
    public static let longCommandNotifications = "notifications.longCommand"
    // Features / advanced
    public static let systemDialogPanes = "features.systemDialogPanes"
    public static let autoSwitchLayouts = "features.autoSwitchLayouts"
    public static let redactSecrets = "features.redactSecrets"
    public static let recordClipboardHistory = "features.recordClipboardHistory"
    // Appearance / chrome
    /// The active ``DSDensity`` tier rawValue. Mirrors ``DSDensity/storageKey`` (the SAME `UserDefaults`
    /// key ``DSThemeStore`` reads at init + on a Settings change) so the picker, persistence, and the live
    /// `DSScale`/height tokens all agree on one source.
    public static let density = "appearance.density"
    /// Whether the bottom ``PaneStatusBar`` is hidden (the chrome recedes toward pure terminal). Default OFF.
    public static let hideStatusBar = "appearance.hideStatusBar"
    /// Whether the per-block sticky command divider/header is shown over terminal panes. Default ON.
    public static let showBlockDividers = "terminal.showBlockDividers"

    /// Whether a layout with a trigger app auto-switches when that app launches on the host (default
    /// ON — assigning a trigger is itself the opt-in). Read at fire-time.
    public static var autoSwitchLayoutsEnabled: Bool { Defaults[.autoSwitchLayouts] }

    /// Whether explicit OSC 9/777 notifications should post (default ON). Read at fire-time.
    public static var oscNotificationsEnabled: Bool { Defaults[.oscNotifications] }

    /// Whether the long-command completion notification should post (default ON). Read at fire-time.
    public static var longCommandNotificationsEnabled: Bool { Defaults[.longCommandNotifications] }

    /// Whether the system-dialog monitor should auto-spawn dialog panes (default ON). The
    /// `AISLOPDESK_SYSTEM_DIALOG_PANES` env var still overrides for tests (`0` off / `force` on).
    public static var systemDialogPanesEnabled: Bool { Defaults[.systemDialogPanes] }

    /// Whether to mask likely secrets (access keys, bearer tokens, `PASSWORD=…`) out of window titles and
    /// notification bodies before they reach the sidebar/pill/Notification Center (default ON — security
    /// by default; the escape hatch is for someone who genuinely wants raw titles). Read at fire-time.
    public static var redactSecretsEnabled: Bool { Defaults[.redactSecrets] }

    /// Whether copied text is archived into the clipboard-history ring that backs the pill's "Paste
    /// Recent" submenu (default ON). Turn it OFF to stop the monitor from retaining any copied string —
    /// the privacy escape hatch for someone who copies secrets to paste into sudo/SSH prompts. Read at
    /// fire-time so a settings change applies live; existing entries are cleared from the pill's "Clear
    /// History".
    public static var recordClipboardHistoryEnabled: Bool { Defaults[.recordClipboardHistory] }

    /// Whether the bottom status bar is hidden (default OFF — the strip shows unless the user hides it).
    /// Read at fire-time so a Settings change applies on the next render.
    public static var hideStatusBarEnabled: Bool { Defaults[.hideStatusBar] }

    /// Whether the per-block command divider/header is shown (default ON). Read at fire-time.
    public static var showBlockDividersEnabled: Bool { Defaults[.showBlockDividers] }

    /// The default kind for a generic "New Pane" (toolbar primary action / empty state), default
    /// `.terminal`. The ⌥⌘N per-kind shortcut is unaffected. A stale persisted `"claudeCode"` value (the
    /// kind retired in W11) is not a valid raw value here → falls back to `.terminal`, exactly right
    /// (the `RawRepresentableBridge` returns the key default when the stored raw value no longer maps).
    public static var defaultPaneKind: PaneKind { Defaults[.defaultPaneKind] }
}

// MARK: - Typed Defaults keys (the single source the accessors + `@Default(.key)` views read)

/// The typed ``Defaults`` keys for the global app-flag namespace. Names reuse the ``SettingsKey`` string
/// constants so the wire strings stay the one source of truth (pinned by `SettingsKeyTests`, shared with
/// every `@Default`/`@AppStorage` consumer). All `.standard`-backed — the per-instance-injectable
/// ``PreferencesStore`` deliberately stays on its own `UserDefaults` (test isolation), not these.
public extension Defaults.Keys {
    static let oscNotifications = Key<Bool>(SettingsKey.oscNotifications, default: true)
    static let longCommandNotifications = Key<Bool>(SettingsKey.longCommandNotifications, default: true)
    static let systemDialogPanes = Key<Bool>(SettingsKey.systemDialogPanes, default: true)
    static let autoSwitchLayouts = Key<Bool>(SettingsKey.autoSwitchLayouts, default: true)
    static let redactSecrets = Key<Bool>(SettingsKey.redactSecrets, default: true)
    static let recordClipboardHistory = Key<Bool>(SettingsKey.recordClipboardHistory, default: true)
    static let hideStatusBar = Key<Bool>(SettingsKey.hideStatusBar, default: false)
    static let showBlockDividers = Key<Bool>(SettingsKey.showBlockDividers, default: true)
    static let defaultPaneKind = Key<PaneKind>(SettingsKey.defaultPaneKindKey, default: .terminal)
}

/// Store ``PaneKind`` as its bare `String` rawValue (not JSON-wrapped) so the value stays wire-compatible
/// with the existing direct-string writes + the `defaultPaneKindKey` `@AppStorage`/`@Default` consumers;
/// `PreferRawRepresentable` selects `RawRepresentableBridge`, which also yields the key default for a
/// retired/invalid raw value (e.g. the W11 `"claudeCode"`).
extension PaneKind: Defaults.Serializable, Defaults.PreferRawRepresentable {}
