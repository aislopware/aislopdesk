// AllSettingsListView — the Advanced → "All Settings" searchable list (E7 WI-3).
//
// A searchable, scrollable list of every client-side config key (driven by the headless
// `AllSettingsCatalog`), rendered into the Advanced `Form` as a `Group` of `Section`s. Faithful to otty's
// `customization__advanced-settings.md` + `all-settings.png`:
//   • header "ALL SETTINGS" (uppercase, tertiary) with a trailing search field,
//   • a "Reset All Settings" / "Reset Advanced Only" button row, each behind a confirmation alert,
//   • rows: monospace key + gray description ("· Default: …"), then EITHER an inline control
//     (`.advancedOnly`, bound to its `Defaults.Key`) OR a value + ✎ jump-to-tab button (`.hasDedicatedTab`).
//
// The catalog is the single source of WHAT to show; this view owns the `Defaults.Key` bindings + the
// cross-tab jump (it sets the shared `selectedSection`). Cross-tab HIGHLIGHT of the target control is
// deferred (the jump alone is the E7 deliverable). Otty.* tokens only (no raw font/radius literals).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import Defaults
import SwiftUI

/// The Advanced → All Settings panel. Returns a `Group` of `Section`s so it composes into the host
/// `AdvancedSettingsTab` `Form`. `selectedSection` is the shared `TabView` selection a ✎ jump repoints.
struct AllSettingsListView: View {
    @Bindable var store: PreferencesStore
    /// The shared `TabView` selection — a ✎ jump on a `.hasDedicatedTab` row sets this to that tab.
    @Binding var selectedSection: SettingsSection
    /// Called after either reset so the host can clear UI buffers it owns (e.g. the raw-overrides text box).
    var onAfterReset: () -> Void = {}

    @State private var query = ""
    @State private var confirmResetAll = false
    @State private var confirmResetAdvanced = false

