import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-6 / ES-E13-6 "Resume" — the STORE seams the History viewer's Resume routes through:
/// ``WorkspaceStore/liveAgentSessionIDs()`` (the jump map) and ``WorkspaceStore/resumeAgentInNewTab(command:)``
/// (the spawn path). Headless — no SwiftUI view, no socket. The spawn test is the revert-to-confirm-fail pin
/// for the original bug: Resume's `.spawn` arm USED to `sendBytes` into the FOCUSED pane (frequently a live
/// agent — so `claude --resume <id>` was typed as a chat prompt INTO the running agent), instead of opening a
/// fresh tab. These FAIL against that behaviour (the focused pane would carry the bytes; no new pane).
@MainActor
final class AgentResumeStoreTests: XCTestCase {
    // MARK: - liveAgentSessionIDs(): only live-agent panes, keyed by their running session id

    func testLiveAgentSessionIDsMapsOnlyPanesHostingALiveAgent() throws {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
        // Two panes: one hosts a live agent session, the other is a plain terminal (no session id).
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let ids = store.tree.allPaneIDs()
        XCTAssertEqual(ids.count, 2)
        let agentPane = ids[0]
        let plainPane = ids[1]
        let agentSession = try XCTUnwrap(store.handle(for: agentPane) as? RecordingTerminalPaneSession)
        agentSession.liveSessionID = "b2d4f6a8-1c3e"
        // plainPane keeps its default nil liveSessionID (no live agent).

        let map = store.liveAgentSessionIDs()
        XCTAssertEqual(map, ["b2d4f6a8-1c3e": agentPane], "only the live-agent pane appears, keyed by its id")
        XCTAssertNil(map.values.first { $0 == plainPane }, "a pane with no live agent session is excluded")
    }

    func testLiveAgentSessionIDsIsEmptyWhenNoPaneHostsAnAgent() {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) }, liveVideoCap: 2,
        )
        XCTAssertTrue(store.liveAgentSessionIDs().isEmpty, "no live agent ⇒ empty map ⇒ every Resume spawns")
    }

    // MARK: - resumeAgentInNewTab(): spawn a FRESH tab + inject VERBATIM (never the focused pane)

    /// A single-pane workspace whose active pane carries NO inherited cwd, so the new tab sends no deferred
    /// `cd` — the new pane's only injected bytes are then exactly the resume command.
    private func makeNoCwdStore() -> (WorkspaceStore, PaneID) {
        let pane = PaneID()
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: nil)]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let store = WorkspaceStore(
            restoringTree: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
        return (store, pane)
    }

    func testResumeAgentInNewTabSpawnsAFreshTabAndInjectsVerbatimNotIntoTheFocusedPane() async throws {
        let (store, originPane) = makeNoCwdStore()
        let origin = try XCTUnwrap(store.handle(for: originPane) as? FakePaneSession)
        let command = AgentResumeRouter.resumeCommand(sessionID: "b2d4f6a8-1c3e") // `claude --resume <id>\n`

        // A 0 ms grace so the deferred inject lands without a 1.4 s wall-clock wait.
        let spawned = try XCTUnwrap(store.resumeAgentInNewTab(command: command, launchGrace: .zero))
        XCTAssertNotEqual(spawned, originPane, "Resume opens a NEW pane, never reuses the focused pane")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "a fresh tab/pane materialized")
        let fresh = try XCTUnwrap(store.handle(for: spawned) as? FakePaneSession)

        // Wait for the deferred inject to land in the fresh pane.
        for _ in 0..<400 where fresh.sentBytes.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            fresh.sentBytes, [Array(command.utf8)],
            "the VERBATIM resume command is delivered to the FRESH tab (literal UTF-8, no SendKeysParser)",
        )
        XCTAssertTrue(
            origin.sentBytes.isEmpty,
            "the FOCUSED pane (frequently a live agent) receives NOTHING — the bug was injecting here",
        )
    }

    func testResumeAgentInNewTabFocusesTheSpawnedPane() throws {
        let (store, _) = makeNoCwdStore()
        let spawned = try XCTUnwrap(store.resumeAgentInNewTab(command: "claude --resume x\n", launchGrace: .zero))
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, spawned,
            "the resumed session's fresh tab is focused",
        )
    }
}
