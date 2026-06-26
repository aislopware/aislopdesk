import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

/// E7 WI-3: pins the headless ``AllSettingsCatalog`` (filter + full client-key coverage + buckets) and the
/// ``PreferencesStore`` reset behaviour the Advanced "All Settings" panel drives. All headless — no view.
@MainActor
final class AllSettingsCatalogTests: XCTestCase {
    // The global `Defaults.Keys` the reset tests flip live in `UserDefaults.standard`; clean them up so the
    // dev machine's real defaults are not polluted (the catalog/filter tests touch no defaults at all).
    private let touchedKeys = [
        SettingsKey.copyOnSelect, SettingsKey.hideStatusBar, SettingsKey.density,
    ]

    override func setUp() { touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    // MARK: - Filter

    /// The search filter matches case-insensitively against key / label / description / keywords. The spec's
    /// own examples (`cursor`, `scrollback`, `blink`) narrow to the expected rows; an empty query returns
    /// ALL entries; a no-match query returns `[]`.
    func testFilterMatchesKeyLabelDescriptionKeywords() {
        // Empty query → every entry, order-preserving.
        XCTAssertEqual(AllSettingsCatalog.filter("").count, AllSettingsCatalog.entries.count)
        XCTAssertEqual(AllSettingsCatalog.filter("   ").count, AllSettingsCatalog.entries.count)

        // `cursor` → exactly the two cursor render-pref rows (key + label + description match).
        XCTAssertEqual(Set(AllSettingsCatalog.filter("cursor").map(\.key)), ["cursor-style", "cursor-style-blink"])
        // Case-insensitive.
        XCTAssertEqual(AllSettingsCatalog.filter("CURSOR").count, 2)

        // `scrollback` → only the scrollback row (the scroll-multiplier / scroll-on-output rows say "scroll",
        // never "scrollback").
        XCTAssertEqual(AllSettingsCatalog.filter("scrollback").map(\.key), ["scrollback-limit"])

        // `blink` → only the cursor-blink row.
        XCTAssertEqual(AllSettingsCatalog.filter("blink").map(\.key), ["cursor-style-blink"])

        // Matches a keyword that is in neither the key nor the label/description.
        XCTAssertTrue(AllSettingsCatalog.filter("autoscroll").contains { $0.key == SettingsKey.scrollOnOutput })

        // No-match query → empty. (`filter(_:)` here is the catalog's query-search method, not
        // `Sequence.filter(where:)`; bind the result so the lint's `.filter(...).isEmpty` heuristic — a
        // false positive on a domain search returning `[SettingEntry]` — doesn't misfire.)
        let noMatches = AllSettingsCatalog.filter("zzz-no-such-key")
        XCTAssertTrue(noMatches.isEmpty)
    }

    // MARK: - Full coverage (anti-drift)

    /// Every client-side ``SettingsKey`` that the otty settings taxonomy surfaces MUST appear in the catalog
    /// — the All-Settings list is "complete". Revert-to-fail: dropping a `SettingEntry` makes this fail. The
    /// required list references the `SettingsKey` constants directly (independent of `entries`), so it is a
    /// real anti-drift pin, not a tautology. (Canvas-mode keys — `canvas.*` — are intentionally excluded;
    /// they belong to the legacy canvas surface, not the otty 8-section settings.)
    func testCatalogCoversEveryClientSettingsKey() {
        let required: [String] = [
            // General
            SettingsKey.onLaunchKey, SettingsKey.oscNotifications, SettingsKey.longCommandNotifications,
            SettingsKey.redactSecrets, SettingsKey.defaultPaneKindKey,
            // Shell
            SettingsKey.workingDirectoryNewWindowKey, SettingsKey.workingDirectoryNewTabKey,
            SettingsKey.workingDirectoryNewSplitKey, SettingsKey.newTabPositionKey,
            SettingsKey.closeConfirmTabKey, SettingsKey.closeConfirmWindowKey,
            // Controls / copy / mouse / scroll
            SettingsKey.copyOnSelect, SettingsKey.trimTrailingSpacesOnCopy, SettingsKey.pasteProtection,
            SettingsKey.mouseHideWhileTyping, SettingsKey.focusFollowsMouse, SettingsKey.scrollOnOutput,
            SettingsKey.scrollMultiplier, SettingsKey.systemDialogPanes,
            // Editor / chrome orphans
            SettingsKey.showBlockDividers, SettingsKey.hideStatusBar,
            // Agents
            SettingsKey.autoSwitchLayouts, SettingsKey.recordClipboardHistory,
            // Appearance
            SettingsKey.density,
        ]
        let present = Set(AllSettingsCatalog.entries.map(\.key))
        for key in required {
            XCTAssertTrue(present.contains(key), "All Settings catalog is missing client key '\(key)'")
        }
    }

    /// The catalog has no duplicate keys (each is the list's identity).
    func testCatalogKeysAreUnique() {
        let keys = AllSettingsCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "duplicate keys in the All Settings catalog")
    }

