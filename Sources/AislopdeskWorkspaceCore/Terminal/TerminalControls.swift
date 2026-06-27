import Defaults
import Foundation

// MARK: - E8 terminal-control enums (the otty Controls / Mouse / Scroll multi-state knobs)

/// A clipboard-access decision for the OSC-52 read/write gates (otty `clipboard-read` /
/// `clipboard-write`, libghostty `allow` / `deny` / `ask`).
///
/// - ``allow``: silently honour the program's request.
/// - ``deny``: silently refuse it.
/// - ``ask``: surface the confirmation sheet (the OSC-52 "Ask" path — WI-6 reuses the paste-protection
///   surface with different copy).
///
/// PURE `String`-raw + `CaseIterable` so it bridges to `Defaults` (see `SettingsKey`) and the Advanced
/// access pickers can enumerate it. The raw values match the libghostty config tokens 1:1, so the
/// config builder (WI-2) emits ``RawValue`` directly. ``init(rawValue:)`` is validate-then-repair (a
/// stale / hostile persisted string falls back to ``ask`` rather than trapping) — the same non-failable
/// shape as ``CloseConfirmationPolicy/init(rawValue:)`` so the `Defaults.PreferRawRepresentable` bridge
/// keeps working.
public enum ClipboardAccess: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
    case ask

    /// Decodes the persisted access token. Validate-then-repair: a recognised raw value maps to its case;
    /// anything else repairs to ``ask`` (the conservative gate) rather than trapping. Non-failable so it
    /// satisfies `RawRepresentable` without ever returning `nil` (the bridge relies on this).
    public init(rawValue: String) {
        switch rawValue {
        case "allow": self = .allow
        case "deny": self = .deny
        case "ask": self = .ask
        default: self = .ask
        }
    }

    /// The SILENT (no-dialog) resolution of an OSC-52 clipboard-READ request gated by this access, as the
    /// text the embedder hands `completeClipboardRead(_:confirmed: true)` (WI-6, GUI-only). ``allow`` returns
    /// the real clipboard `text`; ``deny`` returns `""` — a well-formed but EMPTY OSC-52 reply that frees the
    /// request without leaking the clipboard (and, paired with `confirmed: true`, never re-trips libghostty's
    /// read gate, which a `confirmed: false` completion recurses on — the read contract differs from a
    /// paste's). ``ask`` returns `nil`: the embedder must surface the confirmation sheet and map the user's
    /// verdict to the same allow (`text`) / deny (`""`).
    ///
    /// PURE so the embedder's GUI-only `confirm_read_clipboard_cb` routing is unit-pinned without a surface.
    public func silentClipboardRead(text: String) -> String? {
        switch self {
        case .allow: text
        case .deny: ""
        case .ask: nil
        }
    }
}

/// What a bare right-click does in the terminal viewport (otty `mouse.rightClickAction`). ⌃+right-click
/// always shows the context menu regardless of this setting (handled at the GUI site, WI-7).
///
/// - ``contextMenu``: show the native context menu (the default).
/// - ``copy``: copy the current selection.
/// - ``paste``: paste the clipboard.
/// - ``copyOrPaste``: copy if there is a selection, otherwise paste.
/// - ``ignore``: do nothing.
///
/// PURE `String`-raw + `CaseIterable`; this is a CLIENT-side dispatch (no libghostty config key), so the
/// raw values are aislopdesk's own kebab-case persistence tokens. ``init(rawValue:)`` is
/// validate-then-repair to ``contextMenu``.
public enum RightClickAction: String, Codable, Sendable, CaseIterable {
    case contextMenu = "context-menu"
    case copy
    case paste
    case copyOrPaste = "copy-or-paste"
    case ignore

    /// Decodes the persisted action token, repairing a stale / hostile value to ``contextMenu`` (the
    /// default) rather than trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "context-menu": self = .contextMenu
        case "copy": self = .copy
        case "paste": self = .paste
        case "copy-or-paste": self = .copyOrPaste
        case "ignore": self = .ignore
        default: self = .contextMenu
        }
    }

    // NOTE: the LIVE bare-right-click dispatch is owned END-TO-END by libghostty — the config builder (WI-2)
    // emits this action's ``rawValue`` as `right-click-action`, so the surface itself performs Copy / Paste /
    // Copy-or-Paste / Ignore / Context-Menu (1:1 with otty, which is ghostty-based). That avoids the GUI
    // re-reading `hasSelection()` AFTER libghostty has already word-selected under the cursor (the WI-7 race).
    // The GUI view (`rightMouseDown`, compile-only behind `#if canImport(CGhostty)`) enforces ONLY the
    // ⌃-right-always-menu override inline; there is no client-side effect model left to keep in sync.
}

