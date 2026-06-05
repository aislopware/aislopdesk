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

    // MARK: - buildPaneEntries

    /// A multi-leaf tab yields one pane entry per leaf, each carrying the correct (PaneID, TabID); a
    /// single-leaf tab yields none (it is fully represented by its tab entry).
    func testBuildPaneEntriesOnlyForMultiPaneTabs() {
        // Two-leaf tab.
        let leftID = PaneID(), rightID = PaneID()
        let multiTab = Tab(
            name: "Work",
            root: .split(
                .horizontal,
                children: [
                    .leaf(leftID, PaneSpec(kind: .terminal, title: "Left")),
                    .leaf(rightID, PaneSpec(kind: .claudeCode, title: "Right")),
                ],
                fractions: [0.5, 0.5]
            ),
            focusedPane: leftID
        )
        // Single-leaf tab.
        let soloID = PaneID()
        let soloTab = Tab(name: "Solo", root: .leaf(soloID, PaneSpec(kind: .terminal, title: "Solo")), focusedPane: soloID)

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
}
