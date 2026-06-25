import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// WS-D / D6 — the keybindings-editor LOGIC seam (headless; no SwiftUI instantiation). The editor view is
/// a thin shell over `PreferencesStore.keybindings`; these prove the store/registry behaviour the editor
/// relies on: a write to `store.keybindings` republishes to `WorkspaceBindingRegistry.activeOverrides` and
/// the process-wide `resolvedChordTable` routes the NEW chord while FREEING the old default; conflicts
/// surface through `store.keybindingConflicts()`; a malformed override falls back to the registry default.
@MainActor
final class KeybindingsEditorLogicTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "KeybindingsEditorLogicTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    override func tearDown() {
        // The store's apply path mutates the process-wide registry overrides; restore so a later test is clean.
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        EnvConfig.overlay = [:]
        super.tearDown()
    }

    /// Writing an override into `store.keybindings` republishes it to the live registry AND the live
    /// `resolvedChordTable` routes the new chord while the old default chord is freed — the end-to-end path
    /// the editor depends on (it never touches `activeOverrides` itself).
    func testEditorWriteRepublishesAndRoutesLiveResolvedChordTable() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)

        // Pre-condition: default split-right is ⌘D and the live table routes it.
        XCTAssertEqual(WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])], .splitRight)

        // The editor's only mutation: assign a fresh KeybindingPreferences to the store (rebinds ⌘E).
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "e", command: true),
        ])

        // 1) Republished to the process-wide live registry overrides.
        XCTAssertEqual(
            WorkspaceBindingRegistry.activeOverrides.chord(for: "pane.splitRight")?.canonical, "cmd+e",
        )
        // 2) The LIVE resolvedChordTable (reads activeOverrides) now routes ⌘E …
        XCTAssertEqual(WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "e", [.command])], .splitRight)
        // 3) … and the OLD default ⌘D no longer routes to split-right (it is freed).
        XCTAssertNil(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])],
            "the old default chord is freed by the override on the LIVE table",
        )
    }

    /// `store.keybindingConflicts()` surfaces the two binding ids that collide on ONE chord (the banner +
    /// per-row warning the editor renders). Two DISTINCT ids overridden to the same chord ⇒ one conflict
    /// entry naming both ids.
    func testKeybindingConflictsSurfacesTwoIdsOnOneChord() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "g", command: true),
            "pane.close": .init(key: "g", command: true),
        ])

        let conflicts = store.keybindingConflicts()
        XCTAssertEqual(conflicts.count, 1, "exactly one chord collides")
        let colliding = conflicts["cmd+g"]
        XCTAssertEqual(colliding.map(Set.init), Set(["pane.splitRight", "pane.close"]))
    }

    /// A malformed override (an unmappable key) is ignored on the LIVE table — the binding keeps its
    /// registry default (validate-then-default, never traps). Proves the editor can't brick a chord by
    /// storing garbage.
    func testMalformedOverrideFallsBackToDefaultOnLiveTable() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil)
        store.keybindings = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "", command: true), // empty key → unmappable
        ])
        // The default ⌘D still routes split-right on the LIVE table (the bad override is dropped).
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "d", [.command])], .splitRight,
            "an unmappable override leaves the registry default routing on the live table",
        )
    }
}
