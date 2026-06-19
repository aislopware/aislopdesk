import CoreGraphics
import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// W6 (docs/42 §"W6 — Keybindings + command palette + cheat sheet"): pins the **tree-command-routing**
/// contract — the single ``WorkspaceBindingRegistry`` source of truth that the menu bar, the ⌘K command
/// palette, the ⌘/ cheat sheet, AND this test all read. Each registered ``WorkspaceAction`` must, when
/// routed through ``WorkspaceBindingRegistry/route(_:to:)`` on a `.tree`-live store, land on the intended
/// store TREE op — asserted through the resulting ``TreeWorkspace`` / registry change, never a recompute
/// of the registry itself (no tautology).
///
/// The suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (never a real
/// `AislopdeskClient` / `HostServer`) and builds every store with ``WorkspaceStore/LiveModel/tree`` so the
/// tree is the live source the routing drives. No SwiftUI view is constructed — `route(_:to:)` is the pure
/// seam under test, identical to what a menu `Button` / palette row / chord dispatch invokes.
@MainActor
final class TreeCommandRoutingTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree` (default: one terminal pane), backed by the
    /// `FakePaneSession` seam — so init reconciles the TREE and the routing then drives it.
    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The tree's leaf ids in DFS order.
    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    /// The active tab's active pane.
    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// Routes `action` through the single-source-of-truth registry (the production seam).
    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        WorkspaceBindingRegistry.route(action, to: store)
    }

    // MARK: - Panes: split adds a leaf + materializes a fake

    /// `.splitRight` adds exactly one leaf (a horizontal sibling) to the active tab and materializes a new
    /// `FakePaneSession` for it — the new leaf becomes the active pane.
    func testSplitRightAddsLeafAndMaterializesFake() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]
        XCTAssertEqual(store.allSessions.count, 1, "default tree = one materialized leaf")

        route(.splitRight, store)

        XCTAssertEqual(leaves(store).count, 2, "splitRight added exactly one leaf")
        XCTAssertEqual(store.allSessions.count, 2, "reconcileTree materialized exactly one new handle")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
        XCTAssertNotNil(store.handle(for: added) as? FakePaneSession, "the new leaf has a fake handle")
    }

    /// `.splitDown` also adds one leaf — proving the axis routes through too (a vertical split). We assert
    /// the leaf count grows and the new leaf is focused; the axis difference vs. `.splitRight` is pinned by
    /// the `WorkspaceTreeOps` suite, so here it suffices that the action reaches the split op.
    func testSplitDownAddsLeaf() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]

        route(.splitDown, store)

        XCTAssertEqual(leaves(store).count, 2, "splitDown added exactly one leaf")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
    }

    /// `.closePane` removes the active pane and tears down exactly its fake (the survivor is untouched).
    func testClosePaneRemovesActivePane() async throws {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store)
        let b = try XCTUnwrap(activePane(store)) // the new pane is active
        XCTAssertNotEqual(a, b)
        let bFake = store.handle(for: b) as? FakePaneSession

        route(.closePane, store)

        XCTAssertNil(store.handle(for: b), "closed leaf removed from the registry synchronously")
        XCTAssertEqual(leaves(store), [a], "only the survivor remains")
        await store.quiesce()
        XCTAssertEqual(bFake?.teardownCount, 1, "the closed leaf was torn down exactly once")
    }

    // MARK: - Focus: geometric move follows the reported layout

    /// `.focusLeft` / `.focusRight` move the active pane along the solved layout the view reports — proving
    /// the focus actions route through `moveFocusTree` against the live geometry (not a no-op).
    func testFocusRightThenLeftMovesActivePane() throws {
        let store = makeTreeStore()
        let left = leaves(store)[0]
        route(.splitRight, store) // a horizontal split: [left | right], right focused
        let right = try XCTUnwrap(activePane(store))
        // Report the rects the SplitTreeView would solve so the geometric move resolves.
        store.updateSolvedLayout(SolvedLayout(frames: [
            left: CGRect(x: 0, y: 0, width: 100, height: 100),
            right: CGRect(x: 100, y: 0, width: 100, height: 100),
        ]))

        route(.focusLeft, store)
        XCTAssertEqual(activePane(store), left, "focusLeft lands on the left pane")

        route(.focusRight, store)
        XCTAssertEqual(activePane(store), right, "focusRight lands back on the right pane")
    }

    // MARK: - View: zoom toggles the active tab's zoomedPane

    /// `.toggleZoom` sets then clears the active tab's `zoomedPane` (render-only zoom; the tree is untouched).
    func testToggleZoomTogglesZoomedPane() {
        let store = makeTreeStore()
        let only = leaves(store)[0]
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "no zoom initially")

        route(.toggleZoom, store)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.zoomedPane, only, "toggleZoom zoomed the active pane")

        route(.toggleZoom, store)
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "toggleZoom again cleared the zoom")
    }

    // MARK: - Tabs: new / next / prev / select-N

    /// `.newTab` adds a tab (single leaf) to the active session and selects it; the leaf is materialized.
    func testNewTabAddsTabAndSelectsIt() {
        let store = makeTreeStore()
        let session0 = try? XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session0?.tabs.count, 1, "default session = one tab")

        route(.newTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "newTab added a tab")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "the new tab is selected")
        XCTAssertEqual(leaves(store).count, 2, "the new tab's leaf was materialized")
        XCTAssertEqual(store.allSessions.count, 2)
    }

    /// `.nextTab` / `.prevTab` cycle the active session's `activeTabIndex` without changing the leaf set.
    func testNextAndPrevTabCycleActiveIndex() {
        let store = makeTreeStore()
        route(.newTab, store) // now two tabs, index 1 active
        route(.newTab, store) // three tabs, index 2 active
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2)
        let leafCount = leaves(store).count

        route(.prevTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "prevTab stepped back one tab")

        route(.nextTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "nextTab stepped forward one tab")

        XCTAssertEqual(leaves(store).count, leafCount, "cycling tabs never changes the leaf set")
    }

    /// `.selectTab(N)` (1-based) selects the Nth tab of the active session.
    func testSelectTabNumberSelectsThatTab() {
        let store = makeTreeStore()
        route(.newTab, store)
        route(.newTab, store) // three tabs (indices 0,1,2), index 2 active

        route(.selectTab(1), store) // 1-based ⇒ index 0
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 0, "selectTab(1) selected the first tab")

        route(.selectTab(3), store) // 1-based ⇒ index 2
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "selectTab(3) selected the third tab")
    }

    /// `.breakPaneToTab` ejects the active pane into a new tab of its session (the source tab collapses).
    func testBreakPaneToTabEjectsActivePane() throws {
        let store = makeTreeStore()
        route(.splitRight, store) // two leaves in one tab
        let moved = try XCTUnwrap(activePane(store))
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "both leaves share one tab")

        route(.breakPaneToTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "break-pane created a second tab")
        // The moved pane is alone in some tab (the new one).
        let owningTab = try XCTUnwrap(store.tree.activeSession?.tabs.first { $0.contains(moved) })
        XCTAssertEqual(owningTab.allPaneIDs(), [moved], "the broken-out pane is alone in its new tab")
    }

    // MARK: - Sessions: new session changes the active session + materializes its leaf

    /// `.newSession` adds a session (one tab/leaf) and selects it; its leaf is materialized.
    func testNewSessionAddsAndSelectsSession() throws {
        let store = makeTreeStore()
        let session0 = try XCTUnwrap(store.tree.activeSessionID)
        XCTAssertEqual(store.tree.sessions.count, 1)

        route(.newSession, store)

        XCTAssertEqual(store.tree.sessions.count, 2, "newSession added a session")
        XCTAssertNotEqual(store.tree.activeSessionID, session0, "the new session is now active")
        XCTAssertEqual(leaves(store).count, 2, "the new session's leaf was materialized")
        XCTAssertEqual(store.allSessions.count, 2)
    }

    // MARK: - Rename: routes to the pending-rename request (UI affordance marker)

    /// `.renamePane` records the active pane as the pending rename target (the inline field opens) — the
    /// tree/registry are untouched, exactly as the canvas rename is a command-layer UI nudge.
    func testRenamePaneRecordsPendingRenameTarget() {
        let store = makeTreeStore()
        let active = activePane(store)
        let treeBefore = store.tree
        let sessionsBefore = store.allSessions.count

        route(.renamePane, store)

        XCTAssertEqual(store.pendingRename, active, "renamePane recorded the active pane as the rename target")
        XCTAssertEqual(store.tree, treeBefore, "renamePane never mutates the tree")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renamePane never touches the registry")
    }

    // MARK: - Registry integrity (the single source of truth)

    /// Every binding has a stable, unique id and (for the chord-carrying ones) a unique chord — the drift
    /// guard the menu/palette/cheat-sheet rely on. Pins that no two actions claim the same chord.
    func testRegistryBindingsHaveUniqueIDsAndChords() {
        let ids = WorkspaceBindingRegistry.bindings.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "binding ids are unique")

        let chords = WorkspaceBindingRegistry.bindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord (conflict-free)")
    }

    /// Every chord-carrying binding is ⌘- or ⌥-prefixed (the load-bearing §5 conflict rule: a bare key /
    /// Ctrl-letter must fall through to the focused terminal). NO bare-key binding anywhere.
    func testEveryChordIsCommandOrOptionPrefixed() {
        for binding in WorkspaceBindingRegistry.bindings {
            guard let chord = binding.chord else { continue }
            XCTAssertTrue(
                chord.modifiers.contains(.command) || chord.modifiers.contains(.option),
                "binding \(binding.id) chord must be ⌘- or ⌥-prefixed (never steal a terminal key)",
            )
        }
    }

    /// The chord table resolves the documented coding-IDE defaults — pins the exact chords the cheat sheet
    /// advertises so a transposed modifier can't slip past the "every action has a row" drift guard.
    func testDefaultChordsMatchTheDocumentedTable() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.newTab), KeyChord(character: "t", [.command]), "new tab = ⌘T")
        XCTAssertEqual(chord(.closePane), KeyChord(character: "w", [.command]), "close pane = ⌘W")
        XCTAssertEqual(chord(.splitRight), KeyChord(character: "d", [.command]), "split right = ⌘D")
        XCTAssertEqual(chord(.splitDown), KeyChord(character: "d", [.command, .shift]), "split down = ⌘⇧D")
        XCTAssertEqual(chord(.focusLeft), KeyChord(.leftArrow, [.option, .command]), "focus left = ⌥⌘←")
        XCTAssertEqual(chord(.toggleZoom), KeyChord(.return, [.option, .command]), "zoom = ⌥⌘↩")
        XCTAssertEqual(chord(.nextTab), KeyChord(character: "]", [.command, .shift]), "next tab = ⌘⇧]")
        XCTAssertEqual(chord(.prevTab), KeyChord(character: "[", [.command, .shift]), "prev tab = ⌘⇧[")
        XCTAssertEqual(chord(.newSession), KeyChord(character: "n", [.control, .command]), "new session = ⌃⌘N")
        XCTAssertEqual(chord(.selectTab(1)), KeyChord(character: "1", [.command]), "select tab 1 = ⌘1")
        XCTAssertEqual(chord(.selectTab(9)), KeyChord(character: "9", [.command]), "select tab 9 = ⌘9")
    }

    #if canImport(SwiftUI)

    // MARK: - Single source of truth: the cheat sheet is GENERATED from the registry (drift guard)

    /// DRIFT GUARD: every chord-carrying registry binding (a real tree shortcut) is documented in the
    /// tree cheat sheet via its registry-rendered glyph — so the cheat sheet cannot drift from the table
    /// the menu + palette + chord dispatcher use. (The select-tab digits collapse to one "⌘1…⌘9" row.)
    func testTreeCheatSheetDocumentsEveryRegistryChord() {
        let glyphs = Set(KeyboardCheatSheet.treeSections().flatMap(\.items).map(\.glyph))
        for binding in WorkspaceBindingRegistry.bindings {
            guard let chord = binding.chord else { continue }
            XCTAssertTrue(
                glyphs.contains(WorkspaceBindingRegistry.glyph(chord)),
                "the tree cheat sheet is missing a row for \(binding.id) (\(WorkspaceBindingRegistry.glyph(chord)))",
            )
        }
        // The collapsed select-tab row stands in for the nine ⌘-digit chords.
        XCTAssertTrue(glyphs.contains("⌘1…⌘9"), "the select-tab digits are documented as one collapsed row")
    }

    /// The tree cheat sheet groups by the registry categories (Panes / Tabs / Sessions / Focus / View)
    /// plus the curated Terminal extras — and every row carries a non-empty glyph + label.
    func testTreeCheatSheetSectionsAreWellFormed() {
        let sections = KeyboardCheatSheet.treeSections()
        let titles = sections.map(\.title)
        for category in WorkspaceAction.Category.allCases {
            XCTAssertTrue(titles.contains(category.rawValue), "the \(category.rawValue) section is present")
        }
        XCTAssertTrue(titles.contains("Terminal"), "the curated terminal-chord section is appended")
        for section in sections {
            XCTAssertFalse(section.items.isEmpty, "\(section.title) has rows")
            for item in section.items {
                XCTAssertFalse(item.glyph.isEmpty, "\(item.label) has a glyph")
                XCTAssertFalse(item.label.isEmpty)
            }
        }
    }

    #endif
}
