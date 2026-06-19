import Foundation

// MARK: - WorkspaceAction (the tree-native command intent)

/// A tree-native workspace action — the intent the IDE-shell keyboard / menu / command-palette / cheat
/// sheet all produce, routed to the matching ``WorkspaceStore`` TREE op by ``WorkspaceBindingRegistry``
/// (docs/42 §W6). It is the `Session → Tab → Pane` redesign's command vocabulary, distinct from the
/// retained-but-dead canvas ``WorkspaceCommand`` (which the registry still routes to in `.canvas` mode):
/// the tree has split-right/down, tabs, and sessions the flat canvas never had.
///
/// A pure value enum (no SwiftUI / store import) so the chord → action mapping is fully unit-testable
/// with no view — exactly as ``WorkspaceCommand`` is.
public enum WorkspaceAction: Hashable, Sendable {
    // Panes
    case splitRight // ⌘D  — split the active pane into a side-by-side column
    case splitDown // ⌘⇧D — split the active pane into a stacked row
    case closePane // ⌘W  — close the active pane (cascades the tab/session)
    case renamePane // ⌘⇧R — rename the active TAB on the tree shell (opens its tab-strip inline field);
    // the active canvas pane on the retained-but-dead canvas path
    case breakPaneToTab // ⌃⌘T — eject the active pane into a new tab

    // Focus
    case focusLeft // ⌥⌘←
    case focusRight // ⌥⌘→
    case focusUp // ⌥⌘↑
    case focusDown // ⌥⌘↓

    // View
    case toggleZoom // ⌥⌘↩ — maximize / restore the active pane (render-only)
    case commandPalette // ⌘K — show/hide the ⌘K command palette
    case cheatSheet // ⌘/ — show/hide the keyboard cheat sheet

    // Tabs
    case newTab // ⌘T
    case nextTab // ⌘⇧]
    case prevTab // ⌘⇧[
    case selectTab(Int) // ⌘1…⌘9 (1-based)

    // Sessions
    case newSession // ⌃⌘N
}

public extension WorkspaceAction {
    /// The display category the cheat sheet groups by (and the menu/palette sections mirror).
    enum Category: String, Sendable, CaseIterable {
        case panes = "Panes"
        case tabs = "Tabs"
        case sessions = "Sessions"
        case focus = "Focus"
        case view = "View"
    }

    /// Whether running this action requires an active pane (so the palette can omit it on an empty shell,
    /// and the menu can grey it out) — mirrors ``WorkspaceCommand/requiresFocusedPane``.
    var requiresActivePane: Bool {
        switch self {
        case .splitRight,
             .splitDown,
             .closePane,
             .renamePane,
             .breakPaneToTab,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .toggleZoom:
            true
        case .commandPalette,
             .cheatSheet,
             .newTab,
             .nextTab,
             .prevTab,
             .selectTab,
             .newSession:
            false
        }
    }
}

// MARK: - WorkspaceBinding (one registry row: action + chord + display)

/// One row of the single-source-of-truth binding table: an action, its default chord (or `nil` for a
/// palette-only verb), plus the display shape the menu / palette / cheat sheet render. Pure value data.
public struct WorkspaceBinding: Sendable, Equatable {
    /// A stable string id (the dedup + rebind key; C4 settings will key user overrides by it).
    public let id: String
    public let action: WorkspaceAction
    public let title: String
    public let category: WorkspaceAction.Category
    /// The default chord, or `nil` for a binding surfaced only in the palette / menu (no key equivalent).
    public let chord: KeyChord?
    /// SF Symbol for the menu / palette row.
    public let symbol: String
    /// Extra non-displayed fuzzy-match terms (synonyms the user might type) — folded into the palette
    /// haystack, never rendered.
    public let keywords: String?

    public init(
        id: String,
        action: WorkspaceAction,
        title: String,
        category: WorkspaceAction.Category,
        chord: KeyChord?,
        symbol: String,
        keywords: String? = nil,
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.category = category
        self.chord = chord
        self.symbol = symbol
        self.keywords = keywords
    }
}

// MARK: - WorkspaceBindingRegistry (the ONE source of truth)

