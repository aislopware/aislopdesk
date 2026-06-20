import AislopdeskAgentDetect
import AislopdeskProtocol
import XCTest
@testable import AislopdeskHost

/// P1 (review #1–#4, #9) — the SINGLE per-pane ``ClaudePaneDetector`` is the host's one source of truth.
///
/// These tests drive the ONE detector with the full mix of inputs the live ``MuxChannelSession`` feeds it
/// — the foreground poll's `sample`, the per-poll `tick`, and the hook socket's `hook(bytes:)` — and
/// assert (a) the `.done→.idle` decay is now DRIVEN by ticks, (b) a presence flap can't clobber a hook
/// block, (c) the host's emitted type-27 `state` byte maps to EXACTLY the host's machine status on the
/// client (no divergence — the client just calls `ClaudeStatus(urgency:)`), and (d) a `claude`-prefixed
/// process name is NOT treated as claude (exact basename) and emits NO status churn (no inspector flap).
///
/// Pure + headless: the detector is value-in/value-out (no PTY/socket/syscall — the `PTYForegroundProbe`
/// and `UnixSocketAcceptor` shims are compiled + code-reviewed only). The clock is injected.
final class ClaudePaneDetectorTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// The EXACT client mapping (`LivePaneSession.feedAgentSignal` calls this on the type-27 `state`
    /// byte). Asserting against it proves host/client agreement without a cross-module import.
    private func clientStatus(forStateByte state: UInt8) -> ClaudeStatus {
        ClaudeStatus(urgency: Int(state))
    }

    /// Pulls the `(state)` byte out of an emitted type-27 message, failing if it is not a `claudeStatus`.
    private func stateByte(_ message: WireMessage?, _ file: StaticString = #filePath, _ line: UInt = #line) -> UInt8? {
        guard case let .claudeStatus(state, _, _)? = message else {
            if message != nil { XCTFail("expected a claudeStatus type-27, got \(message!)", file: file, line: line) }
            return nil
        }
        return state
    }

    // MARK: - (a) Decay is DRIVEN by ticks (the host emits a type-27 `.idle` after the timeout)

    /// A Stop hook puts the machine in `.done`; with NO further hook (the Stop hook fired and stopped),
    /// only TICKS advance time — and a tick past the timeout must emit a type-27 `.idle`. Pre-P1 nobody
    /// ticked the host machine, so a finished turn stayed `.done` (🔵) forever (review #4).
    func testStopThenOnlyTicksEmitsIdleAfterTimeout() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        // Hook: Stop → done. (No foreground sample needed — the hook drives presence-independent status.)
        let stop = d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#), at: 0)
        XCTAssertEqual(stateByte(stop.status), 2, "Stop → done (urgency 2)")
        XCTAssertEqual(d.status, .done)

        // A tick BEFORE the timeout changes nothing (dedupe — still done).
        let early = d.tick(at: 4)
        XCTAssertNil(early.status, "still done before the timeout — no new type-27")

        // A tick AT/AFTER the timeout decays to idle and EMITS the type-27 (the host pushes the decay).
        let decayed = d.tick(at: 6)
        XCTAssertEqual(d.status, .idle, "the decay fired — driven by the tick")
        XCTAssertEqual(stateByte(decayed.status), 1, "host emits type-27 idle (urgency 1) on the decay")
    }

    // MARK: - (b) A presence re-sample does NOT clobber a hook-set `.needsPermission`

    /// The review-#3 flap (a child process taking the PTY) is defended on the CLIENT (a type-26 edge is
    /// display-only there — see `ClaudeStatusWiringTests`). On the HOST, the realistic in-turn case is a
    /// hook block followed by a CONTINUED claude presence (the kernel keeps reporting `claude` for a
    /// claude turn) plus the 1 Hz tick — the block must SURVIVE: presence is a floor that never
    /// downgrades a richer hook status, and a redundant `sample("claude")` must not knock it back to idle.
    func testContinuedClaudePresenceKeepsHookBlock() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: json(#"{"hook_event_name":"Notification","message":"needs your permission"}"#), at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        // The 1 Hz poll re-reads `claude` (+ a tick) — presence is a floor, it must NOT downgrade.
        _ = d.tick(at: 2)
        let resample = d.sample(name: "claude", at: 2)
        XCTAssertEqual(d.status, .needsPermission, "a redundant claude presence must not clear the hook block")
        XCTAssertNil(resample.status, "no status change → no type-27 churn (dedupe)")
    }

    // MARK: - (c) The client status EQUALS the host's type-27 verdict (no divergence)

    /// For a representative signal sequence, every host-emitted type-27 `state` byte maps (via the EXACT
    /// client mapping `ClaudeStatus(urgency:)`) back to the host machine's OWN status — proving the client
    /// (a passive display) can never diverge from the host's verdict.
    func testEmittedStateByteMatchesHostStatusForClient() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        func assertAgrees(_ e: ClaudePaneDetector.Emission, _ file: StaticString = #filePath, _ line: UInt = #line) {
            guard let state = stateByte(e.status) else { return } // deduped → no frame, nothing to compare
            XCTAssertEqual(
                clientStatus(forStateByte: state), d.status,
                "the client maps the emitted byte to the host's own status (no divergence)",
                file: file, line: line,
            )
        }
        assertAgrees(d.sample(name: "claude", at: 0)) // → idle
        assertAgrees(d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit"}"#), at: 1)) // → working
        assertAgrees(d.hook(
            bytes: json(#"{"hook_event_name":"Notification","message":"needs your permission"}"#),
            at: 2,
        ))
        assertAgrees(d.hook(bytes: json(#"{"hook_event_name":"Stop","last_assistant_message":"done"}"#), at: 3))
        assertAgrees(d.tick(at: 9)) // decay → idle
        assertAgrees(d.sample(name: "zsh", at: 10)) // claude gone → none
    }

    // MARK: - (d) `claude-monitor` / `myclaudewrapper` is NOT claude (exact basename, no flap)

    /// A process whose name merely CONTAINS "claude" (`claude-monitor`, `myclaudewrapper`) is NOT claude
    /// (exact basename match). The host status stays `.none`, the client (mapping byte 0) agrees, and
    /// because the status never lifts off `.none` there is no type-27 churn that would flap the inspector.
    func testClaudePrefixedProcessIsNotClaudeNoInspectorFlap() {
        for name in ["claude-monitor", "myclaudewrapper", "/usr/local/bin/claude-monitor"] {
            var d = ClaudePaneDetector()
            let e = d.sample(name: name, at: 0)
            XCTAssertEqual(d.status, .none, "\(name) must not be treated as claude (exact basename)")
            // The first sample emits the anchor type-27 (none); the client maps byte 0 → .none (agreement).
            if let state = stateByte(e.status) {
                XCTAssertEqual(state, 0)
                XCTAssertEqual(clientStatus(forStateByte: state), .none, "host + client agree it is not claude")
            }
            // A second identical sample emits NO further type-27 → no inspector flap on the client.
            let again = d.sample(name: name, at: 1)
            XCTAssertNil(again.status, "an unchanged non-claude name does not churn type-27 (no inspector flap)")
        }
    }

    // MARK: - (P5 #6) Dedupe is COUNTED, not just nil-checked

    /// A genuine dedupe assertion: COUNT the type-27 frames emitted across a stream that repeats the same
    /// status, and assert exactly one frame ships per DISTINCT `(state,kind,label)` triple. With the
    /// dedupe guard removed, every fold would emit a frame (the count would balloon) — so this fails
    /// loudly if the guard regresses, unlike a single `XCTAssertNil` on one repeat.
    func testRepeatedIdenticalStatusEmitsExactlyOneType27() {
        var d = ClaudePaneDetector(doneToIdleTimeout: 5)
        var emittedStates: [UInt8] = []
        func feedHook(_ json: String, at t: TimeInterval) {
            if let s = stateByte(d.hook(bytes: self.json(json), at: t).status) { emittedStates.append(s) }
        }
        func feedTick(at t: TimeInterval) {
            if let s = stateByte(d.tick(at: t).status) { emittedStates.append(s) }
        }
        // working ×3 (2 dups), block ×2 (1 dup), then idle on decay; plus quiet ticks that change nothing.
        feedHook(#"{"hook_event_name":"UserPromptSubmit"}"#, at: 0) // working
        feedHook(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#, at: 1) // working (dup triple)
        feedTick(at: 2) // no change → no frame
        feedHook(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#, at: 3) // working (dup triple)
        feedHook(#"{"hook_event_name":"Stop","last_assistant_message":"ok"}"#, at: 4) // done
        feedTick(at: 5) // no change yet (timeout is 5 from t=4 → not due)
        feedTick(at: 9) // decay → idle
        feedTick(at: 10) // idle, no change → no frame

        XCTAssertEqual(
            emittedStates, [3, 2, 1],
            "exactly one type-27 per distinct status (working 3, done 2, idle 1) — repeats + quiet ticks deduped",
        )
    }

    // MARK: - type-26 is a basename edge only (a display hint, not a status source)

    /// type-26 (`foregroundProcess`) fires only on a basename EDGE and is independent of the type-27
    /// status stream — a coarse display hint, never a second status source (review #2).
    func testType26IsBasenameEdgeOnly() {
        var d = ClaudePaneDetector()
        let first = d.sample(name: "zsh", at: 0)
        XCTAssertEqual(first.foreground, .foregroundProcess(name: "zsh"), "first sample emits the basename")
        let same = d.sample(name: "zsh", at: 1)
        XCTAssertNil(same.foreground, "an unchanged basename does not re-emit type-26 (dedupe)")
        let edge = d.sample(name: "claude", at: 2)
        XCTAssertEqual(edge.foreground, .foregroundProcess(name: "claude"), "a basename change re-emits type-26")
    }

    // MARK: - PIECE 4: agent self-report folds as an authoritative hook

    /// A self-report `working`/`blocked`/`done`/`idle` maps to the same machine verdict an
    /// equivalent real hook would. Each is precedence-2 (authoritative), so it beats the bare
    /// foreground-process presence FLOOR (which only lifts `.none → .idle`).
    func testReportWorkingBlockedDoneIdle() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0) // presence floor = idle

        let working = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working)
        XCTAssertEqual(stateByte(working.status), 3, "working → urgency 3")

        let blocked = d.report(state: "blocked", message: "approve?", at: 2)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertEqual(stateByte(blocked.status), 4, "blocked → needsPermission urgency 4")

        let done = d.report(state: "done", message: "all set", at: 3)
        XCTAssertEqual(d.status, .done)
        XCTAssertEqual(stateByte(done.status), 2, "done → urgency 2")

        let idle = d.report(state: "idle", message: nil, at: 4)
        XCTAssertEqual(d.status, .idle)
        XCTAssertEqual(stateByte(idle.status), 1, "idle → urgency 1")
    }

    /// Self-report beats the foreground heuristic: with NO claude present (presence would force
    /// `.none`), a `working` report still lifts the status — the authoritative hook fold wins.
    func testReportBeatsForegroundFloor() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "zsh", at: 0) // not claude → status .none
        XCTAssertEqual(d.status, .none)
        _ = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working, "the self-report is authoritative; presence floor cannot override it")
    }

    /// An unknown report state is a no-op (validate-then-drop) — no emission, no status change.
    func testReportUnknownStateIsNoOp() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let before = d.status
        let e = d.report(state: "frobnicating", message: nil, at: 1)
        XCTAssertNil(e.status, "unknown state emits nothing")
        XCTAssertEqual(d.status, before, "unknown state does not change the machine")
    }

    /// A self-report is STICKY against the ~1 Hz foreground poll: after `report(working)`, a
    /// following `tick` + `sample(name: non-claude)` (the supervised case — a custom orchestrator /
    /// node-wrapped CLI whose basename is NOT `claude`) must NOT wipe the reported state for the
    /// grace window. Without the stickiness floor, `sample`'s `processPresent(false)` terminates the
    /// machine ~1s after the report, fanning a spurious working→idle/none. This FAILS on the
    /// pre-fix code (the report is wiped on the very next poll).
    func testReportStickyAgainstForegroundAbsence() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "node", at: 0) // a non-claude wrapper → status .none
        XCTAssertEqual(d.status, .none)
        _ = d.report(state: "working", message: nil, at: 1)
        XCTAssertEqual(d.status, .working, "the self-report lifts the status")

        // The very next foreground poll (~1s later): a tick + a non-claude sample. Pre-fix this
        // terminated the machine; with the stickiness floor the reported state survives.
        _ = d.tick(at: 2)
        let resample = d.sample(name: "node", at: 2)
        XCTAssertEqual(d.status, .working, "a non-claude presence-absence must not wipe a recent self-report")
        XCTAssertNil(resample.status, "no transition → no spurious type-27 churn")

        // Several more polls within the grace window keep it sticky.
        _ = d.sample(name: "node", at: 10)
        XCTAssertEqual(d.status, .working, "still sticky well inside the grace window")
    }

    /// The stickiness floor LAPSES: once the grace window elapses with the agent still absent
    /// (genuinely exited), a foreground-absence sample DOES terminate — a stale report does not
    /// pin the pane forever. Complements ``testReportStickyAgainstForegroundAbsence``.
    func testReportStickinessLapsesAfterGraceWindow() {
        var d = ClaudePaneDetector()
        _ = d.report(state: "working", message: nil, at: 0)
        XCTAssertEqual(d.status, .working)
        // A sample PAST the grace window with no claude present → the agent really left → terminate.
        let late = ClaudePaneDetector.reportGraceWindow + 1
        let e = d.sample(name: "node", at: late)
        XCTAssertEqual(d.status, .none, "after the grace window a non-claude absence terminates as before")
        XCTAssertNotNil(e.status, "the termination emits a type-27 transition")
    }

    /// A repeated identical self-report dedupes (no second type-27) — the change-hook only fires
    /// on a real transition.
    func testRepeatedReportDedupes() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let first = d.report(state: "working", message: nil, at: 1)
        XCTAssertNotNil(first.status, "first working report emits")
        let second = d.report(state: "working", message: nil, at: 2)
        XCTAssertNil(second.status, "an identical consecutive report dedupes (no new type-27)")
    }
}
