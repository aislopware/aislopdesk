import XCTest
@testable import AislopdeskClientUI

/// Pins the command-palette recents ring on the store (dedup-to-front, capped).
@MainActor
final class PaletteRecentsTests: XCTestCase {

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) })
    }

    func testRecordPrependsDedupsAndCaps() {
        let store = makeStore()
        store.recordRecentCommand(.tidy)
        store.recordRecentCommand(.centerAll)
        XCTAssertEqual(store.recentCommands, [.centerAll, .tidy])
        store.recordRecentCommand(.tidy)
        XCTAssertEqual(store.recentCommands, [.tidy, .centerAll], "a repeat moves to front")

        let many: [WorkspaceCommand] = [.newGroup, .toggleZoom, .toggleOverview,
                                        .reopenClosedPane, .duplicatePane, .centerFocusedPane]
        for c in many { store.recordRecentCommand(c) }
        XCTAssertEqual(store.recentCommands.count, WorkspaceStore.recentCommandsCap)
        XCTAssertEqual(store.recentCommands.first, .centerFocusedPane, "newest first")
    }
}
