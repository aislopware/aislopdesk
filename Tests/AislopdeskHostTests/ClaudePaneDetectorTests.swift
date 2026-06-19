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
}
