import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskClientUI

/// Pins the `SettingsKey` fire-time accessors (default ON for the gates, with env/UserDefaults
/// overrides) — the shared source of truth between the Settings scene and the consumers.
@MainActor
final class SettingsKeyTests: XCTestCase {
    private var keys: [String] {
        [
            SettingsKey.oscNotifications,
            SettingsKey.longCommandNotifications,
            SettingsKey.systemDialogPanes,
            SettingsKey.defaultPaneKindKey,
            SettingsKey.snapPanes,
            SettingsKey.snapGrid,
            SettingsKey.showGrid,
            SettingsKey.nonOverlap,
            SettingsKey.autoSwitchLayouts,
            SettingsKey.redactSecrets,
            SettingsKey.recordClipboardHistory,
        ]
    }

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    func testGatesDefaultOnWhenUnset() {
        XCTAssertTrue(SettingsKey.oscNotificationsEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled)
        XCTAssertTrue(SettingsKey.systemDialogPanesEnabled)
    }

    func testGatesRespectAnExplicitFalse() {
        UserDefaults.standard.set(false, forKey: SettingsKey.oscNotifications)
        UserDefaults.standard.set(false, forKey: SettingsKey.systemDialogPanes)
        XCTAssertFalse(SettingsKey.oscNotificationsEnabled)
        XCTAssertFalse(SettingsKey.systemDialogPanesEnabled)
        XCTAssertTrue(SettingsKey.longCommandNotificationsEnabled, "an unset key stays default-ON")
    }

    func testCanvasKeyWireValuesArePinned() {
        // These exact strings are the single source of truth shared with every @AppStorage consumer
        // (CanvasView / CanvasItemView / FloatingPaneHandle / the menu toggles). Pinning the wire values
        // here means a rename that would silently split-brain the Settings UI from the canvas consumers
        // (a user toggles a setting that no longer applies) fails this test.
        XCTAssertEqual(SettingsKey.snapPanes, "canvas.snapPanes")
        XCTAssertEqual(SettingsKey.snapGrid, "canvas.snapGrid")
        XCTAssertEqual(SettingsKey.showGrid, "canvas.showGrid")
        XCTAssertEqual(SettingsKey.nonOverlap, "canvas.nonOverlap")
    }

    func testPrivacyAndLayoutGatesDefaultOnAndRespectFalse() {
        XCTAssertTrue(SettingsKey.redactSecretsEnabled)
        XCTAssertTrue(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertTrue(SettingsKey.autoSwitchLayoutsEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.redactSecrets)
        UserDefaults.standard.set(false, forKey: SettingsKey.recordClipboardHistory)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoSwitchLayouts)
        XCTAssertFalse(SettingsKey.redactSecretsEnabled)
        XCTAssertFalse(SettingsKey.recordClipboardHistoryEnabled)
        XCTAssertFalse(SettingsKey.autoSwitchLayoutsEnabled)
    }

    func testDefaultPaneKindDefaultsToTerminalAndRoundTrips() {
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal)
        UserDefaults.standard.set(PaneKind.remoteGUI.rawValue, forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .remoteGUI)
        // W11: a stale persisted `claudeCode` value (the retired kind) is no longer a valid raw value
        // here → falls back to `.terminal` (the safe default), like any other invalid raw value.
        UserDefaults.standard.set("claudeCode", forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal, "a retired/invalid raw value falls back to terminal")
        UserDefaults.standard.set("garbage", forKey: SettingsKey.defaultPaneKindKey)
        XCTAssertEqual(SettingsKey.defaultPaneKind, .terminal, "an invalid raw value falls back to terminal")
    }

    // MARK: - PreferencesStore (W13) — the live source the Settings panels bind to

    /// An isolated `UserDefaults` suite so the round-trips don't touch the real defaults.
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testPreferencesStoreLoadsModelDefaultsOnFreshInstall() {
        // A fresh install (no persisted prefs) loads the model DEFAULTS, and the all-nil video/agent
        // models contribute NOTHING to the EnvConfig overlay (behaviour-preserving). `applyOnInit: false`
        // so we assert the loaded models without mutating the process-wide overlay.
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        XCTAssertEqual(store.terminal, TerminalPreferences())
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertEqual(store.agent, AgentPreferences())
        XCTAssertEqual(store.keybindings, KeybindingPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        // The behaviour-preservation proof: the default video ∪ agent overlay is EMPTY.
        XCTAssertTrue(EnvBridge.toEnv(store.video).isEmpty)
        XCTAssertTrue(EnvBridge.toEnv(store.agent).isEmpty)
    }

    func testPreferencesStoreRoundTripsEachModelThroughUserDefaults() {
        let defaults = makeIsolatedDefaults()
        // Write a custom value for each model, then reload a NEW store from the SAME defaults.
        let store = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontFamily: "JetBrains Mono", fontSize: 15, cursorStyle: .bar)
        store.video = VideoPreferences(qpSharp: 22, fecM: 2, fecK: 5)
        store.agent = AgentPreferences(agentDetect: true)
        store.keybindings = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "e", command: true)])
        store.rawOverrides = ["AISLOPDESK_FOO": "1"]

        let reloaded = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        XCTAssertEqual(reloaded.terminal, store.terminal)
        XCTAssertEqual(reloaded.video, store.video)
        XCTAssertEqual(reloaded.agent, store.agent)
        XCTAssertEqual(reloaded.keybindings, store.keybindings)
        XCTAssertEqual(reloaded.rawOverrides, store.rawOverrides)
    }

    func testResetAllReturnsToBehaviourPreservingDefaults() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.video = VideoPreferences(qpSharp: 30)
        store.rawOverrides = ["AISLOPDESK_X": "9"]
        store.resetAll()
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        XCTAssertTrue(EnvBridge.toEnv(store.video).isEmpty)
    }
}
