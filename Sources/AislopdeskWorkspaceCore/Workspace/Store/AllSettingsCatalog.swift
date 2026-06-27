import Foundation

// MARK: - AllSettingsCatalog (headless source for the Advanced "All Settings" list — E7 WI-3)

/// The pure, headless catalog the Advanced → **All Settings** list iterates (otty's
/// `customization__advanced-settings.md`). It enumerates every client-side configuration key aislopdesk
/// understands — the orphan + new fire-time `SettingsKey` toggles, the Shell/General pickers, and the
/// typed-model render fields (font / cursor / theme) that have a richer dedicated tab — together with the
/// metadata each row renders: a monospace `key`, a human `label`, a short `description`, the `defaultText`,
/// the rendering `bucket`, and a free-text `keywords` blob the search field matches.
///
/// PURE / no SwiftUI: this lives in `AislopdeskWorkspaceCore` so `AllSettingsCatalogTests` can pin the
/// filter, the full-coverage anti-drift, and the buckets with NO view. The view layer
/// (`AllSettingsListView`) owns the actual `Defaults.Key` bindings + the cross-tab jump; this only describes
/// WHAT to render, never HOW.
///
/// GOLDEN-SAFE: the catalog is metadata only — it never reads/writes a value, never touches the wire codecs
/// or the env overlay. The `key` strings reuse the ``SettingsKey`` namespace constants (the one source of
/// truth) so a rename that would split-brain the list from the fire-sites fails the catalog tests.
public enum AllSettingsCatalog {
    /// One row in the All Settings list.
    public struct SettingEntry: Equatable, Identifiable, Sendable {
        /// How the row is edited — the otty distinction between an inline-editable expert key and a key with
        /// a richer dedicated tab control.
        public enum Bucket: Equatable, Sendable {
            /// No richer tab UI (or a simple flag) — render an INLINE control (toggle / stepper / picker)
            /// bound to the key. Edits apply live, identical to hand-editing the config.
            ///
            /// NOTE: this bucket is a pure RENDERING hint for the All-Settings list ("inline editor vs
            /// jump-to-tab button") — it is NOT a "reset bucket". Many `.advancedOnly`-rendered keys (e.g.
            /// `copyOnSelect`, `oscNotifications`, `hideStatusBar`) ALSO have a dedicated tab and are
            /// therefore tab-reachable, so they are PRESERVED by ``PreferencesStore/resetAdvancedOnly()``.
            /// Do not conflate "rendered inline here" with "is an advanced-only key" — the reset scope lives
            /// in ``PreferencesStore``, not in this bucket.
            case advancedOnly
            /// A richer control lives on a dedicated tab — render the current value + a ✎ button that jumps
            /// to that tab (the destination is ``SettingEntry/targetSection``).
            case hasDedicatedTab
        }

        /// The monospace config key shown in the row (an aislopdesk ``SettingsKey`` constant, or an
        /// otty-style render-pref name like `font-family` for a typed-model field).
        public let key: String
        /// The human-readable label (search-matched).
        public let label: String
        /// A one-line description (search-matched; rendered gray beneath the key).
        public let description: String
        /// The default value rendered as `· Default: …` after the description.
        public let defaultText: String
        /// Whether the row is inline-editable or jumps to a dedicated tab.
        public let bucket: Bucket
        /// For ``Bucket/hasDedicatedTab``: the `SettingsSection` rawValue to jump to (e.g. `"editor"`). `nil`
        /// for ``Bucket/advancedOnly`` (kept as a String so this headless catalog never imports the UI's
        /// `SettingsSection`).
        public let targetSection: String?
        /// Extra free-text the search field matches against (synonyms not in the label/description).
        public let keywords: String

        public var id: String { key }

        public init(
            key: String,
            label: String,
            description: String,
            defaultText: String,
            bucket: Bucket,
            targetSection: String? = nil,
            keywords: String = "",
        ) {
            self.key = key
            self.label = label
            self.description = description
            self.defaultText = defaultText
            self.bucket = bucket
            self.targetSection = targetSection
            self.keywords = keywords
        }
    }