/// Overscroll behaviour past the LAST line of content (otty "Scroll Past Last Line", default Disabled).
/// Automatically suppressed on the alternate screen (the policy that consumes this — `ScrollPastPolicy`,
/// WI-12 — returns `nil` there so full-screen TUIs keep their bottom edge).
///
/// - ``disabled``: clamp at the buffer bottom (the default).
/// - ``lastLineWithContent``: the bottom-most content row lands at the viewport top.
/// - ``lastLineInMiddle``: that row lands at the vertical centre.
/// - ``cursorLine``: the cursor row lands at the top, even if it is on a blank line.
///
/// PURE `String`-raw + `CaseIterable`; a CLIENT-side render policy (no libghostty key). ``init(rawValue:)``
/// is validate-then-repair to ``disabled``.
public enum ScrollPastLast: String, Codable, Sendable, CaseIterable {
    case disabled
    case lastLineWithContent = "last-line-with-content"
    case lastLineInMiddle = "last-line-in-middle"
    case cursorLine = "cursor-line"

    /// Decodes the persisted mode token, repairing a stale / hostile value to ``disabled`` (clamp) rather
    /// than trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "last-line-with-content": self = .lastLineWithContent
        case "last-line-in-middle": self = .lastLineInMiddle
        case "cursor-line": self = .cursorLine
        default: self = .disabled
        }
    }
}

/// Overscroll behaviour past the FIRST (oldest) line of scrollback (otty "Scroll Past First Line", default
/// Disabled). Symmetric with ``ScrollPastLast``.
///
/// - ``disabled``: clamp at the scrollback top (the default).
/// - ``sameAsLast``: mirror the ``ScrollPastLast`` setting (only one knob to tune).
/// - ``firstLineWithContent``: the topmost history row lands at the viewport bottom.
/// - ``firstLineInMiddle``: that row lands at the vertical centre.
///
/// PURE `String`-raw + `CaseIterable`; a CLIENT-side render policy (no libghostty key). ``init(rawValue:)``
/// is validate-then-repair to ``disabled``.
public enum ScrollPastFirst: String, Codable, Sendable, CaseIterable {
    case disabled
    case sameAsLast = "same-as-last"
    case firstLineWithContent = "first-line-with-content"
    case firstLineInMiddle = "first-line-in-middle"

    /// Decodes the persisted mode token, repairing a stale / hostile value to ``disabled`` (clamp) rather
    /// than trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "same-as-last": self = .sameAsLast
        case "first-line-with-content": self = .firstLineWithContent
        case "first-line-in-middle": self = .firstLineInMiddle
        default: self = .disabled
        }
    }
}

/// Whether ⇧+click / ⇧+drag bypasses a program's mouse capture to make a native selection (otty "Allow
/// Shift with Mouse Click", libghostty `mouse-shift-capture`).
///
/// - ``disabled``: never bypass (program always captures).
/// - ``enabled``: ⇧ bypasses capture for that one gesture (the default).
/// - ``always``: ⇧ is always consumed for selection.
/// - ``never``: ⇧ is never consumed for selection (always forwarded to the program).
///
/// PURE `String`-raw + `CaseIterable`. The persisted raw values are aislopdesk's own semantic tokens; the
/// libghostty config token (`false` / `true` / `always` / `never`) is exposed separately as ``configValue``
/// so persistence stays readable while the config builder (WI-2) emits the libghostty form.
/// ``init(rawValue:)`` is validate-then-repair to ``enabled`` (the default).
public enum MouseShiftCapture: String, Codable, Sendable, CaseIterable {
    case disabled
    case enabled
    case always
    case never

