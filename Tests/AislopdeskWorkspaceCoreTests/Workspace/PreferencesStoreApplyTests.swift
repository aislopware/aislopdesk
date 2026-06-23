import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// W13 — the ``PreferencesStore`` APPLY paths (live env overlay, sidecar, terminal broadcast, keybinding
/// overrides) + the W6 ``WorkspaceBindingRegistry`` consulting ``KeybindingPreferences``. These prove the
/// wiring, not just the round-trip (which `SettingsKeyTests` covers).
@MainActor
final class PreferencesStoreApplyTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "PreferencesStoreApplyTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        // Restore the process-wide overlays the apply paths mutate so a later test isn't polluted.
        EnvConfig.overlay = [:]
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    // MARK: Live env overlay

    func testVideoAndRawOverridesFoldIntoEnvConfigOverlay() {
        EnvConfig.overlay = [:]
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        // Empty prefs ⇒ empty overlay (behaviour-preserving — the golden corpus is unaffected).
        XCTAssertTrue(EnvConfig.overlay.isEmpty, "default prefs produce an empty overlay")

        store.video = VideoPreferences(qpSharp: 22, fecM: 2)
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_QP_SHARP"], "22")
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_FEC_M"], "2")

        // A raw override is folded LAST so it wins over a matching typed setting.
        store.rawOverrides = ["AISLOPDESK_QP_SHARP": "18", "AISLOPDESK_CUSTOM": "x"]
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_QP_SHARP"], "18", "raw override wins over the typed pref")
        XCTAssertEqual(EnvConfig.overlay["AISLOPDESK_CUSTOM"], "x")
    }

    func testEnvConfigResolvesTheOverlayValueAfterApply() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.agent = AgentPreferences(agentDetect: true)
        // The agent gate is default-OFF (== "1"); an explicit ON writes "1" into the overlay, which
        // `EnvConfig` then resolves.
        XCTAssertEqual(EnvConfig.string("AISLOPDESK_AGENT_DETECT"), "1")
        XCTAssertTrue(EnvConfig.boolDefaultOff("AISLOPDESK_AGENT_DETECT"))
    }

    // MARK: Sidecar (video-prefs.json)

    func testVideoChangeWritesTheSidecar() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-prefs-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: tmp)
        store.video = VideoPreferences(fecM: 3, fecK: 6)

        let sidecar = EnvBridge.readSidecar(at: tmp)
        XCTAssertEqual(sidecar?.video.fecM, 3)
        XCTAssertEqual(sidecar?.video.fecK, 6)
        // Its env contribution matches the typed prefs.
        XCTAssertEqual(sidecar?.toEnv()["AISLOPDESK_FEC_M"], "3")
    }

    // MARK: Terminal broadcast

    func testTerminalChangeBumpsTheBroadcaster() {
        let before = TerminalConfigBroadcaster.shared.generation
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        // init published once (applyOnInit default ON).
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, before)
        let afterInit = TerminalConfigBroadcaster.shared.generation
        store.terminal = TerminalPreferences(fontFamily: "Menlo", fontSize: 16)
        XCTAssertGreaterThan(TerminalConfigBroadcaster.shared.generation, afterInit, "a change re-publishes")
        XCTAssertTrue(TerminalConfigBroadcaster.shared.configString.contains("font-family = Menlo"))
        XCTAssertTrue(TerminalConfigBroadcaster.shared.configString.contains("font-size = 16"))
    }

    // MARK: Keybinding overrides → the W6 registry

    func testStorePublishesKeybindingOverridesToTheRegistry() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true, shift: true),
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.activeOverrides.chord(for: "pane.splitRight")?.canonical,
            "shift+cmd+e",
        )
    }

    func testRegistryResolvesOverrideElseDefault() {
        // Default: split-right is ⌘D.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: KeybindingPreferences()),
            KeyChord(character: "d", [.command]),
        )
        // With an override, the resolved chord is the override (⌘E here), NOT the default.
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: overrides),
            KeyChord(character: "e", [.command]),
        )
        // An unrelated action is unaffected by the override.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .closePane, overrides: overrides),
            KeyChord(character: "w", [.command]),
        )
    }

    func testResolvedChordTableRoutesTheOverrideChord() {
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])
        let table = WorkspaceBindingRegistry.resolvedChordTable(overrides: overrides)
        // The NEW chord routes to splitRight; the OLD default chord no longer does (it's now free).
        XCTAssertEqual(table[KeyChord(character: "e", [.command])], .splitRight)
        XCTAssertNil(table[KeyChord(character: "d", [.command])], "the old default chord is freed by the override")
    }

    func testMalformedOverrideFallsBackToTheDefault() {
        // An override whose key can't map to a registry chord (empty / multi-char) is IGNORED →
        // the registry default stands (validate-then-default, never traps).
        let overrides = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "", command: true), // empty key → unmappable
        ])
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChord(for: .splitRight, overrides: overrides),
            KeyChord(character: "d", [.command]), "an unmappable override falls back to the default",
        )
    }

    func testNamedKeyOverrideMapsToTheRegistryKey() {
        // A named-key override (e.g. rebinding focus-left to ⌘⇧↩) maps to the registry's Key case.
        let chord = KeybindingPreferences.KeyChord(key: "return", command: true, shift: true)
        XCTAssertEqual(chord.asRegistryChord, KeyChord(.return, [.command, .shift]))
        let left = KeybindingPreferences.KeyChord(key: "left", command: true, option: true)
        XCTAssertEqual(left.asRegistryChord, KeyChord(.leftArrow, [.option, .command]))
    }
}
