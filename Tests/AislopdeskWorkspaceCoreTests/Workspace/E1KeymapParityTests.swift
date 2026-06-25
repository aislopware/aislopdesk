import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// E1 (epic E1 — "Default-keymap parity & command-routing completion"): pins the NEW keymap-parity
/// contract WI-4 adds to the single-source-of-truth ``WorkspaceBindingRegistry`` — every clone action
/// registered with its collision-checked chord, the tab-cycle re-point (⌘]/⌘[ → sequential PANE cycle,
/// tab cycling moved to ⌘⇧]/⌘⇧[), the named-key scroll chords, the font chords, and the agent stubs.
///
/// Mirrors ``TreeCommandRoutingTests`` (same `makeTreeStore` / `route` harness): each new action must
/// resolve to its documented chord AND route through ``WorkspaceBindingRegistry/route(_:to:)`` on a
/// `.tree`-live store WITHOUT trapping (the registry's "no dead chords" contract). Behavioral effects that
/// need a live terminal surface (font / scroll → libghostty) are covered by the recording-fake-surface
/// tests in the store-hook suite; here we pin the structural store effects (split / cycle) + the chord table.
@MainActor
final class E1KeymapParityTests: XCTestCase {
    // MARK: - Fixtures (mirror TreeCommandRoutingTests)

    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func chord(_ action: WorkspaceAction) -> KeyChord? {
        WorkspaceBindingRegistry.binding(for: action)?.chord
    }

    // MARK: - ES-E1-1: split-left / split-up insert the LEADING leaf and focus it

    /// `.splitLeft` splits the active pane and inserts the new `.chooser` leaf on the LEADING (DFS-first)
    /// side, focused. (The leaf is a `.chooser`, which materializes no session until `choosePaneKind`, so we
    /// assert on the tree structure, not a fake handle — the chooser-split itself is the WI-4/WI-5 contract.)
    /// FAILS on the pre-E1 code: there is no `.splitLeft` action / routing case.
    func testSplitLeftInsertsLeadingLeafAndFocuses() throws {
        let store = makeTreeStore()
        let original = try XCTUnwrap(leaves(store).first)

        WorkspaceBindingRegistry.route(.splitLeft, to: store)

        let after = leaves(store)
        XCTAssertEqual(after.count, 2, "splitLeft added exactly one leaf")
        let added = try XCTUnwrap(after.first { $0 != original })
        XCTAssertEqual(after.first, added, "the new leaf is inserted on the LEADING side (DFS-first)")
        XCTAssertEqual(activePane(store), added, "the new (leading) leaf is focused")
        XCTAssertEqual(store.tree.spec(for: added)?.kind, .chooser, "the new leaf is an in-pane chooser pane")
    }

    /// `.splitUp` does the same on the vertical axis: a leading (top, DFS-first) leaf, focused, in a stacked
    /// split. FAILS on the pre-E1 code (no `.splitUp`).
    func testSplitUpInsertsLeadingLeafInStackedSplit() throws {
        let store = makeTreeStore()
        let original = try XCTUnwrap(leaves(store).first)

        WorkspaceBindingRegistry.route(.splitUp, to: store)

        let after = leaves(store)
        XCTAssertEqual(after.count, 2, "splitUp added exactly one leaf")
        let added = try XCTUnwrap(after.first { $0 != original })
        XCTAssertEqual(after.first, added, "the new leaf is inserted on the LEADING (top) side")
        XCTAssertEqual(activePane(store), added, "the new (top) leaf is focused")
        guard case .split(_, .vertical, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("splitUp produces a vertical (stacked) split")
            return
        }
    }

    // MARK: - ES-E1-2: sequential pane cycle walks DFS and wraps

