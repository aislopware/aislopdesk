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
    // Shell / window behaviour
    /// Where a new tab is inserted in the active session's tab bar (otty `new-tab-position`). Stored as the
    /// ``NewTabPosition`` rawValue (`auto`/`end`/`after-current`); default `.auto` (= append). Read at the
    /// ⌘T fire-site (`WorkspaceStore.newTab`). Named with the `Key` suffix (like ``defaultPaneKindKey``) so
    /// the typed ``NewTabPosition`` accessor below can take the bare ``newTabPosition`` name.
    public static let newTabPositionKey = "shell.newTabPosition" // NewTabPosition.rawValue

    /// The working-directory policy for a NEW WINDOW (otty `working-directory`), default `home` — a fresh
    /// window opens at the shell's login cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string
    /// (`inherit` / `home` / an absolute path). Read at the new-window fire-site.
    public static let workingDirectoryNewWindowKey = "shell.workingDirectory.newWindow"
    /// The working-directory policy for a NEW TAB, default `inherit` — a ⌘T tab starts in the active pane's
    /// last-known cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string. Read at the ⌘T fire-site
    /// (`WorkspaceStore.newTab`).
    public static let workingDirectoryNewTabKey = "shell.workingDirectory.newTab"
    /// The working-directory policy for a NEW SPLIT, default `inherit` — a split starts in the active pane's
    /// last-known cwd. Stored as the ``WorkingDirectoryPolicy/rawConfig`` string. Read at the split fire-site
    /// (`WorkspaceStore.splitActivePane`).
    public static let workingDirectoryNewSplitKey = "shell.workingDirectory.newSplit"

    /// The close-confirmation policy for a TAB / PANE close (otty close-confirmation), default `process` —
    /// confirm only when a child process is running. Stored as the ``CloseConfirmationPolicy`` rawValue
    /// (`process` / `always` / `multiple_tabs`). Read at the tab/pane close fire-sites
    /// (`WorkspaceStore.requestClosePaneTree` / `requestCloseActivePaneTree` / `closeActiveTab`).
    public static let closeConfirmTabKey = "shell.closeConfirm.tab" // CloseConfirmationPolicy.rawValue
    /// The close-confirmation policy for a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default `process`. Stored as the ``CloseConfirmationPolicy`` rawValue. Read at
    /// the window-close fire-site (`WorkspaceStore.requestCloseWindow`).
    public static let closeConfirmWindowKey = "shell.closeConfirm.window" // CloseConfirmationPolicy.rawValue

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

    /// Where a new tab opens in the active session's tab bar (otty `new-tab-position`), default `.auto`
    /// (= append, byte-identical to the pre-E3 behaviour). A stale / invalid persisted raw value falls back
    /// to `.auto` via the `RawRepresentableBridge`. Read at the ⌘T fire-site.
    public static var newTabPosition: NewTabPosition { Defaults[.newTabPosition] }

    /// The working-directory policy applied when a NEW WINDOW opens (otty `working-directory`), default
    /// ``WorkingDirectoryPolicy/home``. Decoded from the persisted ``WorkingDirectoryPolicy/rawConfig``
    /// string (an empty / unknown value repairs to `.home`). Read at fire-time.
    public static var workingDirectoryNewWindow: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewWindow])
    }

    /// The working-directory policy applied when a NEW TAB opens, default ``WorkingDirectoryPolicy/inherit``
    /// (the ⌘T tab starts in the active pane's last-known cwd). Read at the ⌘T fire-site.
    public static var workingDirectoryNewTab: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewTab])
    }

    /// The working-directory policy applied when a NEW SPLIT opens, default
    /// ``WorkingDirectoryPolicy/inherit``. Read at the split fire-site.
    public static var workingDirectoryNewSplit: WorkingDirectoryPolicy {
        WorkingDirectoryPolicy(rawConfig: Defaults[.workingDirectoryNewSplit])
    }

    /// The close-confirmation policy applied to a TAB / PANE close (otty close-confirmation), default
    /// ``CloseConfirmationPolicy/process``. A stale / invalid persisted raw value repairs to `.process` (via
    /// ``CloseConfirmationPolicy/init(rawValue:)`` + the `RawRepresentableBridge`). Read at fire-time.
    public static var closeConfirmTab: CloseConfirmationPolicy { Defaults[.closeConfirmTab] }

    /// The close-confirmation policy applied to a WINDOW close (mapped to the active ``Session`` — see
    /// `docs/DECISIONS.md`), default ``CloseConfirmationPolicy/process``. Read at fire-time.
    public static var closeConfirmWindow: CloseConfirmationPolicy { Defaults[.closeConfirmWindow] }
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
    static let newTabPosition = Key<NewTabPosition>(SettingsKey.newTabPositionKey, default: .auto)
    // Working-directory policies stored as the `WorkingDirectoryPolicy.rawConfig` String (otty config value).
    // New window defaults to `home` (login cwd); new tab / split default to `inherit` (active pane's cwd).
    static let workingDirectoryNewWindow = Key<String>(SettingsKey.workingDirectoryNewWindowKey, default: "home")
    static let workingDirectoryNewTab = Key<String>(SettingsKey.workingDirectoryNewTabKey, default: "inherit")
    static let workingDirectoryNewSplit = Key<String>(SettingsKey.workingDirectoryNewSplitKey, default: "inherit")
    // Close-confirmation policies stored as the `CloseConfirmationPolicy` rawValue (otty config value). Both
    // default to `process` (confirm only on a running child process — the pre-E3 busy-shell guard).
    static let closeConfirmTab = Key<CloseConfirmationPolicy>(SettingsKey.closeConfirmTabKey, default: .process)
    static let closeConfirmWindow = Key<CloseConfirmationPolicy>(SettingsKey.closeConfirmWindowKey, default: .process)
}

/// Store ``PaneKind`` as its bare `String` rawValue (not JSON-wrapped) so the value stays wire-compatible
/// with the existing direct-string writes + the `defaultPaneKindKey` `@AppStorage`/`@Default` consumers;
/// `PreferRawRepresentable` selects `RawRepresentableBridge`, which also yields the key default for a
/// retired/invalid raw value (e.g. the W11 `"claudeCode"`).
extension PaneKind: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``NewTabPosition`` as its bare `String` rawValue (`auto`/`end`/`after-current`) so the persisted
/// `new-tab-position` setting round-trips with the otty config value; `PreferRawRepresentable` selects the
/// `RawRepresentableBridge`, which yields the key default (`.auto`) for a stale / invalid raw value.
extension NewTabPosition: Defaults.Serializable, Defaults.PreferRawRepresentable {}

/// Store ``CloseConfirmationPolicy`` as its bare `String` rawValue (`process`/`always`/`multiple_tabs`) so
/// the persisted close-confirmation setting round-trips with the otty config value; `PreferRawRepresentable`
/// selects the `RawRepresentableBridge`. A stale / invalid raw value repairs to `.process` via the policy's
/// own non-failable ``CloseConfirmationPolicy/init(rawValue:)`` (and the key default is also `.process`).
extension CloseConfirmationPolicy: Defaults.Serializable, Defaults.PreferRawRepresentable {}
