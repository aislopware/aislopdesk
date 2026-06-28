import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-6 / ES-E13-6 "Resume": pins the PURE ``AgentResumeRouter`` — the VERBATIM `claude --resume <id>\n`
/// command string and the jump-vs-spawn decision off the live-pane map. All headless (no SwiftUI view, no
/// socket). Revert-to-confirm-fail: each assertion checks an exact literal / branch a stub router would miss
/// (a no-op `resumeCommand` or an always-spawn `target` fails these).
final class AgentResumeRouterTests: XCTestCase {
    // MARK: - resumeCommand: VERBATIM `claude --resume <id>` + a single trailing newline

    func testResumeCommandIsVerbatimClaudeResumeWithTrailingNewline() {
        XCTAssertEqual(
            AgentResumeRouter.resumeCommand(sessionID: "abc-123"),
            "claude --resume abc-123\n",
            "the resume verb is the literal `claude --resume <id>` with exactly one submitting newline",
        )
    }

    func testResumeCommandInterpolatesIdVerbatim() {
        // The host reports `AgentSessionInfo.id` as an absolute .jsonl path; it is interpolated AS-IS (no
        // escaping / no SendKeysParser) — parity with the existing Open-Quickly resume path.
        let path = "/Users/x/.claude/projects/p/b2d4f6a8-1c3e.jsonl"
        XCTAssertEqual(
            AgentResumeRouter.resumeCommand(sessionID: path),
            "claude --resume \(path)\n",
        )
    }

    // MARK: - target: spawn when no live pane runs the session

    func testTargetSpawnsWhenNoLivePane() {
        let target = AgentResumeRouter.target(sessionID: "sess-1", liveSessionIDs: [:])
        XCTAssertEqual(target, .spawn(command: "claude --resume sess-1\n"))
    }

    func testTargetSpawnCarriesResumeCommand() {
        // The spawn case's command is exactly `resumeCommand(sessionID:)` (single source of truth).
        let target = AgentResumeRouter.target(sessionID: "sess-2", liveSessionIDs: [:])
        XCTAssertEqual(target, .spawn(command: AgentResumeRouter.resumeCommand(sessionID: "sess-2")))
    }

    func testTargetSpawnsWhenADifferentSessionIsLive() {
        // A live pane for a DIFFERENT session must not divert this id to a jump.
        let other = PaneID()
        let target = AgentResumeRouter.target(sessionID: "sess-1", liveSessionIDs: ["sess-9": other])
        XCTAssertEqual(target, .spawn(command: "claude --resume sess-1\n"))
    }

    // MARK: - target: jump when a live pane already runs the session

    func testTargetJumpsToLivePaneRunningTheSession() {
        let pane = PaneID()
        let target = AgentResumeRouter.target(sessionID: "sess-1", liveSessionIDs: ["sess-1": pane])
        XCTAssertEqual(target, .jumpTo(pane), "a live tab running the exact session is focused, not duplicated")
    }

    func testTargetJumpsToTheMatchingPaneAmongMany() {
        let wanted = PaneID()
        let target = AgentResumeRouter.target(
            sessionID: "sess-2",
            liveSessionIDs: ["sess-1": PaneID(), "sess-2": wanted, "sess-3": PaneID()],
        )
        XCTAssertEqual(target, .jumpTo(wanted))
    }

    // MARK: - target: CANONICAL match (host file-path id ⇄ live bare session id)

    func testTargetJumpsWhenHostPathIdMatchesABareLiveId() {
        // The host reports `AgentSessionInfo.id` as an absolute `<id>.jsonl` path; a live pane advertises the
        // BARE `<id>` off its inspector channel. Without canonical matching the jump branch is DEAD (every
        // Resume spawns) — this fails on a bare-equality `target`.
        let pane = PaneID()
        let path = "/Users/x/.claude/projects/p/b2d4f6a8-1c3e.jsonl"
        let target = AgentResumeRouter.target(sessionID: path, liveSessionIDs: ["b2d4f6a8-1c3e": pane])
        XCTAssertEqual(target, .jumpTo(pane), "a path-form id resolves to the live tab running its bare id")
    }

    func testTargetStillSpawnsWhenNoCanonicalMatch() {
        // A path id whose bare leaf matches NO live session still spawns, carrying the VERBATIM path id.
        let path = "/Users/x/.claude/projects/p/aaaa-1111.jsonl"
        let target = AgentResumeRouter.target(sessionID: path, liveSessionIDs: ["bbbb-2222": PaneID()])
        XCTAssertEqual(target, .spawn(command: "claude --resume \(path)\n"))
    }

    // MARK: - canonicalSessionID: leaf with the extension stripped, bare id unchanged

    func testCanonicalSessionIDStripsPathAndExtension() {
        XCTAssertEqual(
            AgentResumeRouter.canonicalSessionID("/Users/x/.claude/projects/p/b2d4f6a8-1c3e.jsonl"),
            "b2d4f6a8-1c3e",
        )
    }

    func testCanonicalSessionIDLeavesABareIdUnchanged() {
        XCTAssertEqual(AgentResumeRouter.canonicalSessionID("b2d4f6a8-1c3e"), "b2d4f6a8-1c3e")
        XCTAssertEqual(AgentResumeRouter.canonicalSessionID("sess-1"), "sess-1")
    }
}