    /// `.cyclePaneNext` steps the active pane through the active tab's panes in DFS order and WRAPS at the
    /// end; `.cyclePanePrev` reverses. A 3-pane tab proves both the step and the wrap. FAILS on the pre-E1
    /// code (no `.cyclePaneNext`/`.cyclePanePrev` action or routing).
    func testCyclePaneWalksDFSAndWraps() {
        let store = makeTreeStore()
        // Build a 3-leaf tab: split twice (each split focuses the new leaf), then read DFS order.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let order = leaves(store)
        XCTAssertEqual(order.count, 3, "three panes in the active tab")

        // Anchor on the FIRST pane so the walk is deterministic from a known start.
        store.focusPaneTree(order[0])
        XCTAssertEqual(activePane(store), order[0])

        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[1], "cycleNext → second pane (DFS)")
        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[2], "cycleNext → third pane (DFS)")
        WorkspaceBindingRegistry.route(.cyclePaneNext, to: store)
        XCTAssertEqual(activePane(store), order[0], "cycleNext WRAPS from last → first")

        WorkspaceBindingRegistry.route(.cyclePanePrev, to: store)
        XCTAssertEqual(activePane(store), order[2], "cyclePrev WRAPS from first → last")
        WorkspaceBindingRegistry.route(.cyclePanePrev, to: store)
        XCTAssertEqual(activePane(store), order[1], "cyclePrev → second pane (reverse DFS)")
    }

    // MARK: - Chord table: re-point + new chords match the collision-checked E1 table

    /// The tab-cycle RE-POINT (ES-E1-2 / DECISIONS): `nextTab`/`prevTab` moved to ⌘⇧]/⌘⇧[, and the FREED
    /// ⌘]/⌘[ now drive sequential PANE cycling. A transposed-modifier typo would slip past the uniqueness
    /// guard (it only catches a COLLISION), so pin the exact values. FAILS on the pre-E1 chords.
    func testTabCycleMovedToShiftBracketAndPaneCycleOnPlainBracket() {
        XCTAssertEqual(chord(.nextTab), KeyChord(character: "]", [.command, .shift]), "next tab → ⌘⇧]")
        XCTAssertEqual(chord(.prevTab), KeyChord(character: "[", [.command, .shift]), "prev tab → ⌘⇧[")
        XCTAssertEqual(chord(.cyclePaneNext), KeyChord(character: "]", [.command]), "cycle pane next = ⌘]")
        XCTAssertEqual(chord(.cyclePanePrev), KeyChord(character: "[", [.command]), "cycle pane prev = ⌘[")
    }

    /// The split-left/up chords (ES-E1-1): ⌘⌥D / ⌘⌥⇧D — ⌥+ the ⌘D / ⌘⇧D right/down splits.
    func testSplitLeftUpChordsMatchTable() {
        XCTAssertEqual(chord(.splitLeft), KeyChord(character: "d", [.command, .option]), "split left = ⌘⌥D")
        XCTAssertEqual(chord(.splitUp), KeyChord(character: "d", [.command, .option, .shift]), "split up = ⌘⌥⇧D")
    }

    /// The eight scroll/command-jump chords + three font chords (ES-E1-3 / ES-E1-4) match the table.
    func testScrollAndFontChordsMatchTable() {
        XCTAssertEqual(chord(.scrollPageUp), KeyChord(.pageUp, [.shift]), "scroll page up = ⇧PageUp")
        XCTAssertEqual(chord(.scrollPageDown), KeyChord(.pageDown, [.shift]), "scroll page down = ⇧PageDown")
        XCTAssertEqual(chord(.scrollToTop), KeyChord(.home, [.shift]), "scroll top = ⇧Home")
        XCTAssertEqual(chord(.scrollToBottom), KeyChord(.end, [.shift]), "scroll bottom = ⇧End")
        XCTAssertEqual(chord(.commandJumpPrev), KeyChord(.pageUp, [.command]), "command jump prev = ⌘PageUp")
        XCTAssertEqual(chord(.commandJumpNext), KeyChord(.pageDown, [.command]), "command jump next = ⌘PageDown")
        XCTAssertEqual(chord(.increaseFontSize), KeyChord(character: "=", [.command]), "font increase = ⌘=")
        XCTAssertEqual(chord(.decreaseFontSize), KeyChord(character: "-", [.command]), "font decrease = ⌘-")
        XCTAssertEqual(chord(.resetFontSize), KeyChord(character: "0", [.command]), "font reset = ⌘0")
    }

    /// The delegated-stub chords (ES-E1-5): reopen ⌘⇧T, open-quickly ⌘⇧O, composer ⌘⇧E, queue ⌘⇧M, send-to-
    /// chat ⌘⌃↩ — all registered now (behaviour lands in later epics), with the exact collision-checked chords.
    func testDelegatedStubChordsMatchTable() {
        XCTAssertEqual(chord(.reopenClosed), KeyChord(character: "t", [.command, .shift]), "reopen closed = ⌘⇧T")
        XCTAssertEqual(chord(.openQuickly), KeyChord(character: "o", [.command, .shift]), "open quickly = ⌘⇧O")
        XCTAssertEqual(chord(.composer), KeyChord(character: "e", [.command, .shift]), "composer = ⌘⇧E")
        XCTAssertEqual(chord(.promptQueue), KeyChord(character: "m", [.command, .shift]), "prompt queue = ⌘⇧M")
        XCTAssertEqual(chord(.sendToChat), KeyChord(.return, [.command, .control]), "send to chat = ⌘⌃↩")
    }

    // MARK: - Registry integrity for the new actions

    /// Every new E1 action has a registered binding with a resolvable default chord (none is a palette-only
    /// orphan / unregistered). FAILS on the pre-E1 code where these actions / bindings don't exist.
    func testEveryE1ActionHasARegisteredChord() {
        let actions: [WorkspaceAction] = [
            .splitLeft, .splitUp,
            .cyclePaneNext, .cyclePanePrev,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .commandJumpPrev, .commandJumpNext,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reopenClosed, .openQuickly,
            .composer, .promptQueue, .sendToChat,
        ]
        for action in actions {
            let binding = WorkspaceBindingRegistry.binding(for: action)
            XCTAssertNotNil(binding, "\(action) has a registry binding")
            XCTAssertNotNil(binding?.chord, "\(action) has a resolvable default chord")
        }
    }

    /// Routing EVERY new E1 action through `route(_:to:)` on a tree store must not trap — the stubs
    /// (reopen / open-quickly / composer / queue / send-to-chat) are documented graceful no-ops, the font /
    /// scroll / command-jump hooks no-op against a non-live surface, and the split / cycle ops mutate the
    /// tree. Pins the registry's "no dead chord" contract: every action is wired, none is dropped/traps.
    func testEveryE1ActionRoutesWithoutTrap() {
        let actions: [WorkspaceAction] = [
            .splitLeft, .splitUp,
            .cyclePaneNext, .cyclePanePrev,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .commandJumpPrev, .commandJumpNext,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reopenClosed, .openQuickly,
            .composer, .promptQueue, .sendToChat,
        ]
        for action in actions {
            // Fresh store per action so a tree-mutating action (split) doesn't perturb the next assertion.
            let store = makeTreeStore()
            WorkspaceBindingRegistry.route(action, to: store) // must not trap
        }
    }

    /// The stub actions (reopen / open-quickly / composer / queue / send-to-chat) are GRACEFUL no-ops in E1:
    /// they route without mutating the tree (their behaviour lands in later epics). Pins that they are wired
    /// to a documented no-op, not accidentally bound to a destructive op.
    func testE1StubActionsDoNotMutateTree() {
        for action in [WorkspaceAction.openQuickly, .composer, .promptQueue, .sendToChat, .reopenClosed] {
            let store = makeTreeStore()
            let before = store.tree
            WorkspaceBindingRegistry.route(action, to: store)
            XCTAssertEqual(store.tree, before, "\(action) is an E1 stub — the tree is unchanged")
        }
    }

    // MARK: - Category taxonomy: the new .agents group is surfaced

    /// The new `.agents` Category is registered and surfaced by `groupedForDisplay` (so the cheat sheet /
    /// palette show the agent verbs). FAILS on the pre-E1 code (no `.agents` case / no agent rows).
    func testAgentsCategoryIsSurfacedInGroupedDisplay() {
        XCTAssertTrue(
            WorkspaceAction.Category.allCases.contains(.agents),
            "the Agents category is registered",
        )
        let agents = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .agents }
        let group = agents?.bindings
        XCTAssertNotNil(group, "groupedForDisplay surfaces the Agents group")
        let ids = Set(group?.map(\.id) ?? [])
        XCTAssertTrue(
            ids.isSuperset(of: ["agent.composer", "agent.promptQueue", "agent.sendToChat"]),
            "the Agents group carries composer / prompt-queue / send-to-chat",
        )
    }
}
