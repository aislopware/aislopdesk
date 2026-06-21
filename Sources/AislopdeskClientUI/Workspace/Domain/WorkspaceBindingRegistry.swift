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
    case toggleFloat // ⌘⇧F — float / embed the active pane (zellij toggle-float)
    case spawnFloating // ⌃⌘F — spawn a new floating scratch pane

    // Move pane (Zellij "move pane" — swap with the geometric neighbour)
    case movePaneLeft // ⌥⌘⇧←
    case movePaneRight // ⌥⌘⇧→
    case movePaneUp // ⌥⌘⇧↑
    case movePaneDown // ⌥⌘⇧↓

    // Resize pane (keyboard divider nudge — grow right/down, shrink left/up)
    case resizePaneLeft // ⌃⌘←
    case resizePaneRight // ⌃⌘→
    case resizePaneUp // ⌃⌘↑
    case resizePaneDown // ⌃⌘↓

    // Balance (tmux even-layout)
    case balancePanes // ⌃⌘=

    // Focus
    case focusLeft // ⌥⌘←
    case focusRight // ⌥⌘→
    case focusUp // ⌥⌘↑
    case focusDown // ⌥⌘↓

    // View
    case toggleZoom // ⌥⌘↩ — maximize / restore the active pane (render-only)
    case commandPalette // ⌘K — show/hide the ⌘K command palette
    case cheatSheet // ⌘/ — show/hide the keyboard cheat sheet
    case find // ⌘F — show/hide the find-in-terminal bar over the active pane (W14 #5)
    case toggleCopyMode // ⌘⇧C — enter modal keyboard copy-mode over the active pane's scrollback (P5b)
    case toggleSidebar // ⌘B — show/hide the sessions sidebar

    // Blocks (WB2 — Warp-style per-command blocks)
    case commandNavigator // ⌃⌘O — show/hide the searchable recent-blocks navigator over the active pane
    case jumpPreviousBlock // ⌃⌘[ — jump the viewport to the previous shell prompt (OSC 133, libghostty)
    case jumpNextBlock // ⌃⌘] — jump the viewport to the next shell prompt
    case reRunLastCommand // ⌃⌘R — re-inject the active pane's latest captured command (verbatim + newline)
    case jumpPreviousFailed // ⌃⌘⇧[ — jump to the previous (newer) FAILED block
    case jumpNextFailed // ⌃⌘⇧] — jump to the next (older) FAILED block

    // Tabs
    case newTab // ⌘T
    case nextTab // ⌘⇧]
    case prevTab // ⌘⇧[
    case selectTab(Int) // ⌘1…⌘9 (1-based)
    case closeTab // ⌘⇧W — close the active tab (all its panes)

    // Sessions
    case newSession // ⌃⌘N

    // Synchronized input (Zellij ToggleActiveSyncTab)
    case toggleSyncInput // ⌘⇧I — broadcast keystrokes to every other pane in the active tab

    // Supervision (P3 — jump to the pane that needs you)
    case jumpToAttention // ⌘⇧U — focus the oldest pane needing attention (needsPermission first, then done)
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
             .movePaneLeft,
             .movePaneRight,
             .movePaneUp,
             .movePaneDown,
             .resizePaneLeft,
             .resizePaneRight,
             .resizePaneUp,
             .resizePaneDown,
             .balancePanes,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .toggleZoom,
             .toggleFloat: // needs a pane to float/embed
            true
        case .find,
             .toggleCopyMode,
             .commandNavigator,
             .jumpPreviousBlock,
             .jumpNextBlock,
             .reRunLastCommand,
             .jumpPreviousFailed,
             .jumpNextFailed:
            // Block / find affordances target the active TERMINAL pane (its blocks / scrollback / prompt
            // marks), so they need one — but they degrade gracefully (a no-pane shell just no-ops), so
            // they are not greyed out aggressively.
            true
        case .commandPalette,
             .cheatSheet,
             .newTab,
             .nextTab,
             .prevTab,
             .selectTab,
             .closeTab,
             .toggleSidebar,
             .newSession,
             .spawnFloating, // creates its own pane — needs none
             .toggleSyncInput, // the tab must exist, but the palette can still show it (mirrors .newTab)
             .jumpToAttention: // acts globally across all tabs/sessions — needs no active pane
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
        // Floating panes (zellij toggle-float / new floating pane). ⌘⇧F floats/embeds the active pane
        // (⌘F is find, so ⌘⇧F is free); ⌃⌘F spawns a new floating scratch pane (the "F = float" family,
        // ⌃⌘F free vs the used ⌃⌘O/R/N/T/=). Both verified unique by `TreeCommandRoutingTests`.
        WorkspaceBinding(
            id: "pane.toggleFloat", action: .toggleFloat, title: "Float Pane",
            category: .panes, chord: KeyChord(character: "f", [.command, .shift]),
            symbol: "macwindow", keywords: "float overlay scratch detach embed unfloat windowed",
        ),
        WorkspaceBinding(
            id: "pane.spawnFloating", action: .spawnFloating, title: "New Floating Pane",
            category: .panes, chord: KeyChord(character: "f", [.control, .command]),
            symbol: "plus.rectangle.on.rectangle", keywords: "new floating scratch overlay terminal window",
        ),
        // Move pane (Zellij "move pane" — swap with the geometric neighbour). ⌥⌘⇧+arrows = the focus chords
        // (⌥⌘arrows) with ⇧ added, so they read as "carry the pane along the focus move" and stay distinct
        // from both focus (no ⇧) and the ⌃⌘arrow resize chords below.
        WorkspaceBinding(
            id: "pane.moveLeft", action: .movePaneLeft, title: "Move Pane Left",
            category: .panes, chord: KeyChord(.leftArrow, [.option, .command, .shift]),
            symbol: "arrow.left.square", keywords: "swap reorder shift pane left",
        ),
        WorkspaceBinding(
            id: "pane.moveRight", action: .movePaneRight, title: "Move Pane Right",
            category: .panes, chord: KeyChord(.rightArrow, [.option, .command, .shift]),
            symbol: "arrow.right.square", keywords: "swap reorder shift pane right",
        ),
        WorkspaceBinding(
            id: "pane.moveUp", action: .movePaneUp, title: "Move Pane Up",
            category: .panes, chord: KeyChord(.upArrow, [.option, .command, .shift]),
            symbol: "arrow.up.square", keywords: "swap reorder shift pane up",
        ),
        WorkspaceBinding(
            id: "pane.moveDown", action: .movePaneDown, title: "Move Pane Down",
            category: .panes, chord: KeyChord(.downArrow, [.option, .command, .shift]),
            symbol: "arrow.down.square", keywords: "swap reorder shift pane down",
        ),
        // Resize pane (keyboard divider nudge). ⌃⌘arrows — distinct from the ⌃⌘bracket block-jump chords
        // (different keys) and grow the active pane toward the arrow (right/down) or shrink it (left/up).
        WorkspaceBinding(
            id: "pane.resizeLeft", action: .resizePaneLeft, title: "Shrink Pane Width",
            category: .panes, chord: KeyChord(.leftArrow, [.control, .command]),
            symbol: "arrow.left.and.line.vertical.and.arrow.right", keywords: "resize shrink narrower width divider",
        ),
        WorkspaceBinding(
            id: "pane.resizeRight", action: .resizePaneRight, title: "Grow Pane Width",
            category: .panes, chord: KeyChord(.rightArrow, [.control, .command]),
            symbol: "arrow.right.and.line.vertical.and.arrow.left", keywords: "resize grow wider width divider",
        ),
        WorkspaceBinding(
            id: "pane.resizeUp", action: .resizePaneUp, title: "Shrink Pane Height",
            category: .panes, chord: KeyChord(.upArrow, [.control, .command]),
            symbol: "arrow.up.and.line.horizontal.and.arrow.down", keywords: "resize shrink shorter height divider",
        ),
        WorkspaceBinding(
            id: "pane.resizeDown", action: .resizePaneDown, title: "Grow Pane Height",
            category: .panes, chord: KeyChord(.downArrow, [.control, .command]),
            symbol: "arrow.down.and.line.horizontal.and.arrow.up", keywords: "resize grow taller height divider",
        ),
        // Balance (tmux even-layout): reset the active tab's split weights to equal. ⌃⌘= is otherwise unbound.
        WorkspaceBinding(
            id: "pane.balance", action: .balancePanes, title: "Balance Panes",
            category: .panes, chord: KeyChord(character: "=", [.control, .command]),
            symbol: "rectangle.split.2x2", keywords: "even equal distribute reset layout balance tile",
        ),
        // Tabs
        WorkspaceBinding(
            id: "tab.new", action: .newTab, title: "New Tab",
            category: .tabs, chord: KeyChord(character: "t", [.command]),
            symbol: "plus.rectangle.on.rectangle", keywords: "add open create tab",
        ),
        WorkspaceBinding(
            id: "tab.next", action: .nextTab, title: "Next Tab",
            category: .tabs, chord: KeyChord(character: "]", [.command]),
            symbol: "arrow.forward.square", keywords: "cycle forward switch tab",
        ),
        WorkspaceBinding(
            id: "tab.prev", action: .prevTab, title: "Previous Tab",
            category: .tabs, chord: KeyChord(character: "[", [.command]),
            symbol: "arrow.backward.square", keywords: "cycle back previous switch tab",
        ),
        WorkspaceBinding(
            id: "tab.close", action: .closeTab, title: "Close Tab",
            category: .tabs, chord: KeyChord(character: "w", [.command, .shift]),
            symbol: "xmark.rectangle", keywords: "close end terminate tab all panes",
        ),
        WorkspaceBinding(
            id: "tab.syncInput", action: .toggleSyncInput, title: "Sync Input to All Panes",
            category: .tabs, chord: KeyChord(character: "i", [.command, .shift]),
            symbol: "keyboard.badge.ellipsis",
            keywords: "sync broadcast input panes tab synchronize mirror zellij",
        ),
        // Supervision (P3): jump to the oldest pane needing attention (needsPermission first, then done) —
        // a global action across all tabs/sessions, so it lives in the Tabs group beside sync-input. ⌘⇧U is
        // FREE (no other binding uses `u`); pinned unique by the chord-uniqueness test.
        WorkspaceBinding(
            id: "view.jumpToAttention", action: .jumpToAttention, title: "Jump to Pane Needing Attention",
            category: .tabs, chord: KeyChord(character: "u", [.command, .shift]),
            symbol: "bell.badge",
            keywords: "jump unread attention needs permission blocked done next pane supervise oldest",
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
        WorkspaceBinding(
            id: "view.find", action: .find, title: "Find…",
            category: .view, chord: KeyChord(character: "f", [.command]),
            symbol: "magnifyingglass", keywords: "search scrollback grep locate text in terminal",
        ),
        // Copy Mode (P5b): modal keyboard scrollback navigation (tmux/zellij copy-mode). ⌘⇧C is FREE —
        // `c` appears in NO other binding, and ⌘⇧C does not collide with the system plain ⌘C copy (a
        // different modifier set, handled by the terminal's own copy responder). Verified unique by the
        // chord-uniqueness guard.
        WorkspaceBinding(
            id: "view.copyMode", action: .toggleCopyMode, title: "Copy Mode",
            category: .view, chord: KeyChord(character: "c", [.command, .shift]),
            symbol: "doc.on.clipboard",
            keywords: "copy mode scrollback keyboard navigate select yank vi tmux zellij",
        ),
        WorkspaceBinding(
            id: "view.toggleSidebar", action: .toggleSidebar, title: "Toggle Sidebar",
            category: .view, chord: KeyChord(character: "b", [.command]),
            symbol: "sidebar.left", keywords: "sidebar sessions rail hide show collapse",
        ),
        // Blocks (WB2): the Command Navigator toggle + jump-to-block prev/next. ⌃⌘O / ⌃⌘[ / ⌃⌘] are all
        // ⌘-prefixed (the §5 conflict rule) and collision-free against the rest of the table (tab cycling
        // is ⌘[/], focus is ⌥⌘arrows — neither uses ⌃⌘bracket). They target the active terminal pane.
        WorkspaceBinding(
            id: "view.commandNavigator", action: .commandNavigator, title: "Command Navigator",
            category: .view, chord: KeyChord(character: "o", [.control, .command]),
            symbol: "list.bullet.rectangle", keywords: "blocks commands history recent navigator output jump warp",
        ),
        WorkspaceBinding(
            id: "view.jumpPreviousBlock", action: .jumpPreviousBlock, title: "Jump to Previous Block",
            category: .view, chord: KeyChord(character: "[", [.control, .command]),
            symbol: "chevron.up.circle", keywords: "previous prompt block command back up jump scroll osc133",
        ),
        WorkspaceBinding(
            id: "view.jumpNextBlock", action: .jumpNextBlock, title: "Jump to Next Block",
            category: .view, chord: KeyChord(character: "]", [.control, .command]),
            symbol: "chevron.down.circle", keywords: "next prompt block command forward down jump scroll osc133",
        ),
        // WB3: re-run last command + jump-to-failed prev/next. ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] are all ⌘-prefixed (§5)
        // and collision-free: ⌃⌘R is otherwise unbound; ⌃⌘⇧[ / ⌃⌘⇧] add ⇧ to the block-jump chords, so
        // they are distinct from both ⌃⌘[ / ⌃⌘] (block jump) and ⌘[ / ⌘] (tab cycling).
        WorkspaceBinding(
            id: "view.reRunLastCommand", action: .reRunLastCommand, title: "Re-run Last Command",
            category: .view, chord: KeyChord(character: "r", [.control, .command]),
            symbol: "arrow.clockwise", keywords: "rerun repeat replay again last command block execute",
        ),
        WorkspaceBinding(
            id: "view.jumpPreviousFailed", action: .jumpPreviousFailed, title: "Jump to Previous Failed",
            category: .view, chord: KeyChord(character: "[", [.control, .command, .shift]),
            symbol: "chevron.up.2", keywords: "previous failed error nonzero exit block jump back up",
        ),
        WorkspaceBinding(
            id: "view.jumpNextFailed", action: .jumpNextFailed, title: "Jump to Next Failed",
            category: .view, chord: KeyChord(character: "]", [.control, .command, .shift]),
            symbol: "chevron.down.2", keywords: "next failed error nonzero exit block jump forward down",
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