    // The advanced-only rows bind directly to the global `Defaults.Keys` (the same channel the per-section
    // tabs use), so an inline edit applies live exactly like hand-editing the config.
    @Default(.onLaunch) private var onLaunch
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.redactSecrets) private var redactSecrets
    @Default(.defaultPaneKind) private var defaultPaneKind
    @Default(.workingDirectoryNewWindow) private var workingDirNewWindow
    @Default(.workingDirectoryNewTab) private var workingDirNewTab
    @Default(.workingDirectoryNewSplit) private var workingDirNewSplit
    @Default(.newTabPosition) private var newTabPosition
    @Default(.closeConfirmTab) private var closeConfirmTab
    @Default(.closeConfirmWindow) private var closeConfirmWindow
    @Default(.copyOnSelect) private var copyOnSelect
    @Default(.trimTrailingSpacesOnCopy) private var trimTrailingSpacesOnCopy
    @Default(.pasteProtection) private var pasteProtection
    @Default(.mouseHideWhileTyping) private var mouseHideWhileTyping
    @Default(.focusFollowsMouse) private var focusFollowsMouse
    @Default(.scrollOnOutput) private var scrollOnOutput
    @Default(.scrollMultiplier) private var scrollMultiplier
    @Default(.systemDialogPanes) private var systemDialogPanes
    @Default(.showBlockDividers) private var showBlockDividers
    @Default(.hideStatusBar) private var hideStatusBar
    @Default(.autoSwitchLayouts) private var autoSwitchLayouts
    @Default(.recordClipboardHistory) private var recordClipboardHistory

    private var filtered: [AllSettingsCatalog.SettingEntry] { AllSettingsCatalog.filter(query) }

    var body: some View {
        Group {
            Section {
                HStack(spacing: Otty.Metric.space2) {
                    Button("Reset All Settings") { confirmResetAll = true }
                    Button("Reset Advanced Only") { confirmResetAdvanced = true }
                    Spacer()
                }
                .buttonStyle(.bordered)

                if filtered.isEmpty {
                    Text("No settings match “\(query)”.")
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.tertiary)
                } else {
                    ForEach(filtered) { entry in row(for: entry) }
                }
            } header: {
                HStack {
                    Text("ALL SETTINGS")
                        .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(Otty.Text.tertiary)
                    Spacer()
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }
            }
        }
        .alert("Reset All Settings?", isPresented: $confirmResetAll) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All", role: .destructive) {
                store.resetAll()
                onAfterReset()
            }
        } message: {
            Text("This restores every setting to its default — font, theme, keybindings, and all expert "
                + "keys. This cannot be undone.")
        }
        .alert("Reset Advanced Settings?", isPresented: $confirmResetAdvanced) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Advanced", role: .destructive) {
                store.resetAdvancedOnly()
                onAfterReset()
            }
        } message: {
            Text("This restores the advanced keys (video, agent, and raw overrides) to their defaults, "
                + "leaving your font, theme, and keybinding choices intact. This cannot be undone.")
        }
    }

    // MARK: - Row

    private func row(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.key)
                    .font(.system(size: Otty.Typeface.body, design: .monospaced))
                    .foregroundStyle(Otty.Text.primary)
                Spacer(minLength: Otty.Metric.space2)
                control(for: entry)
            }
            Text("\(entry.description) · Default: \(entry.defaultText)")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Otty.Metric.space1)
    }

    /// The trailing control: an inline editor for an `.advancedOnly` key, or a value + ✎ jump button for a
    /// `.hasDedicatedTab` key.
    @ViewBuilder
    private func control(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        switch entry.bucket {
        case .advancedOnly: inlineControl(for: entry)
        case .hasDedicatedTab: jumpButton(for: entry)
        }
    }

    /// A button showing the current value + ✎ that repoints `selectedSection` to the owning tab.
    private func jumpButton(for entry: AllSettingsCatalog.SettingEntry) -> some View {
        Button {
            if let raw = entry.targetSection, let section = SettingsSection(rawValue: raw) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: Otty.Metric.space1) {
                Text(dedicatedValue(for: entry))
                    .foregroundStyle(Otty.Text.secondary)
                Image(systemName: "pencil")
                    .foregroundStyle(Otty.Text.icon)
            }
            .font(.system(size: Otty.Typeface.footnote))
        }
        .buttonStyle(.borderless)
    }

    /// The current value of a `.hasDedicatedTab` render-pref, read live from the store.
    private func dedicatedValue(for entry: AllSettingsCatalog.SettingEntry) -> String {
        switch entry.key {
        case "font-family": store.terminal.fontFamily
        case "font-size": "\(Int(store.terminal.fontSize))"
        case "scrollback-limit": "\(store.terminal.scrollbackLines)"
        case "cursor-style": store.terminal.cursorStyle.rawValue.capitalized
        case "cursor-style-blink": store.terminal.cursorBlink ? "On" : "Off"
        case "theme": themeLabel(store.appearance.theme ?? .system)
        case SettingsKey.density: (store.appearance.density ?? "comfortable").capitalized
        default: entry.defaultText
        }
    }

    // MARK: - Inline advanced-only controls (bound to the `Defaults.Keys`)

    /// The inline editor for an `.advancedOnly` key. Returns `AnyView` so the large key switch erases to one
    /// type (keeps the SwiftUI `ViewBuilder` type-checker cheap).
    private func inlineControl(for entry: AllSettingsCatalog.SettingEntry) -> AnyView {
        switch entry.key {
        case SettingsKey.oscNotifications: boolControl($oscNotifications)
        case SettingsKey.longCommandNotifications: boolControl($longCommandNotifications)
        case SettingsKey.redactSecrets: boolControl($redactSecrets)
        case SettingsKey.copyOnSelect: boolControl($copyOnSelect)
        case SettingsKey.trimTrailingSpacesOnCopy: boolControl($trimTrailingSpacesOnCopy)
        case SettingsKey.pasteProtection: boolControl($pasteProtection)
        case SettingsKey.mouseHideWhileTyping: boolControl($mouseHideWhileTyping)
        case SettingsKey.focusFollowsMouse: boolControl($focusFollowsMouse)
        case SettingsKey.scrollOnOutput: boolControl($scrollOnOutput)
        case SettingsKey.systemDialogPanes: boolControl($systemDialogPanes)
        case SettingsKey.showBlockDividers: boolControl($showBlockDividers)
        case SettingsKey.hideStatusBar: boolControl($hideStatusBar)
        case SettingsKey.autoSwitchLayouts: boolControl($autoSwitchLayouts)
        case SettingsKey.recordClipboardHistory: boolControl($recordClipboardHistory)
        case SettingsKey.scrollMultiplier:
            AnyView(HStack(spacing: Otty.Metric.space1) {
                Text(String(format: "%.2f×", scrollMultiplier))
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
                    .monospacedDigit()
                Stepper("", value: $scrollMultiplier, in: 0.25...5, step: 0.25).labelsHidden()
            })
        case SettingsKey.onLaunchKey:
            menuPicker($onLaunch) {
                Text("Restore Last Session").tag(OnLaunchBehavior.restoreLastSession)
                Text("New Window").tag(OnLaunchBehavior.newWindow)
            }
        case SettingsKey.defaultPaneKindKey:
            menuPicker($defaultPaneKind) {
                Text("Terminal").tag(PaneKind.terminal)
                Text("Remote GUI").tag(PaneKind.remoteGUI)
            }
        case SettingsKey.newTabPositionKey:
            menuPicker($newTabPosition) {
                Text("Automatic").tag(NewTabPosition.auto)
                Text("End").tag(NewTabPosition.end)
                Text("After Current").tag(NewTabPosition.afterCurrent)
            }
        case SettingsKey.closeConfirmTabKey: menuPicker($closeConfirmTab) { closeConfirmOptions }
        case SettingsKey.closeConfirmWindowKey: menuPicker($closeConfirmWindow) { closeConfirmOptions }
        case SettingsKey.workingDirectoryNewWindowKey: workingDirControl($workingDirNewWindow)
        case SettingsKey.workingDirectoryNewTabKey: workingDirControl($workingDirNewTab)
        case SettingsKey.workingDirectoryNewSplitKey: workingDirControl($workingDirNewSplit)
        default:
            // No inline editor wired (should not happen for an `.advancedOnly` entry) — show the default.
            AnyView(Text(entry.defaultText)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary))
        }
    }

    private func boolControl(_ binding: Binding<Bool>) -> AnyView {
        AnyView(Toggle("", isOn: binding).labelsHidden())
    }

    private func menuPicker(
        _ binding: Binding<some Hashable>, @ViewBuilder _ content: () -> some View,
    ) -> AnyView {
        AnyView(Picker("", selection: binding, content: content)
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize())
    }

    @ViewBuilder private var closeConfirmOptions: some View {
        Text("Running Process").tag(CloseConfirmationPolicy.process)
        Text("Always").tag(CloseConfirmationPolicy.always)
        Text("Multiple Tabs").tag(CloseConfirmationPolicy.multipleTabs)
    }

    /// The two working-dir choices, bridged onto the `WorkingDirectoryPolicy.rawConfig` String key (any
    /// non-`inherit` policy reads as `home`, exactly as the Shell tab's picker).
    private func workingDirControl(_ raw: Binding<String>) -> AnyView {
        let bridged = Binding<WorkingDirChoice>(
            get: { WorkingDirectoryPolicy(rawConfig: raw.wrappedValue) == .inherit ? .inherit : .home },
            set: { raw.wrappedValue = ($0 == .inherit ? WorkingDirectoryPolicy.inherit : .home).rawConfig },
        )
        return menuPicker(bridged) {
            Text("Same as Current").tag(WorkingDirChoice.inherit)
            Text("Home").tag(WorkingDirChoice.home)
        }
    }

    private enum WorkingDirChoice: String, CaseIterable, Identifiable {
        case inherit
        case home
        var id: String { rawValue }
    }

    /// A friendly display name for a theme choice (mirrors the Appearance picker labels).
    private func themeLabel(_ theme: ThemeChoice) -> String {
        switch theme {
        case .system: "System"
        case .monokaiProClassic: "Monokai Pro (Classic)"
        case .monokaiProClassicLight: "Monokai Pro Light"
        case .monokaiProOctagon: "Monokai Pro Octagon"
        case .monokaiProMachine: "Monokai Pro Machine"
        case .monokaiProRistretto: "Monokai Pro Ristretto"
        case .monokaiProSpectrum: "Monokai Pro Spectrum"
        case .paper: "Paper (Light)"
        case .dark: "Dark"
        }
    }
}
#endif