/// The single source of truth for the IDE-shell command surface (docs/42 §W6): ONE ``bindings`` table
/// that the menu bar (``WorkspaceCommands``), the ⌘K command palette (``CommandPaletteView``), the ⌘/
/// cheat sheet (``KeyboardCheatSheet``), and the routing tests ALL read — so a chord, a menu item, a
/// palette row, and a cheat-sheet glyph can never drift apart (and C4 settings has one table to make
/// user-editable).
///
/// Every chord is ⌘- or ⌥-prefixed (the load-bearing §5 conflict rule: a bare key / Ctrl-letter falls
/// through to the focused terminal), and no two bindings share a chord — both pinned by
/// `TreeCommandRoutingTests`. The chords mirror coding-IDE / multiplexer norms (VS Code / WezTerm /
/// Zellij): ⌘T new tab, ⌘W close, ⌘D split-right, ⌘⇧D split-down, ⌥⌘+arrows focus, ⌥⌘↩ zoom, ⌘⇧]/⌘⇧[
/// next/prev tab, ⌘1…9 select tab, ⌃⌘N new session, ⌘⇧R rename, ⌃⌘T break-pane-to-tab, ⌘K palette, ⌘/
/// cheat sheet.
public enum WorkspaceBindingRegistry {
    /// The shipped binding table, in cheat-sheet / palette display order (panes, tabs, sessions, focus,
    /// view). `.selectTab(n)` for n=1…9 is generated (one chord each) but is NOT listed here — it is
    /// expanded by ``selectTabBindings`` so the table stays readable; the menu/palette/cheat-sheet collapse
    /// the nine slots to a representative row.
    public static let bindings: [WorkspaceBinding] = [
        // Panes
        WorkspaceBinding(
            id: "pane.splitRight", action: .splitRight, title: "Split Right",
            category: .panes, chord: KeyChord(character: "d", [.command]),
            symbol: "rectangle.split.2x1", keywords: "split column side vertical divider new pane",
        ),
        WorkspaceBinding(
            id: "pane.splitDown", action: .splitDown, title: "Split Down",
            category: .panes, chord: KeyChord(character: "d", [.command, .shift]),
            symbol: "rectangle.split.1x2", keywords: "split row stacked horizontal divider new pane below",
        ),
        WorkspaceBinding(
            id: "pane.close", action: .closePane, title: "Close Pane",
            category: .panes, chord: KeyChord(character: "w", [.command]),
            symbol: "xmark", keywords: "quit kill end terminate remove",
        ),
        WorkspaceBinding(
            id: "pane.rename", action: .renamePane, title: "Rename Tab",
            category: .panes, chord: KeyChord(character: "r", [.command, .shift]),
            symbol: "pencil", keywords: "title label name tab",
        ),
        WorkspaceBinding(
            id: "pane.breakToTab", action: .breakPaneToTab, title: "Break Pane to Tab",
            category: .panes, chord: KeyChord(character: "t", [.control, .command]),
            symbol: "rectangle.portrait.and.arrow.right", keywords: "eject move detach pop out promote",
        ),
        // Tabs
        WorkspaceBinding(
            id: "tab.new", action: .newTab, title: "New Tab",
            category: .tabs, chord: KeyChord(character: "t", [.command]),
            symbol: "plus.rectangle.on.rectangle", keywords: "add open create tab",
        ),
        WorkspaceBinding(
            id: "tab.next", action: .nextTab, title: "Next Tab",
            category: .tabs, chord: KeyChord(character: "]", [.command, .shift]),
            symbol: "arrow.forward.square", keywords: "cycle forward switch tab",
        ),
        WorkspaceBinding(
            id: "tab.prev", action: .prevTab, title: "Previous Tab",
            category: .tabs, chord: KeyChord(character: "[", [.command, .shift]),
            symbol: "arrow.backward.square", keywords: "cycle back previous switch tab",
        ),
        // Sessions
        WorkspaceBinding(
            id: "session.new", action: .newSession, title: "New Session",
            category: .sessions, chord: KeyChord(character: "n", [.control, .command]),
            symbol: "macwindow.badge.plus", keywords: "host connection add open create workspace",
        ),
        // Focus
        WorkspaceBinding(
            id: "focus.left", action: .focusLeft, title: "Focus Left",
            category: .focus, chord: KeyChord(.leftArrow, [.option, .command]),
            symbol: "arrow.left", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.right", action: .focusRight, title: "Focus Right",
            category: .focus, chord: KeyChord(.rightArrow, [.option, .command]),
            symbol: "arrow.right", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.up", action: .focusUp, title: "Focus Up",
            category: .focus, chord: KeyChord(.upArrow, [.option, .command]),
            symbol: "arrow.up", keywords: "move navigate pane",
        ),
        WorkspaceBinding(
            id: "focus.down", action: .focusDown, title: "Focus Down",
            category: .focus, chord: KeyChord(.downArrow, [.option, .command]),
            symbol: "arrow.down", keywords: "move navigate pane",
        ),
        // View
        WorkspaceBinding(
            id: "view.zoom", action: .toggleZoom, title: "Maximize Pane",
            category: .view, chord: KeyChord(.return, [.option, .command]),
            symbol: "arrow.up.left.and.arrow.down.right", keywords: "fullscreen full screen zoom expand enlarge",
        ),
        WorkspaceBinding(
            id: "view.palette", action: .commandPalette, title: "Command Palette",
            category: .view, chord: KeyChord(character: "k", [.command]),
            symbol: "command", keywords: "search run quickly open actions",
        ),
        WorkspaceBinding(
            id: "view.cheatSheet", action: .cheatSheet, title: "Keyboard Shortcuts",
            category: .view, chord: KeyChord(character: "/", [.command]),
            symbol: "keyboard", keywords: "shortcuts cheat sheet help keys reference",
        ),
    ]

