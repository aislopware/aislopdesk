import XCTest
@testable import RworkClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the command-palette catalog + per-pane entry builder additions (research B2): the new
/// "Reconnect Pane" command surfaces and ranks under "recon", and a multi-pane tab produces one
/// jump-to-pane entry per leaf carrying both the pane id and its owning tab id. Pure seams — the fuzzy
/// scorer and `buildPaneEntries` are tested directly, no SwiftUI render. `.reconnectPane` command
/// routing is asserted against the store via `apply(_:to:)` with the `FakePaneSession` seam.
@MainActor
final class CommandPaletteEntriesTests: XCTestCase {

    #if canImport(SwiftUI)

    // MARK: - Catalog contains Reconnect Pane + fuzzy ranks it

    func testCatalogContainsReconnectPane() {
        let hasReconnect = CommandPaletteView.commandCatalog.contains { $0.command == .reconnectPane }
        XCTAssertTrue(hasReconnect, "the palette catalog must offer Reconnect Pane")
    }

    func testFuzzyRanksReconnectForReconQuery() {
        // "recon" is a contiguous-prefix subsequence of "Reconnect Pane" ⇒ a positive (high) score.
        let score = CommandPaletteView.fuzzyScore(query: "recon", in: "Reconnect Pane")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
        // A non-subsequence query does not match.
        XCTAssertNil(CommandPaletteView.fuzzyScore(query: "xyz", in: "Reconnect Pane"))
    }

    // MARK: - Tab entry keyword search ("select tab N")

    /// A tab entry folds non-displayed `keywords` ("select tab N") into `searchText`, so the menu-bar
    /// phrasing finds a tab by POSITION even when the tab is not literally named "N". Without the
    /// keywords, that phrasing would not match the tab's visible text — closing the two-surface gap.
    func testTabEntryKeywordsEnableSelectTabNQuery() {
        let withKeywords = CommandPaletteView.Entry(
            id: "tab.x", kind: .tab(TabID()), title: "Work",
            subtitle: "Switch to tab", symbol: "rectangle.stack", keywords: "select tab 3"
        )
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "select tab 3", in: withKeywords.searchText),
            "the menu-learned 'Select Tab 3' phrasing must match a tab via its keywords"
        )

        let noKeywords = CommandPaletteView.Entry(
            id: "tab.x", kind: .tab(TabID()), title: "Work",
            subtitle: "Switch to tab", symbol: "rectangle.stack"
        )
        XCTAssertNil(
            CommandPaletteView.fuzzyScore(query: "select tab 3", in: noKeywords.searchText),
            "without keywords that phrasing does not match the tab's visible text (proves keywords are load-bearing)"
        )
    }

    // MARK: - buildPaneEntries

    /// A multi-leaf tab yields one pane entry per leaf, each carrying the correct (PaneID, TabID); a
    /// single-leaf tab yields none (it is fully represented by its tab entry).
    func testBuildPaneEntriesOnlyForMultiPaneTabs() {
        // Two-pane tab.
        let leftID = PaneID(), rightID = PaneID()
        let multiTab = Tab.canvasTab(
            name: "Work",
            panes: [
                (leftID, PaneSpec(kind: .terminal, title: "Left")),
                (rightID, PaneSpec(kind: .claudeCode, title: "Right")),
            ],
            focused: leftID
        )
        // Single-pane tab.
        let soloID = PaneID()
        let soloTab = Tab.canvasTab(name: "Solo", panes: [(soloID, PaneSpec(kind: .terminal, title: "Solo"))])

        let entries = CommandPaletteView.buildPaneEntries(tabs: [multiTab, soloTab])

        XCTAssertEqual(entries.count, 2, "only the 2-leaf tab contributes pane entries")
        let pairs: [(PaneID, TabID)] = entries.compactMap { entry in
            if case let .pane(p, t) = entry.kind { return (p, t) }
            return nil
        }
        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.contains { $0.0 == leftID && $0.1 == multiTab.id })
        XCTAssertTrue(pairs.contains { $0.0 == rightID && $0.1 == multiTab.id })
        // Titles come from the leaf specs.
        XCTAssertEqual(Set(entries.map(\.title)), ["Left", "Right"])
    }

    #endif

    // MARK: - apply(.reconnectPane) routing

    /// `apply(.reconnectPane)` is a graceful no-op against the `FakePaneSession` seam (no live
    /// connection) — it must not trap and must not mutate the tree / registry.
    func testApplyReconnectPaneIsSafeWithFakeSession() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let before = store.workspace
        let sessions = store.allSessions.count

        apply(.reconnectPane, to: store)   // focused pane has a FakePaneSession (no connection) ⇒ no-op

        XCTAssertEqual(store.workspace, before, "reconnect must not mutate the tree")
        XCTAssertEqual(store.allSessions.count, sessions, "reconnect must not touch the registry")
    }

    /// `apply(.reconnectPane)` with no active tab is a graceful no-op (no focused pane to reconnect).
    func testApplyReconnectPaneNoopWithNoActiveTab() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.closeTab(store.activeTab!.id)
        XCTAssertNil(store.activeTab)
        apply(.reconnectPane, to: store)   // must not trap
        XCTAssertNil(store.activeTab)
    }

    // MARK: - apply(.renameTab) wiring (was a dead no-op)

    /// `apply(.renameTab)` bumps `renameTabRequest` so the sidebar opens its inline rename field — the
    /// fix for the ⌘R / menu / palette "Rename Tab" entry points that previously did nothing.
    func testApplyRenameTabBumpsRenameRequestWithActiveTab() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        XCTAssertNotNil(store.activeTab)
        let before = store.renameTabRequest
        apply(.renameTab, to: store)
        XCTAssertEqual(store.renameTabRequest, before + 1, "rename request bumps so the sidebar opens the field")
    }

    /// With no active tab, `apply(.renameTab)` is a graceful no-op (nothing to rename).
    func testApplyRenameTabNoopWithNoActiveTab() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.closeTab(store.activeTab!.id)
        XCTAssertNil(store.activeTab)
        let before = store.renameTabRequest
        apply(.renameTab, to: store)   // must not trap
        XCTAssertEqual(store.renameTabRequest, before, "no active tab → no rename request")
    }
}
