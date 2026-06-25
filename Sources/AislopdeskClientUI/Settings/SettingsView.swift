// SettingsView — the SwiftUI Settings surface (REBUILD-V2, WS-D / D4).
//
// A tabbed Settings window whose tabs are THIN `@Bindable` bindings over the one live `@Observable`
// `PreferencesStore`. Each tab edits a slice of the typed prefs models (`TerminalPreferences`,
// `VideoPreferences`, `AgentPreferences`, `AppearancePreferences`, `KeybindingPreferences`) or the
// fire-time `SettingsKey` toggles, and the store's `didSet` apply-paths do the rest (terminal live-reload,
// env overlay + sidecar, theme repoint, keybinding republish).
//
// SURFACING: the main window is `.hiddenTitleBar` and `OverlayCoordinator` is NOT yet mounted, so this
// rides a STOCK SwiftUI `Settings` scene (`AislopdeskSettingsScene`) — ⌘, opens a separate, system-chromed
// window that does not clash with otty's hover-reveal titlebar. When the coordinator lands, the same view
// tree can be relocated into an in-window otty panel via `settingsVisible`.
//
// DEFERRED vs LIVE-APPLY: each field is tagged with an `ApplyTiming` chip (`.live` applies immediately;
// `.reconnect` is a HOST-read flag shipped via the sidecar that only takes effect on the next host
// connection). Terminal + appearance + keybindings are live; the video/agent HOST flags are reconnect-only;
// SYMMETRIC keys (FEC) additionally carry a "set on both ends" warning.
//
// Otty.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import Defaults
import SwiftUI

// MARK: - Settings scene (stock SwiftUI, ⌘,)

/// The stock `Settings` scene wrapper, wired in `AislopdeskClientApp`. Stock (not an otty in-window panel)
/// because the main window hides its titlebar and the overlay host is not yet mounted (see file header).
/// macOS-only: the `Settings` scene is unavailable on iOS (the iOS settings surface lands as an in-app
/// sheet later); `SettingsView` itself stays cross-platform so iOS can host it once that lands.
#if os(macOS)
public struct AislopdeskSettingsScene: Scene {
    private let store: PreferencesStore

    public init(store: PreferencesStore) { self.store = store }

    public var body: some Scene {
        Settings {
            SettingsView(store: store)
                .tint(Otty.State.accent)
                .preferredColorScheme(Otty.colorScheme)
        }
    }
}
#endif

// MARK: - Apply-timing tag (deferred vs live, surfaced as a chip not prose)

/// When a setting takes effect — surfaced as a small chip so the deferred/live distinction is a DATA
/// attribute, not buried in prose (D4).
enum ApplyTiming {
    case live // applies immediately (terminal reload / theme / keybinding republish / fire-time key)
    case reconnect // a HOST-read flag shipped via the sidecar — applies on the next host connection

    var label: String {
        switch self {
        case .live: "Applies now"
        case .reconnect: "Applies on reconnect"
        }
    }

    var symbol: String {
        switch self {
        case .live: "bolt.fill"
        case .reconnect: "arrow.triangle.2.circlepath"
        }
    }
}

/// A small inline timing chip (symbol + label). The tint reads the `@MainActor` `Otty.Status` tokens in
/// the view body (not on the nonisolated enum).
private struct TimingChip: View {
    let timing: ApplyTiming
    var body: some View {
        HStack(spacing: Otty.Metric.space1) {
            Image(systemName: timing.symbol)
            Text(timing.label)
        }
        .font(.system(size: Otty.Typeface.small))
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch timing {
        case .live: Otty.Status.ok
        case .reconnect: Otty.Status.warn
        }
    }
}

// MARK: - The tabbed Settings view

/// The Settings body: a `TabView` whose tabs each bind a slice of the live store.
struct SettingsView: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsTab(store: store)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            VideoSettingsTab(store: store)
                .tabItem { Label("Video", systemImage: "video") }
            KeybindingsSettingsTab(store: store)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
            AdvancedSettingsTab(store: store)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(Otty.Surface.window)
    }
}

// MARK: - General / Appearance tab

/// General + Appearance: the otty theme picker (via `AppearancePreferences` → `ThemeStore`), density, and
/// the fire-time `SettingsKey` toggles (notifications / redact-secrets / default pane kind). All LIVE.
private struct GeneralSettingsTab: View {
    @Bindable var store: PreferencesStore

