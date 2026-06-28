import AislopdeskAgentDetect
import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-7 / ES-E13-7 "Fork": pins the PURE ``ForkSessionDetector`` — the `/branch` fingerprint (a NEW
/// Claude session id appearing on the agent signal) and the VERBATIM resume command the detected id feeds.
/// All headless (no SwiftUI view, no socket, no live ``LivePaneSession``). Revert-to-confirm-fail: each
/// assertion checks an exact branch / literal a stub would miss (an always-nil or always-echo detector fails
/// these), never the output against its own derivation.
final class ForkSessionDetectorTests: XCTestCase {
    // MARK: - Helpers

    private func sessionStart(_ id: String?) -> ClaudeSignal { .hook(.sessionStart(sessionID: id)) }

    // MARK: - detectNewSession: the /branch change-detector (before/after signal pair)

    func testFirstSessionStartReportsItsIdAsAChange() {
        // nil → id is a change; the CALLER treats a previous-less first sighting as the BASELINE.
        XCTAssertEqual(ForkSessionDetector.detectNewSession(previous: nil, signal: sessionStart("s1")), "s1")
    }

    func testNewIdAfterABaselineIsDetected() {
        // The literal /branch: a session was running ("s1") and a DIFFERENT id ("s2") now appears.
        XCTAssertEqual(ForkSessionDetector.detectNewSession(previous: "s1", signal: sessionStart("s2")), "s2")
    }

    func testSameIdIsNoChange() {
        // A replay of the SAME session id (e.g. the inspector re-tailing fromSeq:0 on resume) is not a fork.
        XCTAssertNil(ForkSessionDetector.detectNewSession(previous: "s1", signal: sessionStart("s1")))
    }

    func testBeforeAfterPairOnlyForksOnTheSecondDistinctId() {
        // Simulate the fold: the before signal establishes the baseline, the after signal (a new id) forks.
        var baseline: String?
        // BEFORE — first session start seeds the baseline (a nil→id change), no fork yet.
        let first = ForkSessionDetector.detectNewSession(previous: baseline, signal: sessionStart("alpha"))
        XCTAssertEqual(first, "alpha")
        baseline = first
        // AFTER — /branch mints a fresh id → detected as the fork target.
        let forked = ForkSessionDetector.detectNewSession(previous: baseline, signal: sessionStart("beta"))
        XCTAssertEqual(forked, "beta")
    }

    // MARK: - No-id / no-session signals are never a fork

    func testNilSessionIdIsNotAChange() {
        XCTAssertNil(ForkSessionDetector.detectNewSession(previous: "s1", signal: sessionStart(nil)))
    }

    func testWhitespaceSessionIdIsTreatedAsNoId() {
        XCTAssertNil(ForkSessionDetector.detectNewSession(previous: "s1", signal: sessionStart("   ")))
    }

    func testWhitespaceAroundAnIdIsTrimmedBeforeComparing() {
        // A padded id is trimmed: a fresh id surfaces trimmed; the same id (just padded) is no change.
        XCTAssertEqual(ForkSessionDetector.detectNewSession(previous: nil, signal: sessionStart("  s1  ")), "s1")
        XCTAssertNil(ForkSessionDetector.detectNewSession(previous: "s1", signal: sessionStart("  s1  ")))
    }

    func testNonHookSignalsCarryNoSession() {
        for signal: ClaudeSignal in [.tick, .processPresent(true), .processPresent(false), .oscTitle("Claude: x")] {
            XCTAssertNil(
                ForkSessionDetector.detectNewSession(previous: "s1", signal: signal),
                "a \(signal) signal references no Claude session id",
            )
        }
    }

    func testNotificationAndSubagentStopHooksCarryNoSessionId() {
        // A permission notification has no session id; a subagentStop carries an AGENT id, not a Claude
        // session id — neither is a fork even with a non-nil baseline.
        XCTAssertNil(ForkSessionDetector.sessionID(in: .hook(.notification(kind: .permission, label: nil))))
        XCTAssertNil(ForkSessionDetector.sessionID(in: .hook(.subagentStop(agentID: "agent-9"))))
        XCTAssertNil(
            ForkSessionDetector.detectNewSession(
                previous: "s1", signal: .hook(.subagentStop(agentID: "agent-9")),
            ),
            "a subagent stop's agentID must never read as a new Claude session id",
        )
    }

    // MARK: - sessionID(in:) extracts from every id-carrying hook

    func testSessionIdExtractedFromIdCarryingHooks() {
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.sessionStart(sessionID: "a"))), "a")
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.userPromptSubmit(sessionID: "b"))), "b")
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.preToolUse(sessionID: "c", tool: "Bash"))), "c")
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.postToolUse(sessionID: "d", tool: "Bash"))), "d")
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.stop(sessionID: "e", label: "done"))), "e")
        XCTAssertEqual(ForkSessionDetector.sessionID(in: .hook(.sessionEnd(sessionID: "f"))), "f")
    }

    // MARK: - The detected id feeds the VERBATIM resume command

    func testDetectedForkIdFeedsVerbatimResumeCommand() {
        // The fork action runs `claude --resume <new-id>` VERBATIM (single source of truth = AgentResumeRouter,
        // never SendKeysParser). A detected id must interpolate AS-IS — including a hostile id with shell-meta.
        let detected = ForkSessionDetector.detectNewSession(previous: "old", signal: sessionStart("br-7;rm -rf"))
        XCTAssertEqual(detected, "br-7;rm -rf")
        XCTAssertEqual(
            AgentResumeRouter.resumeCommand(sessionID: detected ?? ""),
            "claude --resume br-7;rm -rf\n",
            "the detected branch id is run VERBATIM (the routing sends literal bytes, no parser)",
        )
    }
}