    /// Decodes the persisted token, repairing a stale / hostile value to ``enabled`` (the default) rather
    /// than trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "disabled": self = .disabled
        case "enabled": self = .enabled
        case "always": self = .always
        case "never": self = .never
        default: self = .enabled
        }
    }

    /// The libghostty `mouse-shift-capture` config token this case maps to. Consumed by the config builder
    /// (WI-2); kept here so the libghostty representation lives next to the enum and is unit-pinned.
    ///
    /// **The mapping is INVERTED on purpose** because otty's user-facing axis ("Allow Shift with Mouse
    /// Click" = "hold ⇧ to *select text* even when the running app captures the mouse") is the *opposite*
    /// of libghostty's `mouse-shift-capture` axis, which asks the reverse question — whether ⇧ is *captured
    /// into the mouse protocol and sent to the program*. Per the vendored ghostty `Config.zig` docs:
    /// `false` = ⇧ is NOT sent to the program and EXTENDS THE SELECTION (libghostty's own default, program
    /// may override via `XTSHIFTESCAPE`); `true` = ⇧ IS sent to the program (program may override); `never`
    /// = same as `false` but the program CANNOT override (⇧ always extends selection); `always` = same as
    /// `true` but the program CANNOT override (⇧ always goes to the program). So "⇧ selects" (otty ON) maps
    /// to libghostty's *don't-capture* tokens and "⇧ goes to the program" (otty OFF) maps to its *capture*
    /// tokens:
    ///
    /// - ``enabled`` (default — ⇧ extends selection, soft) → `false` — and libghostty's own default is
    ///   `false`, so the factory terminal honours, rather than overrides, the upstream default.
    /// - ``disabled`` (⇧ goes to the program, soft) → `true`.
    /// - ``always`` (⇧ ALWAYS extends selection, program can't override) → `never`.
    /// - ``never`` (⇧ NEVER extends selection / always forwarded to the program) → `always`.
    public var configValue: String {
        switch self {
        case .disabled: "true"
        case .enabled: "false"
        case .always: "never"
        case .never: "always"
        }
    }

    /// Whether ⇧ EXTENDS THE SELECTION — the ON state of otty's binary "Allow Shift with Mouse Click" switch.
    /// The Settings UI surfaces this leaf as a simple ON/OFF toggle (not the 4-way enum), so a value persisted
    /// by the removed 4-way picker must project onto that binary axis: ``enabled`` / ``always`` (soft / hard
    /// "⇧ extends selection") read ON; ``disabled`` / ``never`` (soft / hard "⇧ goes to the program") read OFF.
    /// Without this a stale ``always`` would mis-read as OFF against a bare `== .enabled` check.
    public var extendsSelection: Bool {
        switch self {
        case .enabled,
             .always: true
        case .disabled,
             .never: false
        }
    }
}

// MARK: - E10 link-interaction enums (otty Settings → Controls → Open With / Link Schemes)

/// What a `⌘`click on a detected link / path does (otty `link-cmd-click`, default ``open``).
///
/// - ``open``: open in the best handler — a file / folder opens or reveals on the HOST (over the E4
///   metadata RPC, E10 WI-7), a URL opens in the client's system browser.
/// - ``copy``: copy the resolved absolute path / URL to the client pasteboard.
/// - ``nothing``: do nothing on ⌘click (the user reaches links via the right-click menu / Jump-To /
///   Hint Mode instead) — otty's escape hatch when ⌘click conflicts with a TUI.
///
/// PURE `String`-raw + `CaseIterable`; a CLIENT-side dispatch token (no libghostty config key), so the raw
/// values are aislopdesk's own / otty's persistence tokens. ``init(rawValue:)`` is validate-then-repair to
/// ``open`` (the default) — the same non-failable shape as ``RightClickAction`` so the
/// `Defaults.PreferRawRepresentable` bridge keeps working.
public enum LinkCmdClick: String, Codable, Sendable, CaseIterable {
    case open
    case copy
    case nothing

    /// Decodes the persisted token, repairing a stale / hostile value to ``open`` (the default) rather than
    /// trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "copy": self = .copy
        case "nothing": self = .nothing
        default: self = .open
        }
    }
}

/// What a `⌘⇧`click on a detected link / path does (otty `link-cmd-shift-click`, default ``revealFinder``).
///
/// - ``revealFinder``: reveal the path in the HOST Finder (the `open -R`-equivalent over the metadata RPC,
///   E10 WI-7); a URL has no Finder target, so the click copies it instead.
/// - ``openSystemDefault``: open the path / URL with the HOST's system-default handler.
///
/// PURE `String`-raw + `CaseIterable`; a CLIENT-side dispatch token. ``init(rawValue:)`` is
/// validate-then-repair to ``revealFinder`` (the default).
public enum LinkCmdShiftClick: String, Codable, Sendable, CaseIterable {
    case revealFinder = "reveal-finder"
    case openSystemDefault = "open-system-default"

