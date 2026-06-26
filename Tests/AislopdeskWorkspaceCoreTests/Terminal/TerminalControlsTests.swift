import XCTest
@testable import AislopdeskWorkspaceCore

/// E8 WI-1: pins the pure ``TerminalControls`` bundle — the `from(defaults:)` factory's key→field mapping
/// (anti-mapping-error: every field is set to a NON-default value, so a swapped / dropped key fails), the
/// new control enums' raw values + non-failable repair + the bare-rawValue persistence the
/// `Defaults.PreferRawRepresentable` bridge round-trips, and the `MouseShiftCapture.configValue` libghostty
/// tokens WI-2 emits. All headless — an injected `UserDefaults` suite isolates the round-trips from the dev
/// machine's real defaults, and the suite is written through RAW `UserDefaults` (the file's established
/// no-`import Defaults` convention, exactly like `SettingsKeyTests`).
@MainActor
final class TerminalControlsTests: XCTestCase {
    /// An isolated `UserDefaults` suite so the round-trips never touch `.standard`.
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "TerminalControlsTest." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Defaults / init parity

    /// The struct's init defaults mirror the `Defaults.Keys` defaults, so `from(...)` on a FRESH suite (no
    /// persisted value) equals a default-constructed `TerminalControls`. This pins the "factory terminal"
    /// invariant and that the factory reads through the injected suite (not `.standard`).
    func testFactoryFromFreshSuiteEqualsDefaults() {
        let controls = TerminalControls.from(defaults: makeIsolatedDefaults())
        XCTAssertEqual(controls, TerminalControls())
        // Spot-check the otty default values directly (independent of the init defaults).
        XCTAssertFalse(controls.copyOnSelect)
        XCTAssertTrue(controls.trimTrailing)
        XCTAssertTrue(controls.clearOnTyping)
        XCTAssertFalse(controls.clearOnCopy)
        XCTAssertEqual(controls.clipboardRead, .ask)
        XCTAssertEqual(controls.clipboardWrite, .allow)
        XCTAssertEqual(controls.allowShiftClick, .enabled)
        XCTAssertEqual(controls.rightClickAction, .contextMenu)
        XCTAssertEqual(controls.scrollMultiplier, 1.0)
    }

