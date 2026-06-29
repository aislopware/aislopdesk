import XCTest
@testable import AislopdeskWorkspaceCore

/// E12 WI-6 — the store-level pin / float resolution the client UI promotes a composer through. The
/// pinned / floating composer is mounted OUTSIDE its origin pane subtree (a window-level bottom strip / a
/// non-activating `NSPanel` on macOS; a re-presented sheet on iOS), so the store must resolve it across ALL
/// live panes — not just the active one. That cross-pane resolution is exactly what lets a pinned composer
/// ride along across tab switches (`reconcileTree` keeps every tab's pane materialized).
///
/// Exercised on ``RecordingTerminalPaneSession`` (a real ``ComposerModel`` per `.terminal` pane, no socket /
/// renderer — hang-safe). REVERT-TO-CONFIRM-FAIL: a resolver that returned the ACTIVE pane's composer
/// (instead of scanning every live pane) would fail `testPinnedComposerResolvesTheNonActivePaneAcrossTabs`.
@MainActor
final class ComposerPinFloatResolverTests: XCTestCase {
    /// A `.tree`-live store backed by the recording (composer-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's durable composer.
    private func activeComposer(_ store: WorkspaceStore) throws -> ComposerModel {
        let id = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let session = try XCTUnwrap(store.handle(for: id) as? RecordingTerminalPaneSession)
        return try XCTUnwrap(session.composer)
    }

    func testNothingPinnedOrFloatingResolvesNil() {
        let store = makeStore()
        XCTAssertNil(store.pinnedComposer, "no pinned composer → no window-level mount")
        XCTAssertNil(store.floatingComposer, "no floating composer → no panel / sheet")
    }

    func testPinnedComposerResolvesTheNonActivePaneAcrossTabs() throws {
        let store = makeStore()
        let firstTabComposer = try activeComposer(store) // pane in tab 1
        store.newTab(kind: .terminal) // tab 2 — now the active tab
        let secondTabComposer = try activeComposer(store)
        XCTAssertNotIdentical(firstTabComposer, secondTabComposer, "precondition: two distinct live panes")

        // Pin the NON-active (tab-1) composer: the pin must resolve regardless of which tab is active, so a
        // pinned composer rides along after the user switches tabs.
        firstTabComposer.setPinned(true)
        let resolved = try XCTUnwrap(store.pinnedComposer)
        XCTAssertIdentical(
            resolved.composer, firstTabComposer,
            "pinnedComposer resolves the PINNED pane across tabs, not the active pane",
        )

        firstTabComposer.setPinned(false)
        XCTAssertNil(store.pinnedComposer, "unpinning drops the window-level mount")
    }

    /// otty's pin is a SINGLE window-level composer — pinning a second pane's composer must auto-unpin the
    /// first so exactly one is pinned (and reachable via ``WorkspaceStore/pinnedComposer``). REVERT-TO-CONFIRM-
    /// FAIL: without the `onPinnedExclusive` sweep, pinning B leaves A pinned too — A's composer (and its unpin
    /// toggle) become unreachable because `pinnedComposer` (first-match across the unordered registry) surfaces
    /// only one of the two — so `XCTAssertFalse(firstTabComposer.isPinned)` fails on the unfixed code.
    func testPinningASecondComposerAutoUnpinsTheFirst() throws {
        let store = makeStore()
        let firstTabComposer = try activeComposer(store) // pane in tab 1
        store.newTab(kind: .terminal) // tab 2 — now the active tab
        let secondTabComposer = try activeComposer(store)
        XCTAssertNotIdentical(firstTabComposer, secondTabComposer, "precondition: two distinct live panes")

        firstTabComposer.setPinned(true)
        XCTAssertIdentical(
            try XCTUnwrap(store.pinnedComposer).composer, firstTabComposer,
            "precondition: pane A is the single pinned composer",
        )

        // Pin pane B's composer: otty's single window-level pin means A must auto-unpin.
        secondTabComposer.setPinned(true)
        XCTAssertFalse(firstTabComposer.isPinned, "pinning B auto-unpins A (one global pinned composer)")
        XCTAssertTrue(secondTabComposer.isPinned, "B stays pinned")
        let resolved = try XCTUnwrap(store.pinnedComposer)
        XCTAssertIdentical(
            resolved.composer, secondTabComposer,
            "B is the single resolved window-level pinned composer (reachable, with its unpin toggle)",
        )
    }

    func testFloatingComposerResolvesAndClears() throws {
        let store = makeStore()
        let composer = try activeComposer(store)
        XCTAssertNil(store.floatingComposer)

        composer.isFloating = true
        XCTAssertIdentical(try XCTUnwrap(store.floatingComposer).composer, composer)

        composer.isFloating = false
        XCTAssertNil(store.floatingComposer, "docking back drops the float presentation")
    }

    func testResolvedComposerAgentActiveDefaultsFalseForAPlainTerminalPane() throws {
        // The recording double carries no `claudeStatus`, so the float title resolves to "Aislopdesk
        // Composer" (agentActive == false) — no agent-name guessing for a non-agent pane.
        let store = makeStore()
        let composer = try activeComposer(store)
        composer.isFloating = true
        XCTAssertFalse(try XCTUnwrap(store.floatingComposer).agentActive)
    }
}