    /// Decodes the persisted token, repairing a stale / hostile value to ``revealFinder`` (the default)
    /// rather than trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "reveal-finder": self = .revealFinder
        case "open-system-default": self = .openSystemDefault
        default: self = .revealFinder
        }
    }
}

/// Which URL schemes are auto-detected / underlined on `⌘`-hover (otty "Auto-Detect Link Schemes",
/// default ``all``). `http(s)`, `file`, and `mailto` are ALWAYS detected regardless of this mode (the
/// detector hard-codes them — see ``LinkSchemePolicy``); this only governs OTHER `scheme://…` forms.
///
/// - ``all``: detect ANY `scheme://…`.
/// - ``custom``: detect only the always-on schemes plus the user's ``SettingsKey/customLinkSchemes`` list.
///
/// PURE `String`-raw + `CaseIterable`; a CLIENT-side persistence token. ``init(rawValue:)`` is
/// validate-then-repair to ``all`` (the default). Bridged to the detector's richer ``LinkSchemePolicy`` by
/// ``SettingsKey/linkSchemePolicy``.
public enum AutoDetectLinkSchemes: String, Codable, Sendable, CaseIterable {
    case all
    case custom

    /// Decodes the persisted token, repairing a stale / hostile value to ``all`` (the default) rather than
    /// trapping. Non-failable so the `Defaults.PreferRawRepresentable` bridge works.
    public init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "custom": self = .custom
        default: self = .all
        }
    }
}

// MARK: - TerminalControls (the fire-time control bundle the config builder consumes)

/// The pure, headless bundle of E8 terminal CONTROL values the libghostty config builder (WI-2) turns into
/// `copy-on-select` / `clipboard-*` / `mouse-*` config lines (+ the ⇧+arrow `adjust_selection` keybinds).
/// It is the controls sibling of ``TerminalPreferences`` (render prefs) — the two are independent inputs to
/// `TerminalConfigBuilder.string(...)`, NOT nested: the builder emits the cursor color/opacity/text lines
/// straight from ``TerminalPreferences`` and the control lines from this struct.
///
/// Every field derives from a fire-time `Defaults.Keys` flag (declared in `SettingsKey`), so this bundle
/// never reaches the `EnvConfig` overlay or the `video-prefs.json` sidecar — golden-safe by construction,
/// exactly like the E7 stubs. ``from(defaults:)`` is the single read site (`PreferencesStore.applyTerminal`
/// rebuilds it on every apply / `refreshTerminalControls()`), so the defaults below mirror the
/// `Defaults.Keys` defaults and a default-constructed value is a faithful "factory" terminal.
///
/// PURE `Codable + Sendable + Equatable` — no SwiftUI, no AppKit — so `TerminalControlsTests` pins the
/// factory + the enum round-trips with no view.
public struct TerminalControls: Codable, Sendable, Equatable {
    /// otty `copy-on-select` — copy the selection to the pasteboard as soon as it is made (default OFF).
    /// The builder emits `clipboard` when on, `false` when off.
    public var copyOnSelect: Bool
    /// otty `clipboard-trim-trailing-spaces` — strip trailing whitespace from each copied line (default ON).
    public var trimTrailing: Bool
    /// otty `selection-clear-on-typing` — clear the selection when the user types (default ON).
    public var clearOnTyping: Bool
    /// otty `selection-clear-on-copy` — clear the selection after an explicit copy (default OFF).
    public var clearOnCopy: Bool
    /// otty `clipboard-paste-protection` — warn before pasting unsafe text (default ON).
    public var pasteProtection: Bool
    /// otty `clipboard-paste-bracketed-safe` — treat bracketed paste as safe (skips the warning when the
    /// program advertised `?2004h`) (default ON).
    public var bracketedSafe: Bool
    /// otty `clipboard-read` — the OSC-52 clipboard-READ access gate (default ``ClipboardAccess/ask``).
    public var clipboardRead: ClipboardAccess
    /// otty `clipboard-write` — the OSC-52 clipboard-WRITE access gate (default ``ClipboardAccess/allow``).
    public var clipboardWrite: ClipboardAccess
    /// otty `mouse-hide-while-typing` — hide the pointer while typing (default ON).
    public var hideMouseWhileTyping: Bool
    /// otty `mouse-shift-capture` — whether ⇧ bypasses a program's mouse capture for a native selection
    /// (default ``MouseShiftCapture/enabled``).
    public var allowShiftClick: MouseShiftCapture
    /// otty `cursor-click-to-move` — click in the prompt to move the shell cursor (default ON).
    public var clickToMove: Bool
    /// otty `mouse-reporting` — allow programs (vim, tmux, htop) to capture mouse events (default ON).
    public var allowMouseCapture: Bool
    /// otty `mouse.rightClickAction` (H7/H8) — what a bare right-click does in the viewport (default
    /// ``RightClickAction/contextMenu``). The config builder (WI-2) emits its `rawValue` as libghostty's
    /// `right-click-action` so libghostty owns the dispatch; the GUI view keeps only the ⌃-right-always-menu
    /// override.
    public var rightClickAction: RightClickAction
    /// otty "Shift+Arrow Select" — ⇧+arrows drive native selection (emits four `adjust_selection` keybinds)
    /// instead of forwarding the arrow escapes to the program (default ON).
    public var shiftArrowSelect: Bool
    /// otty `mouse-scroll-multiplier` — multiply the scroll-wheel delta (default `1.0`).
    public var scrollMultiplier: Double