    /// The fire-time keys are NOT in the typed models, so bind the global `Defaults.Keys` directly through
    /// the type-safe `@Default(.key)` wrapper (the default lives in the key declaration, not here).
    @Default(.oscNotifications) private var oscNotifications
    @Default(.longCommandNotifications) private var longCommandNotifications
    @Default(.redactSecrets) private var redactSecrets
    @Default(.defaultPaneKind) private var defaultPaneKind

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: themeBinding) {
                    Text("System").tag(ThemeChoice.system)
                    Divider()
                    Text("Monokai Pro (Classic)").tag(ThemeChoice.monokaiProClassic)
                    Text("Monokai Pro Light").tag(ThemeChoice.monokaiProClassicLight)
                    Text("Monokai Pro Octagon").tag(ThemeChoice.monokaiProOctagon)
                    Text("Monokai Pro Machine").tag(ThemeChoice.monokaiProMachine)
                    Text("Monokai Pro Ristretto").tag(ThemeChoice.monokaiProRistretto)
                    Text("Monokai Pro Spectrum").tag(ThemeChoice.monokaiProSpectrum)
                    Divider()
                    Text("Paper (Light)").tag(ThemeChoice.paper)
                    Text("Dark").tag(ThemeChoice.dark)
                }
                LabeledContent("Density") {
                    Picker("Density", selection: densityBinding) {
                        Text("Comfortable").tag("comfortable")
                        Text("Compact").tag("compact")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                timingFooter(.live)
            }

            Section("Notifications") {
                Toggle("Explicit notifications (OSC 9 / 777)", isOn: $oscNotifications)
                Toggle("Long-command completion", isOn: $longCommandNotifications)
                timingFooter(.live)
            }

            Section("Privacy & New Panes") {
                Toggle("Redact likely secrets from titles", isOn: $redactSecrets)
                Picker("Default pane kind", selection: $defaultPaneKind) {
                    Text("Terminal").tag(PaneKind.terminal)
                    Text("Remote GUI").tag(PaneKind.remoteGUI)
                }
                timingFooter(.live)
            }
        }
        .formStyle(.grouped)
    }

    /// Bridge the picker (non-optional `ThemeChoice`) to the optional model field: unset (`nil`) reads as
    /// `.system`-equivalent default but writing always sets an explicit choice (so the user's pick persists).
    private var themeBinding: Binding<ThemeChoice> {
        Binding(
            get: { store.appearance.theme ?? .system },
            set: { store.appearance.theme = $0 },
        )
    }

    private var densityBinding: Binding<String> {
        Binding(
            get: { store.appearance.density ?? "comfortable" },
            set: { store.appearance.density = $0 },
        )
    }
}

// MARK: - Terminal tab (live reload via TerminalConfigBroadcaster)