    // MARK: - Buckets

    /// The orphan + new fire-time toggles are `.advancedOnly` (inline-editable in the list); the rich
    /// typed-render fields (font / theme / cursor) are `.hasDedicatedTab` (jump to their tab) and each names
    /// a destination section.
    func testAdvancedOnlyVsDedicatedTabBuckets() {
        func bucket(_ key: String) -> AllSettingsCatalog.SettingEntry.Bucket? {
            AllSettingsCatalog.entries.first { $0.key == key }?.bucket
        }
        for key in [
            SettingsKey.hideStatusBar, SettingsKey.showBlockDividers, SettingsKey.systemDialogPanes,
            SettingsKey.autoSwitchLayouts, SettingsKey.recordClipboardHistory,
            SettingsKey.copyOnSelect, SettingsKey.scrollMultiplier,
        ] {
            XCTAssertEqual(bucket(key), .advancedOnly, "'\(key)' should be advancedOnly (inline)")
        }
        for key in ["font-family", "font-size", "theme", "cursor-style", "cursor-style-blink"] {
            XCTAssertEqual(bucket(key), .hasDedicatedTab, "'\(key)' should be hasDedicatedTab (jump)")
        }
        // Every hasDedicatedTab entry names a target section; every advancedOnly entry does NOT.
        for entry in AllSettingsCatalog.entries {
            switch entry.bucket {
            case .hasDedicatedTab:
                XCTAssertNotNil(entry.targetSection, "'\(entry.key)' (hasDedicatedTab) must name a target section")
            case .advancedOnly:
                XCTAssertNil(entry.targetSection, "'\(entry.key)' (advancedOnly) should not name a target section")
            }
        }
    }

    // MARK: - PreferencesStore reset behaviour (the panel's Reset buttons)

    /// An isolated `UserDefaults` suite for the injected store models (the global `Defaults.Keys` are still
    /// `.standard`-backed — those are cleaned up in `tearDown`).
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AllSettingsCatalogTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// "Reset Advanced Only" clears the video / agent host flags + raw overrides AND the global advanced
    /// toggles, but LEAVES the font (`terminal`), theme (`appearance`), and keybinding choices intact —
    /// `customization__advanced-settings.md`.
    func testResetAdvancedOnlyPreservesAppearanceFontKeybindings() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontSize: 18)
        store.appearance = AppearancePreferences(theme: .dark)
        store.keybindings = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "e", command: true)])
        store.video = VideoPreferences(qpSharp: 30)
        store.agent = AgentPreferences(agentDetect: true)
        store.rawOverrides = ["AISLOPDESK_X": "9"]
        // A flipped advanced-bucket orphan toggle (global `.standard` key).
        UserDefaults.standard.set(true, forKey: SettingsKey.copyOnSelect)
        XCTAssertTrue(SettingsKey.copyOnSelectEnabled)

        store.resetAdvancedOnly()

        // Advanced bucket cleared.
        XCTAssertEqual(store.video, VideoPreferences())
        XCTAssertEqual(store.agent, AgentPreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        XCTAssertFalse(SettingsKey.copyOnSelectEnabled, "advanced-only toggle is reset")
        // Font / theme / keybindings preserved.
        XCTAssertEqual(store.terminal.fontSize, 18)
        XCTAssertEqual(store.appearance.theme, .dark)
        XCTAssertEqual(store.keybindings.overrides["pane.splitRight"]?.key, "e")
    }

    /// "Reset All Settings" returns EVERYTHING to defaults — the typed models AND a flipped global orphan
    /// toggle (`hideStatusBar`). Revert-to-fail: before WI-1 extended `resetAll()`, the `Defaults.Keys`
    /// toggle survived a reset.
    func testResetAllClearsEverythingIncludingOrphanToggle() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults(), sidecarURL: nil, applyOnInit: false)
        store.terminal = TerminalPreferences(fontSize: 18)
        store.appearance = AppearancePreferences(theme: .dark)
        UserDefaults.standard.set(true, forKey: SettingsKey.hideStatusBar)
        XCTAssertTrue(SettingsKey.hideStatusBarEnabled)

        store.resetAll()

        XCTAssertEqual(store.terminal, TerminalPreferences())
        XCTAssertEqual(store.appearance, AppearancePreferences())
        XCTAssertTrue(store.rawOverrides.isEmpty)
        XCTAssertFalse(SettingsKey.hideStatusBarEnabled, "Reset All clears the orphan toggle")
    }
}