    public init(
        copyOnSelect: Bool = false,
        trimTrailing: Bool = true,
        clearOnTyping: Bool = true,
        clearOnCopy: Bool = false,
        pasteProtection: Bool = true,
        bracketedSafe: Bool = true,
        clipboardRead: ClipboardAccess = .ask,
        clipboardWrite: ClipboardAccess = .allow,
        hideMouseWhileTyping: Bool = true,
        allowShiftClick: MouseShiftCapture = .enabled,
        clickToMove: Bool = true,
        allowMouseCapture: Bool = true,
        rightClickAction: RightClickAction = .contextMenu,
        shiftArrowSelect: Bool = true,
        scrollMultiplier: Double = 1.0,
    ) {
        self.copyOnSelect = copyOnSelect
        self.trimTrailing = trimTrailing
        self.clearOnTyping = clearOnTyping
        self.clearOnCopy = clearOnCopy
        self.pasteProtection = pasteProtection
        self.bracketedSafe = bracketedSafe
        self.clipboardRead = clipboardRead
        self.clipboardWrite = clipboardWrite
        self.hideMouseWhileTyping = hideMouseWhileTyping
        self.allowShiftClick = allowShiftClick
        self.clickToMove = clickToMove
        self.allowMouseCapture = allowMouseCapture
        self.rightClickAction = rightClickAction
        self.shiftArrowSelect = shiftArrowSelect
        self.scrollMultiplier = scrollMultiplier
    }

    /// Read the live control bundle from the persisted fire-time `Defaults.Keys` flags. The `defaults`
    /// parameter is read through the typed-key subscript (`defaults[.copyOnSelect]`), so an injected suite
    /// makes the factory test-isolatable while production passes `.standard` — the same idiom the
    /// `SettingsKey` accessors use, just routed through an explicit store for testability. Each missing key
    /// falls back to its `Defaults.Key` default (mirrored by this struct's init defaults).
    public static func from(defaults: UserDefaults = .standard) -> Self {
        // E14/K12: the "Clipboard — Shell Controlled" master switch (default ON) gates the WHOLE OSC-52 path
        // ahead of the per-direction Ask/Allow/Deny gate. When OFF, both read + write resolve to `.deny`, so
        // the config builder emits `clipboard-read/write = deny` and no remote OSC-52 ever reaches the gate.
        let clipboardShellControlled = defaults[.clipboardShellControlled]
        return Self(
            copyOnSelect: defaults[.copyOnSelect],
            trimTrailing: defaults[.trimTrailingSpacesOnCopy],
            clearOnTyping: defaults[.clearSelectionOnTyping],
            clearOnCopy: defaults[.clearSelectionOnCopy],
            pasteProtection: defaults[.pasteProtection],
            bracketedSafe: defaults[.pasteBracketedSafe],
            clipboardRead: clipboardShellControlled ? defaults[.clipboardRead] : .deny,
            clipboardWrite: clipboardShellControlled ? defaults[.clipboardWrite] : .deny,
            hideMouseWhileTyping: defaults[.mouseHideWhileTyping],
            allowShiftClick: defaults[.allowShiftClick],
            clickToMove: defaults[.clickToMove],
            allowMouseCapture: defaults[.allowMouseCapture],
            rightClickAction: defaults[.rightClickAction],
            shiftArrowSelect: defaults[.shiftArrowSelect],
            scrollMultiplier: defaults[.scrollMultiplier],
        )
    }
}
