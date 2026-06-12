#if canImport(SwiftUI)
import SwiftUI

// MARK: - Settings keys (one source of truth)

/// The `@AppStorage` keys the Settings scene owns, shared verbatim with the consumers (the canvas
/// snap toggles, the system-dialog gate, the notification posters). Centralised so a key can never
/// drift between where it is written (Settings) and where it is read.
public enum SettingsKey {
    // Canvas
    public static let snapPanes = "canvas.snapPanes"
    public static let snapGrid = "canvas.snapGrid"
    public static let showGrid = "canvas.showGrid"
    public static let defaultPaneKindKey = "canvas.defaultPaneKind"   // PaneKind.rawValue
    // Notifications
    public static let oscNotifications = "notifications.osc"
    public static let longCommandNotifications = "notifications.longCommand"
    // Features / advanced
    public static let systemDialogPanes = "features.systemDialogPanes"

    /// Whether explicit OSC 9/777 notifications should post (default ON). Read at fire-time.
    public static var oscNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: oscNotifications) as? Bool ?? true
    }
    /// Whether the long-command completion notification should post (default ON). Read at fire-time.
    public static var longCommandNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: longCommandNotifications) as? Bool ?? true
    }
    /// Whether the system-dialog monitor should auto-spawn dialog panes (default ON). The
    /// `AISLOPDESK_SYSTEM_DIALOG_PANES` env var still overrides for tests (`0` off / `force` on).
    public static var systemDialogPanesEnabled: Bool {
        UserDefaults.standard.object(forKey: systemDialogPanes) as? Bool ?? true
    }
    /// The default kind for a generic "New Pane" (toolbar primary action / empty state), default
    /// `.terminal`. Per-kind shortcuts (⇧⌘N / ⌥⌘N) are unaffected.
    public static var defaultPaneKind: PaneKind {
        (UserDefaults.standard.string(forKey: defaultPaneKindKey)).flatMap(PaneKind.init(rawValue:)) ?? .terminal
    }
}

// MARK: - SettingsView (the ⌘, scene)

/// The app Settings window (macOS ⌘,). Three tabs of `@AppStorage`-backed preferences that retire the
/// env-var gates into real, discoverable settings. macOS-first; the keys are shared with the consumers
/// via ``SettingsKey`` so the two surfaces cannot drift.
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            CanvasSettingsTab()
                .tabItem { Label("Canvas", systemImage: "rectangle.3.group") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 460, height: 280)
    }
}

private struct CanvasSettingsTab: View {
    @AppStorage(SettingsKey.snapPanes) private var snapPanes = true
    @AppStorage(SettingsKey.snapGrid) private var snapGrid = true
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.defaultPaneKindKey) private var defaultKind = PaneKind.terminal.rawValue

    var body: some View {
        Form {
            Section("Snapping") {
                Toggle("Snap to panes", isOn: $snapPanes)
                Toggle("Snap to grid", isOn: $snapGrid)
                Toggle("Show grid", isOn: $showGrid)
                Text("Hold ⌘ while dragging to bypass snapping for one move.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("New panes") {
                Picker("Default new pane", selection: $defaultKind) {
                    Text("Terminal").tag(PaneKind.terminal.rawValue)
                    Text("Claude Code").tag(PaneKind.claudeCode.rawValue)
                    Text("Remote Window").tag(PaneKind.remoteGUI.rawValue)
                }
                Text("Used by ⌘N and the toolbar + button. ⇧⌘N / ⌥⌘N always make Claude / Remote panes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(SettingsKey.oscNotifications) private var osc = true
    @AppStorage(SettingsKey.longCommandNotifications) private var longCommand = true

    var body: some View {
        Form {
            Section("Desktop notifications") {
                Toggle("Explicit notifications (OSC 9 / 777)", isOn: $osc)
                Text("A remote command can post a notification on demand, e.g. `printf '\\e]9;done\\e\\\\'`. Click it to jump to the pane.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Long-running command finished (~10s+)", isOn: $longCommand)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AdvancedSettingsTab: View {
    @AppStorage(SettingsKey.systemDialogPanes) private var systemDialogPanes = true

    var body: some View {
        Form {
            Section("System dialogs") {
                Toggle("Show system password dialogs in their own pane", isOn: $systemDialogPanes)
                Text("A SecurityAgent / sudo prompt on the host auto-spawns an ephemeral pane (and an attention beacon if it lands off-screen). Type into it with Paste as Keystrokes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
#endif