/// Terminal render prefs — font / cursor / scrollback. These apply LIVE (the store rebuilds the libghostty
/// config string and bumps `TerminalConfigBroadcaster`).
private struct TerminalSettingsTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section("Font") {
                TextField("Family", text: $store.terminal.fontFamily)
                Stepper(
                    "Size: \(Int(store.terminal.fontSize))",
                    value: $store.terminal.fontSize, in: 8...32, step: 1,
                )
            }
            Section("Cursor") {
                Picker("Style", selection: $store.terminal.cursorStyle) {
                    ForEach(TerminalPreferences.CursorStyle.allCases, id: \.self) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
                Toggle("Blink", isOn: $store.terminal.cursorBlink)
            }
            Section("Scrollback") {
                Stepper(
                    "Lines: \(store.terminal.scrollbackLines)",
                    value: $store.terminal.scrollbackLines, in: 1000...100_000, step: 1000,
                )
            }
            Section { timingFooter(.live) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Video tab (host-read flags — applies on reconnect; FEC symmetric)

/// Video / FEC / agent host flags. These are read by the HOST daemon at launch and shipped via the
/// `video-prefs.json` sidecar, so they are labelled "applies on reconnect"; the SYMMETRIC FEC keys add a
/// "set on both ends" warning. The client-side `sharpen` is the one live field.
private struct VideoSettingsTab: View {
    @Bindable var store: PreferencesStore

    var body: some View {
        Form {
            Section("Quality") {
                optionalIntStepper("Sharp QP", $store.video.qpSharp, range: 1...51, default: 26)
                optionalIntStepper("Coarse QP", $store.video.qpCoarse, range: 1...51, default: 40)
                timingFooter(.reconnect)
            }

            Section {
                optionalIntStepper("Parity (m)", $store.video.fecM, range: 1...8, default: 1)
                optionalIntStepper("Group size (k)", $store.video.fecK, range: 1...32, default: 8)
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("FEC must be set IDENTICALLY on both ends or the host and client disagree.")
                }
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Status.warn)
                timingFooter(.reconnect)
            } header: {
                Text("Forward Error Correction (symmetric)")
            }

            Section("Pacer") {
                Picker("Mode", selection: pacerBinding) {
                    Text("Default (deadline)").tag(VideoPreferences.Pacer?.none)
                    Text("Deadline").tag(Optional(VideoPreferences.Pacer.deadline))
                    Text("On arrival").tag(Optional(VideoPreferences.Pacer.arrival))
                }
                timingFooter(.reconnect)
            }

            Section("Client render") {
                optionalDoubleSlider("Sharpen", $store.video.sharpen, range: 0...2, default: 0)
                timingFooter(.live)
            }

            Section("Agent detection (host)") {
                optionalBoolToggle("Foreground-process watch", $store.agent.agentDetect)
                optionalBoolToggle("Claude Code hooks", $store.agent.agentHooks)
                timingFooter(.reconnect)
            }
        }
        .formStyle(.grouped)
    }

    private var pacerBinding: Binding<VideoPreferences.Pacer?> {
        Binding(get: { store.video.pacer }, set: { store.video.pacer = $0 })
    }

    // MARK: Optional-field editors (nil = "unset / use compile-time default")

    /// An optional-Int stepper: a leading "Set" toggle gates the value (off ⇒ `nil` ⇒ unset, golden-safe).
    private func optionalIntStepper(
        _ title: String, _ binding: Binding<Int?>, range: ClosedRange<Int>, default def: Int,
    ) -> some View {
        HStack {
            Toggle(isOn: setBinding(binding, default: def)) { Text(title) }
                .toggleStyle(.switch)
            Spacer()
            if let value = binding.wrappedValue {
                Stepper("\(value)", value: nonOptional(binding, default: def), in: range)
                    .labelsHidden()
                Text("\(value)").foregroundStyle(Otty.Text.secondary)
            } else {
                Text("default").foregroundStyle(Otty.Text.tertiary)
                    .font(.system(size: Otty.Typeface.footnote))
            }
        }
    }

    private func optionalDoubleSlider(
        _ title: String, _ binding: Binding<Double?>, range: ClosedRange<Double>, default def: Double,
    ) -> some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Toggle(isOn: setBinding(binding, default: def)) { Text(title) }
                .toggleStyle(.switch)
            if binding.wrappedValue != nil {
                Slider(value: nonOptional(binding, default: def), in: range)
            }
        }
    }

    private func optionalBoolToggle(_ title: String, _ binding: Binding<Bool?>) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 ? true : nil },
        )) { Text(title) }
    }

    /// A `Bool` binding that toggles an optional field between `nil` (unset) and a default value.
    private func setBinding<T>(_ binding: Binding<T?>, default def: T) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue != nil },
            set: { binding.wrappedValue = $0 ? def : nil },
        )
    }

    /// A non-optional projection of an optional binding (only used when the value is already non-nil; falls
    /// back to `def` defensively).
    private func nonOptional<T>(_ binding: Binding<T?>, default def: T) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue ?? def },
            set: { binding.wrappedValue = $0 },
        )
    }
}

// MARK: - Keybindings tab

private struct KeybindingsSettingsTab: View {
    @Bindable var store: PreferencesStore
    var body: some View {
        KeybindingsEditorView(store: store)
    }
}

// MARK: - Advanced tab (raw overrides — folded LAST; a real env var still wins)

/// The power-user raw `AISLOPDESK_*` override box, folded LAST into the env overlay (so a typed raw key
/// beats the matching typed pref). A precedence note makes clear a REAL process env var still wins over the
/// whole overlay. Folded last in the tab order too.
private struct AdvancedSettingsTab: View {
    @Bindable var store: PreferencesStore

    /// Local edit buffer of `key = value` lines; committed into `store.rawOverrides` on change.
    @State private var text: String = ""

    var body: some View {
        Form {
            Section("Raw overrides") {
                Text(
                    "One AISLOPDESK_KEY=value per line. Folded last, so a key here overrides the matching typed setting.",
                )
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                TextEditor(text: $text)
                    .font(.system(size: Otty.Typeface.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: text) { _, new in commit(new) }
                HStack(spacing: Otty.Metric.space1) {
                    Image(systemName: "info.circle")
                    Text("A real environment variable set on the process still wins over any value here.")
                }
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
            }

            Section {
                Button("Restore All Defaults", role: .destructive) {
                    store.resetAll()
                    text = ""
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { text = Self.render(store.rawOverrides) }
    }

    /// Parse the `key=value` lines and write them into `store.rawOverrides` (empty / malformed lines ignored).
    private func commit(_ raw: String) {
        var map: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        if map != store.rawOverrides { store.rawOverrides = map }
    }

    private static func render(_ map: [String: String]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Shared timing footer

/// A right-aligned timing chip used as a section footer so each section's apply timing is visible inline.
private func timingFooter(_ timing: ApplyTiming) -> some View {
    HStack {
        Spacer()
        TimingChip(timing: timing)
    }
}
#endif