    /// The ⌘1…⌘9 "select tab N" bindings (generated, kept out of the main table for readability). One per
    /// digit; carried so the chord table is complete + the conflict / prefix guards see them.
    public static let selectTabBindings: [WorkspaceBinding] = (1...9).map { n in
        WorkspaceBinding(
            id: "tab.select.\(n)", action: .selectTab(n),
            title: "Select Tab \(n)", category: .tabs,
            chord: KeyChord(character: Character("\(n)"), [.command]),
            symbol: "\(n).square", keywords: "switch jump tab \(n)",
        )
    }

    /// Every binding the registry knows — the main table plus the nine ⌘-digit select-tab chords. The
    /// chord-table guards (uniqueness, ⌘/⌥-prefix) run over this full set.
    public static var allBindings: [WorkspaceBinding] { bindings + selectTabBindings }

    /// The binding for `action`, or `nil` if unregistered.
    public static func binding(for action: WorkspaceAction) -> WorkspaceBinding? {
        allBindings.first { $0.action == action }
    }

    /// The chord → action lookup table (drives the keyboard dispatcher). Built from ``allBindings`` so the
    /// keyboard layer reads the SAME source as the menu/palette/cheat sheet.
    public static var chordTable: [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        for binding in allBindings {
            if let chord = binding.chord { map[chord] = binding.action }
        }
        return map
    }

    // MARK: - Glyph rendering (chord → human string) — the cheat sheet / palette display

    /// Renders a ``KeyChord`` in native modifier-glyph order (⌃⌥⇧⌘ + key) — the same form the canvas
    /// palette uses, kept here as the registry's own pure renderer so the menu/palette/cheat sheet read
    /// ONE place. `nonisolated` (no view / actor) so it composes from any context.
    nonisolated static func glyph(_ chord: KeyChord) -> String {
        var out = ""
        if chord.modifiers.contains(.control) { out += "⌃" }
        if chord.modifiers.contains(.option) { out += "⌥" }
        if chord.modifiers.contains(.shift) { out += "⇧" }
        if chord.modifiers.contains(.command) { out += "⌘" }
        out += keyGlyph(chord.key)
        return out
    }

    /// The display glyph for `action`'s default chord, or `nil` when it has none.
    nonisolated static func glyph(for action: WorkspaceAction) -> String? {
        binding(for: action)?.chord.map(glyph)
    }

    private nonisolated static func keyGlyph(_ key: KeyChord.Key) -> String {
        switch key {
        case let .character(c): c.uppercased()
        case .tab: "⇥"
        case .return: "↩"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        }
    }

    // MARK: - Grouped display (the cheat sheet sections + palette catalog order)

    /// The bindings grouped by category in display order (panes, tabs, sessions, focus, view), with the
    /// nine ⌘-digit select-tab chords collapsed into one representative "⌘1…⌘9" row in the Tabs group. The
    /// SINGLE source the cheat sheet renders and the palette catalog iterates — so they cannot drift.
    static var groupedForDisplay: [(category: WorkspaceAction.Category, bindings: [WorkspaceBinding])] {
        WorkspaceAction.Category.allCases.compactMap { category in
            let rows = bindings.filter { $0.category == category }
            guard !rows.isEmpty else { return nil }
            return (category, rows)
        }
    }
}