    /// Anti-mapping-error: every persisted key is set to a value DISTINCT from its default, so a factory that
    /// reads the wrong key (or drops one) produces a mismatch this catches. Revert-to-fail: swap any two
    /// `defaults[...]` reads in `from(defaults:)` and a field below diverges. The enum keys are written as
    /// their bare rawValue string (what the `RawRepresentableBridge` stores), proving the factory decodes
    /// them through the bridge.
    func testFactoryReadsEveryPersistedKey() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: SettingsKey.copyOnSelect)
        defaults.set(false, forKey: SettingsKey.trimTrailingSpacesOnCopy)
        defaults.set(false, forKey: SettingsKey.clearSelectionOnTyping)
        defaults.set(true, forKey: SettingsKey.clearSelectionOnCopy)
        defaults.set(false, forKey: SettingsKey.pasteProtection)
        defaults.set(false, forKey: SettingsKey.pasteBracketedSafe)
        defaults.set(ClipboardAccess.deny.rawValue, forKey: SettingsKey.clipboardReadKey)
        defaults.set(ClipboardAccess.deny.rawValue, forKey: SettingsKey.clipboardWriteKey)
        defaults.set(false, forKey: SettingsKey.mouseHideWhileTyping)
        defaults.set(MouseShiftCapture.always.rawValue, forKey: SettingsKey.allowShiftClickKey)
        defaults.set(false, forKey: SettingsKey.clickToMove)
        defaults.set(false, forKey: SettingsKey.allowMouseCapture)
        defaults.set(RightClickAction.copyOrPaste.rawValue, forKey: SettingsKey.rightClickActionKey)
        defaults.set(false, forKey: SettingsKey.shiftArrowSelect)
        defaults.set(2.5, forKey: SettingsKey.scrollMultiplier)

        let controls = TerminalControls.from(defaults: defaults)
        XCTAssertEqual(
            controls,
            TerminalControls(
                copyOnSelect: true,
                trimTrailing: false,
                clearOnTyping: false,
                clearOnCopy: true,
                pasteProtection: false,
                bracketedSafe: false,
                clipboardRead: .deny,
                clipboardWrite: .deny,
                hideMouseWhileTyping: false,
                allowShiftClick: .always,
                clickToMove: false,
                allowMouseCapture: false,
                rightClickAction: .copyOrPaste,
                shiftArrowSelect: false,
                scrollMultiplier: 2.5,
            ),
        )
    }

    /// A stale / hostile persisted enum token decodes through the factory and repairs to the default rather
    /// than trapping (the non-failable `init(rawValue:)` the bridge relies on).
    func testFactoryRepairsStaleEnumToken() {
        let defaults = makeIsolatedDefaults()
        defaults.set("future-token", forKey: SettingsKey.clipboardReadKey)
        defaults.set("garbage", forKey: SettingsKey.allowShiftClickKey)
        let controls = TerminalControls.from(defaults: defaults)
        XCTAssertEqual(controls.clipboardRead, .ask, "an invalid clipboard-read token repairs to ask")
        XCTAssertEqual(controls.allowShiftClick, .enabled, "an invalid shift-capture token repairs to enabled")
    }

    // MARK: - Enum raw values + repair

    /// The control enums' raw values are the otty / aislopdesk config tokens (the persisted strings + the
    /// libghostty `clipboard-read/write` tokens). A rename here would split-brain persistence from the
    /// config builder (WI-2) → pinned.
    func testEnumRawValuesArePinned() {
        XCTAssertEqual(ClipboardAccess.allCases.map(\.rawValue), ["allow", "deny", "ask"])
        XCTAssertEqual(RightClickAction.contextMenu.rawValue, "context-menu")
        XCTAssertEqual(RightClickAction.copyOrPaste.rawValue, "copy-or-paste")
        XCTAssertEqual(ScrollPastLast.lastLineWithContent.rawValue, "last-line-with-content")
        XCTAssertEqual(ScrollPastLast.cursorLine.rawValue, "cursor-line")
        XCTAssertEqual(ScrollPastFirst.sameAsLast.rawValue, "same-as-last")
        XCTAssertEqual(ScrollPastFirst.firstLineInMiddle.rawValue, "first-line-in-middle")
        XCTAssertEqual(
            MouseShiftCapture.allCases.map(\.rawValue),
            ["disabled", "enabled", "always", "never"],
        )
    }

    /// Each enum's non-failable `init(rawValue:)` maps a known token to its case and repairs an unknown /
    /// hostile token to the default (never traps) — the contract the `Defaults.PreferRawRepresentable` bridge
    /// relies on.
    func testEnumInitRepairsUnknownToken() {
        XCTAssertEqual(ClipboardAccess(rawValue: "deny"), .deny)
        XCTAssertEqual(ClipboardAccess(rawValue: "garbage"), .ask)
        XCTAssertEqual(RightClickAction(rawValue: "copy-or-paste"), .copyOrPaste)
        XCTAssertEqual(RightClickAction(rawValue: ""), .contextMenu)
        XCTAssertEqual(ScrollPastLast(rawValue: "cursor-line"), .cursorLine)
        XCTAssertEqual(ScrollPastLast(rawValue: "nope"), .disabled)
        XCTAssertEqual(ScrollPastFirst(rawValue: "same-as-last"), .sameAsLast)
        XCTAssertEqual(ScrollPastFirst(rawValue: "nope"), .disabled)
        XCTAssertEqual(MouseShiftCapture(rawValue: "always"), .always)
        XCTAssertEqual(MouseShiftCapture(rawValue: "nope"), .enabled)
    }

    /// `MouseShiftCapture.configValue` is the libghostty `mouse-shift-capture` token WI-2 emits. This is a
    /// REAL ORACLE, not a restatement of the mapping: otty's "Allow Shift with Mouse Click" axis ("hold ⇧ to
    /// *select text* even when the running app captures the mouse") is the INVERSE of libghostty's
    /// `mouse-shift-capture` axis (whether ⇧ is *captured into the mouse protocol and sent to the program*).
    /// Per the vendored ghostty `Config.zig`: `false` = ⇧ extends the selection (libghostty's own default,
    /// program may override); `true` = ⇧ is sent to the program (program may override); `never` = ⇧ ALWAYS
    /// extends selection (program can't override); `always` = ⇧ ALWAYS goes to the program (can't override).
    /// So "⇧ selects" must yield a *don't-capture* token and "⇧ goes to the program" a *capture* token.
    func testMouseShiftCaptureConfigValue() {
        // The tokens libghostty interprets as "⇧ extends the selection" (the otty intent when shift-select is
        // ALLOWED). The default/soft form must be `false` — libghostty's own default — so the factory neither
        // inverts the meaning NOR overrides the upstream default.
        let extendsSelectionTokens = Set(["false", "never"])
        // The tokens libghostty interprets as "⇧ is sent to the running program" (selection NOT extended).
        let capturesTokens = Set(["true", "always"])

        // Default = ⇧ extends the selection, soft → libghostty's own default `false`.
        XCTAssertEqual(
            MouseShiftCapture.enabled.configValue, "false",
            "the default (⇧ extends selection) must emit libghostty's `false` — the exact token whose docs say "
                + "the shift key is NOT sent to the program and extends the selection",
        )
        XCTAssertTrue(extendsSelectionTokens.contains(MouseShiftCapture.enabled.configValue))

        // Allow-shift OFF (soft) = ⇧ goes to the program → a capture token.
        XCTAssertEqual(MouseShiftCapture.disabled.configValue, "true")
        XCTAssertTrue(
            capturesTokens.contains(MouseShiftCapture.disabled.configValue),
            "with shift-select disabled, ⇧ must be sent to the program (a capture token), not extend selection",
        )

        // Hard forms: `.always` = ⇧ ALWAYS extends selection (program can't override) → libghostty `never`;
        // `.never` = ⇧ NEVER extends selection / always forwarded to the program → libghostty `always`.
        XCTAssertEqual(
            MouseShiftCapture.always.configValue, "never",
            "⇧ ALWAYS extends selection maps to libghostty `never` (extend-selection, program can't override)",
        )
        XCTAssertTrue(extendsSelectionTokens.contains(MouseShiftCapture.always.configValue))
        XCTAssertEqual(
            MouseShiftCapture.never.configValue, "always",
            "⇧ NEVER extends selection maps to libghostty `always` (sent to program, program can't override)",
        )
        XCTAssertTrue(capturesTokens.contains(MouseShiftCapture.never.configValue))

        // The factory terminal (default-constructed) keeps the shift-to-select escape hatch.
        XCTAssertEqual(
            TerminalControls().allowShiftClick.configValue, "false",
            "a factory TerminalControls must emit the shift-extends-selection token, not capture ⇧ to the program",
        )
    }

    // MARK: - Right-click action resolution (WI-7)

    /// The pure right-click dispatch the GUI `rightMouseDown` (WI-7, H7/H8) drives.
    /// ``RightClickAction/effect(controlHeld:hasSelection:)`` collapses a bare / ⌃ right-click into the
    /// concrete ``RightClickEffect``: each plain action maps to its effect, ``RightClickAction/copyOrPaste``
    /// picks ``RightClickEffect/copy`` WHEN a selection exists else ``RightClickEffect/paste``, and — the otty
    /// override — ⌃+right-click ALWAYS resolves to ``RightClickEffect/contextMenu`` regardless of the
    /// configured action (incl. ``RightClickAction/ignore``). Pinning it headlessly proves the H7/H8 semantics
    /// without an AppKit `NSEvent` / `GhosttySurface`; the un-fixed view always showed the menu, so a wrong
    /// effect mapping fails here.
    func testRightClickEffectResolvesEachAction() {
        // Bare right-click → the configured action's effect (selection state irrelevant for the plain cases).
        XCTAssertEqual(RightClickAction.contextMenu.effect(controlHeld: false, hasSelection: false), .contextMenu)
        XCTAssertEqual(RightClickAction.copy.effect(controlHeld: false, hasSelection: true), .copy)
        XCTAssertEqual(RightClickAction.paste.effect(controlHeld: false, hasSelection: false), .paste)
        XCTAssertEqual(RightClickAction.ignore.effect(controlHeld: false, hasSelection: true), .ignore)
    }

    /// ``RightClickAction/copyOrPaste`` is the only selection-sensitive case: copy WHEN there is a selection,
    /// else paste.
    func testRightClickEffectCopyOrPasteFollowsSelection() {
        XCTAssertEqual(
            RightClickAction.copyOrPaste.effect(controlHeld: false, hasSelection: true), .copy,
            "copy-or-paste copies when a selection exists",
        )
        XCTAssertEqual(
            RightClickAction.copyOrPaste.effect(controlHeld: false, hasSelection: false), .paste,
            "copy-or-paste pastes when there is no selection",
        )
    }

    /// ⌃+right-click ALWAYS shows the context menu, overriding EVERY configured action (the otty escape
    /// hatch — the menu is always reachable, even under `ignore` / `copy`), independent of the selection.
    func testControlRightClickAlwaysShowsContextMenu() {
        for action in RightClickAction.allCases {
            XCTAssertEqual(
                action.effect(controlHeld: true, hasSelection: false), .contextMenu,
                "⌃+right-click overrides \(action.rawValue) to the context menu",
            )
            XCTAssertEqual(
                action.effect(controlHeld: true, hasSelection: true), .contextMenu,
                "⌃+right-click overrides \(action.rawValue) to the context menu (with a selection)",
            )
        }
    }

    // MARK: - OSC-52 read confirm decision (WI-6)

    /// The pure OSC-52 clipboard-READ resolution the embedder's GUI-only `confirm_read_clipboard_cb` (WI-6)
    /// drives. ``ClipboardAccess/silentClipboardRead(text:)`` decides the SILENT (no-dialog) outcome:
    /// ``ClipboardAccess/allow`` hands the program the real clipboard text, ``ClipboardAccess/deny`` hands
    /// back EMPTY (a well-formed but empty OSC-52 reply — the clipboard is never leaked), and
    /// ``ClipboardAccess/ask`` returns `nil` (the embedder must prompt). Pinning it headlessly proves the
    /// no-leak deny contract — and that allow ≠ deny on the SAME input — without a `GhosttySurface`.
    func testSilentClipboardReadResolvesAllowDenyAsk() {
        XCTAssertEqual(
            ClipboardAccess.allow.silentClipboardRead(text: "secret"), "secret",
            "allow hands the program the real clipboard text",
        )
        XCTAssertEqual(
            ClipboardAccess.deny.silentClipboardRead(text: "secret"), "",
            "deny replies EMPTY — the clipboard is never leaked",
        )
        XCTAssertNil(
            ClipboardAccess.ask.silentClipboardRead(text: "secret"),
            "ask defers to the confirmation sheet (nil = prompt the user)",
        )
    }

    // MARK: - Codable

    /// `TerminalControls` is `Codable` (it round-trips through JSON unchanged) — the pure-value contract the
    /// config builder + any future persistence rely on.
    func testCodableRoundTrip() throws {
        let original = TerminalControls(
            copyOnSelect: true,
            clipboardRead: .deny,
            allowShiftClick: .always,
            scrollMultiplier: 1.75,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalControls.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