    /// Every client-side configuration key, in a readable section order (General → Shell → Controls →
    /// Editor → Appearance → Agents, then the typed render fields). The list is the single source the All
    /// Settings view iterates; `AllSettingsCatalogTests.testCatalogCoversEveryClientSettingsKey` pins that no
    /// surfaced ``SettingsKey`` is dropped.
    public static let entries: [SettingEntry] = [
        // MARK: General

        SettingEntry(
            key: SettingsKey.onLaunchKey,
            label: "On Launch",
            description: "Restore the last session or open a fresh window when the app starts.",
            defaultText: "Restore Last Session",
            bucket: .advancedOnly,
            keywords: "launch startup restore session new window open",
        ),
        SettingEntry(
            key: SettingsKey.redactSecrets,
            label: "Redact Secrets",
            description: "Mask likely secrets in window titles and notification bodies.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "privacy secret redact mask token password api key",
        ),
        SettingEntry(
            key: SettingsKey.defaultPaneKindKey,
            label: "Default Pane Kind",
            description: "The kind used when opening a generic new pane.",
            defaultText: "Terminal",
            bucket: .advancedOnly,
            keywords: "pane kind terminal gui remote default new",
        ),
        SettingEntry(
            key: SettingsKey.closeConfirmTabKey,
            label: "Close Confirmation · Tab",
            description: "When to confirm before closing a tab or pane.",
            defaultText: "Running Process",
            bucket: .advancedOnly,
            keywords: "close confirm tab pane prompt quit running process always",
        ),
        SettingEntry(
            key: SettingsKey.closeConfirmWindowKey,
            label: "Close Confirmation · Window",
            description: "When to confirm before closing a window.",
            defaultText: "Running Process",
            bucket: .advancedOnly,
            keywords: "close confirm window prompt quit running process always",
        ),

        // MARK: Shell (notifications — notification-setting.png — + working directory — window-tab-split spec)

        SettingEntry(
            key: SettingsKey.oscNotifications,
            label: "Explicit Notifications",
            description: "Post OSC 9 / OSC 777 notifications emitted by the terminal.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification osc bell alert badge shell",
        ),
        SettingEntry(
            key: SettingsKey.longCommandNotifications,
            label: "Long-Command Notification",
            description: "Notify when a long-running command finishes in an unfocused pane.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "notification command complete long running done shell",
        ),
        SettingEntry(
            key: SettingsKey.workingDirectoryNewWindowKey,
            label: "Working Directory · New Window",
            description: "Where a new window opens — the home directory or the active pane's directory.",
            defaultText: "Home Directory",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder window home inherit same",
        ),
        SettingEntry(
            key: SettingsKey.workingDirectoryNewTabKey,
            label: "Working Directory · New Tab",
            description: "Where a new tab opens — the home directory or the active pane's directory.",
            defaultText: "Same as Current",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder tab home inherit same",
        ),
        SettingEntry(
            key: SettingsKey.workingDirectoryNewSplitKey,
            label: "Working Directory · New Split",
            description: "Where a new split opens — the home directory or the active pane's directory.",
            defaultText: "Same as Current",
            bucket: .advancedOnly,
            keywords: "working directory cwd folder split home inherit same",
        ),

        // MARK: Controls (copy / paste / mouse / scroll fire-time flags — E8 owns the behaviour)

        SettingEntry(
            key: SettingsKey.copyOnSelect,
            label: "Copy on Select",
            description: "Copy the selection to the pasteboard as soon as it is made.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "copy select clipboard pasteboard mouse selection",
        ),
        SettingEntry(
            key: SettingsKey.trimTrailingSpacesOnCopy,
            label: "Trim Trailing Spaces on Copy",
            description: "Strip trailing whitespace from each copied line.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "copy trim trailing whitespace space clipboard",
        ),
        SettingEntry(
            key: SettingsKey.pasteProtection,
            label: "Paste Protection",
            description: "Warn before pasting text that contains a newline or control character.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "paste protection clipboard safety bracketed newline",
        ),
        SettingEntry(
            key: SettingsKey.mouseHideWhileTyping,
            label: "Hide Mouse While Typing",
            description: "Hide the pointer while typing into a pane.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "mouse hide typing pointer",
        ),
        SettingEntry(
            key: SettingsKey.focusFollowsMouse,
            label: "Focus Follows Mouse",
            description: "Focus the pane the pointer is over without a click.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "focus follows mouse hover pane pointer",
        ),
        SettingEntry(
            key: SettingsKey.scrollOnOutput,
            label: "Scroll on Output",
            description: "Scroll the viewport to the bottom when new output arrives.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "scroll output bottom autoscroll follow",
        ),
        SettingEntry(
            key: SettingsKey.scrollMultiplier,
            label: "Scroll Multiplier",
            description: "Multiply the scroll-wheel delta.",
            defaultText: "1.00×",
            bucket: .advancedOnly,
            keywords: "scroll multiplier wheel speed mouse sensitivity",
        ),

        // E8 WI-1: the remaining Controls / Mouse / Scroll knobs (E8 owns the behaviour; declared here so
        // the Advanced list is complete and the keys round-trip today).
        SettingEntry(
            key: SettingsKey.clearSelectionOnTyping,
            label: "Clear Selection on Typing",
            description: "Clear the selection when the user starts typing.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "selection clear typing keyboard input",
        ),
        SettingEntry(
            key: SettingsKey.clearSelectionOnCopy,
            label: "Clear Selection on Copy",
            description: "Clear the selection after an explicit copy.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "selection clear copy clipboard",
        ),
        SettingEntry(
            key: SettingsKey.backspaceDeletesSelection,
            label: "Backspace Deletes Selection",
            description: "Not yet functional — the renderer exposes no selection-geometry API, so Backspace "
                + "deletes one character whether on or off.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "backspace delete selection prompt edit",
        ),
        SettingEntry(
            key: SettingsKey.shiftArrowSelect,
            label: "Shift+Arrow Select",
            description: "Use Shift+arrows to drive native selection instead of forwarding arrow escapes.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "shift arrow select selection keyboard extend",
        ),
        SettingEntry(
            key: SettingsKey.pasteBracketedSafe,
            label: "Paste Bracketed Safe",
            description: "Treat a bracketed paste as safe, skipping the warning when the program supports it.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "paste bracketed safe protection clipboard",
        ),
        SettingEntry(
            key: SettingsKey.clipboardReadKey,
            label: "Clipboard Read (OSC 52)",
            description: "Whether a program may READ the clipboard via OSC 52.",
            defaultText: "Ask",
            bucket: .advancedOnly,
            keywords: "clipboard read osc 52 access allow deny ask paste",
        ),
        SettingEntry(
            key: SettingsKey.clipboardWriteKey,
            label: "Clipboard Write (OSC 52)",
            description: "Whether a program may WRITE the clipboard via OSC 52.",
            defaultText: "Allow",
            bucket: .advancedOnly,
            keywords: "clipboard write osc 52 access allow deny ask copy",
        ),
        SettingEntry(
            key: SettingsKey.allowMouseCapture,
            label: "Allow Mouse Capture",
            description: "Allow shell apps to capture mouse events (e.g. vim, tmux).",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "mouse capture reporting vim tmux htop program",
        ),
        SettingEntry(
            key: SettingsKey.allowShiftClickKey,
            label: "Allow Shift with Mouse Click",
            description: "Hold Shift to select text even when the running app captures the mouse.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "shift mouse click capture selection bypass",
        ),
        SettingEntry(
            key: SettingsKey.clickToMove,
            label: "Cursor Click-to-Move",
            description: "Click in the prompt to move the shell cursor, across soft-wrapped rows.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "cursor click move prompt arrow keys soft wrap",
        ),
        SettingEntry(
            key: SettingsKey.rightClickActionKey,
            label: "Right-Click Action",
            description: "What right-click does in the viewport (Ctrl+right-click always opens the menu).",
            defaultText: "Context Menu",
            bucket: .advancedOnly,
            keywords: "right click action menu copy paste ignore mouse",
        ),
        SettingEntry(
            key: SettingsKey.scrollPastLastLineKey,
            label: "Scroll Past Last Line",
            description: "Overscroll mode past the last content row. Preference saved; the overscroll "
                + "rendering is deferred (the renderer owns the viewport).",
            defaultText: "Disabled",
            bucket: .advancedOnly,
            keywords: "scroll past last line overscroll bottom content",
        ),
        SettingEntry(
            key: SettingsKey.scrollPastFirstLineKey,
            label: "Scroll Past First Line",
            description: "Overscroll mode past the first (oldest) line of history. Preference saved; the "
                + "overscroll rendering is deferred (same renderer ceiling as Scroll Past Last).",
            defaultText: "Disabled",
            bucket: .advancedOnly,
            keywords: "scroll past first line overscroll top oldest history",
        ),
        SettingEntry(
            key: SettingsKey.smoothScroll,
            label: "Smooth Scroll",
            description: "Scrolling already runs at pixel granularity; the whole-row snap when off is "
                + "deferred (the renderer exposes no row-snap hook).",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "smooth scroll pixel gesture snap row",
        ),
        SettingEntry(
            key: SettingsKey.undoAtPrompt,
            label: "Undo at Prompt",
            description: "Press Cmd-Z at the shell prompt to emit the readline undo sequence.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "undo prompt readline command z edit",
        ),

        // E10 (Path/link detection — otty Settings → Controls → Open With / Link Schemes). Declared here so
        // the Advanced "All Settings" list is complete; E10 WI-5/6/8/9 own the behaviour.
        SettingEntry(
            key: SettingsKey.linkDetection,
            label: "Detect Links & Paths",
            description: "Detect paths and URLs in terminal output and underline them on Cmd-hover.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "link path url detect underline hover open clickable hyperlink osc 8",
        ),
        SettingEntry(
            key: SettingsKey.linkCmdClickKey,
            label: "Cmd-Click on Link",
            description: "What Cmd+click on a detected link does — open in the best handler, copy, or nothing.",
            defaultText: "Open",
            bucket: .advancedOnly,
            keywords: "link cmd click open copy nothing url path open with handler",
        ),
        SettingEntry(
            key: SettingsKey.linkCmdShiftClickKey,
            label: "Cmd-Shift-Click on Link",
            description: "What Cmd+Shift+click on a detected link does — reveal on the host, or open with the "
                + "system default.",
            defaultText: "Reveal in Finder",
            bucket: .advancedOnly,
            keywords: "link cmd shift click reveal finder open system default host",
        ),
        SettingEntry(
            key: SettingsKey.autoDetectLinkSchemesKey,
            label: "Auto-Detect Link Schemes",
            description: "Which URL schemes are underlined and clickable. All detects any scheme://; Custom "
                + "restricts to your list. http(s), file, and mailto are always detected.",
            defaultText: "All",
            bucket: .advancedOnly,
            keywords: "link scheme url detect custom all http https file mailto codex ssh vscode",
        ),
        SettingEntry(
            key: SettingsKey.customLinkSchemes,
            label: "Custom Link Schemes",
            description: "Extra URL schemes to detect when Auto-Detect is set to Custom (e.g. codex, ssh, "
                + "vscode).",
            defaultText: "None",
            bucket: .advancedOnly,
            keywords: "custom link scheme url codex ssh vscode additional detect",
        ),
        SettingEntry(
            key: SettingsKey.systemDialogPanes,
            label: "System Dialog Panes",
            description: "Auto-spawn a pane for system password / security dialogs.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "system dialog password security pane spawn authorization",
        ),

        // MARK: Appearance (New Tab Position + chrome orphan toggles)

        // otty homes New Tab Position under **Appearance** in a TABS group (`tab-setting.png`), NOT Shell.
        SettingEntry(
            key: SettingsKey.newTabPositionKey,
            label: "New Tab Position",
            description: "Where a new tab is inserted in the active session's tab bar.",
            defaultText: "Automatic",
            bucket: .advancedOnly,
            keywords: "tab position new placement order end after current appearance",
        ),
        SettingEntry(
            key: SettingsKey.showBlockDividers,
            label: "Show Command Dividers",
            description: "Show the per-block sticky command header over terminal panes.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "block divider command header terminal sticky shell",
        ),
        SettingEntry(
            key: SettingsKey.hideStatusBar,
            label: "Hide Status Bar",
            description: "Hide the bottom pane status bar so the chrome recedes.",
            defaultText: "Off",
            bucket: .advancedOnly,
            keywords: "status bar hide chrome appearance bottom strip",
        ),

        // MARK: Agents behaviour toggles

        SettingEntry(
            key: SettingsKey.autoSwitchLayouts,
            label: "Auto-Switch Layouts",
            description: "Switch to a layout when its trigger app launches on the host.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "layout switch trigger app auto agent",
        ),
        SettingEntry(
            key: SettingsKey.recordClipboardHistory,
            label: "Record Clipboard History",
            description: "Archive copied text into the clipboard-history ring.",
            defaultText: "On",
            bucket: .advancedOnly,
            keywords: "clipboard history record paste recent ring",
        ),

        // MARK: Typed render fields with a richer dedicated tab (jump-to-tab)

        // otty homes (proven by the screenshots): FONT FAMILY + the CURSOR group live under **Appearance**
        // (`docs/otty-clone/screenshots/font-setting.png`, `cursor-style.png`); SCROLLBACK lives under
        // **Controls → Scroll** (`spec/terminal-features__scroll.md`). otty's Editor section is the built-in
        // file-editor's settings, which aislopdesk has no equivalent for, so nothing routes there.
        SettingEntry(
            key: "font-family",
            label: "Font Family",
            description: "The terminal font family.",
            defaultText: "SF Mono",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "font family typeface monospace appearance",
        ),
        SettingEntry(
            key: "font-size",
            label: "Font Size",
            description: "The terminal font point size.",
            defaultText: "13",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "font size point appearance zoom",
        ),
        SettingEntry(
            key: "scrollback-limit",
            label: "Scrollback Lines",
            description: "The terminal scrollback buffer size, in lines.",
            defaultText: "10000",
            bucket: .hasDedicatedTab,
            targetSection: "controls",
            keywords: "scrollback lines buffer history controls scroll",
        ),
        SettingEntry(
            key: "cursor-style",
            label: "Cursor Style",
            description: "The terminal cursor style.",
            defaultText: "Block",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "cursor style block hollow bar underline appearance",
        ),
        SettingEntry(
            key: "cursor-style-blink",
            label: "Cursor Blink",
            description: "Whether the terminal cursor blinks. Default defers to DEC mode 12.",
            defaultText: "Default",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "cursor blink appearance",
        ),
        SettingEntry(
            key: "theme",
            label: "Theme",
            description: "The client chrome and terminal colour theme.",
            defaultText: "System",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "theme appearance colour color palette monokai dark light",
        ),
        SettingEntry(
            key: SettingsKey.density,
            label: "Density",
            description: "The UI density tier.",
            defaultText: "Comfortable",
            bucket: .hasDedicatedTab,
            targetSection: "appearance",
            keywords: "density appearance compact comfortable spacing tier",
        ),
    ]

    /// Filter the catalog by a search query, matching (case-insensitively) against the key, label,
    /// description, and keywords — the faithful clone of otty's "matching against key name, label,
    /// description, and keywords" (a substring filter, not fuzzy; the spec narrows on `cursor` / `scrollback`
    /// / `blink`). An empty / whitespace query returns ALL entries (order-preserving); a no-match query
    /// returns `[]`.
    public static func filter(_ query: String) -> [SettingEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.key.lowercased().contains(needle)
                || entry.label.lowercased().contains(needle)
                || entry.description.lowercased().contains(needle)
                || entry.keywords.lowercased().contains(needle)
        }
    }
}
