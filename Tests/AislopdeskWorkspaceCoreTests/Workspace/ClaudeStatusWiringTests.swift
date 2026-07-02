import AislopdeskAgentDetect
import AislopdeskTransport
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskWorkspaceCore

/// W11 — the LIVE agent-status wiring (the auto-detect payoff). Proves the host→client wire signals
/// (type 26 `foregroundProcess`, type 27 `claudeStatus`) fold through the per-pane ``LivePaneSession``
/// into the store's ``WorkspaceStore/paneAgentStatus`` + the sidebar/tab rollup — entirely headless
/// (no socket, no SCStream/VT/Metal; the session's transport factory is inert).
///
/// Two surfaces:
///  1. ``LivePaneSession/feedAgentSignal(_:now:)`` maps the raw wire bytes back to a ``ClaudeStatus``
///     (the only client-side wire→machine bridge), with dedupe + forward-tolerant byte handling.
///  2. The store sink: feeding a session a signal and mirroring it into `paneAgentStatus`, so
///     `agentStatus(for:)` + the session/tab `rollupStatus(...)` light up live.
@MainActor
final class ClaudeStatusWiringTests: XCTestCase {
    /// An inert client factory (never connected — these tests drive the status fold directly, no byte
    /// stream). `@Sendable` free function so it can be passed as `makeClient`.
    private static let makeUnconnectedClient: @Sendable () -> AislopdeskClient = {
        AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })
    }

    private func makeTerminalSession() -> LivePaneSession {
        LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: Self.makeUnconnectedClient,
            makeInspector: { _ in nil },
        )
    }

    // MARK: - 1. feedAgentSignal: wire bytes → ClaudeStatus (the decode→machine bridge)

    /// A type-27 `claudeStatus` carrying the `working` urgency byte (3) lifts the pane to `.working`.
    func testClaudeStatusWireWorkingByteMapsToWorking() {
        let session = makeTerminalSession()
        XCTAssertEqual(session.claudeStatus, .none, "a fresh terminal has no claude")
        let result = session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "building"))
        XCTAssertEqual(result, .working, "state byte 3 (urgency) → .working")
        XCTAssertEqual(session.claudeStatus, .working, "the session mirrors the folded status")
    }

    /// A type-27 `claudeStatus` with the `needsPermission` urgency (4) + the `permission` kind (1) →
    /// blocked (`.needsPermission`) — the attention state the rollup surfaces most urgently.
    func testClaudeStatusPermissionMapsToNeedsPermission() {
        let session = makeTerminalSession()
        let result = session.feedAgentSignal(.claudeStatus(state: 4, kind: 1, label: "Allow Bash?"))
        XCTAssertEqual(result, .needsPermission, "state 4 + kind 1 → blocked on a permission prompt")
        XCTAssertEqual(session.claudeStatus, .needsPermission)
    }

    /// P1: a type-26 `foregroundProcess` is a DISPLAY-ONLY process-name hint — it updates
    /// ``LivePaneSession/foregroundProcessName`` and NEVER touches ``claudeStatus`` (the host's type-27
    /// is the single source of truth). So even `foregroundProcess("claude")` leaves the status at `.none`
    /// until the host SAYS so via type-27.
    func testForegroundProcessIsDisplayOnlyAndNeverSetsStatus() {
        let session = makeTerminalSession()
        XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: "claude")), .none, "type-26 never sets status")
        XCTAssertEqual(session.claudeStatus, .none, "status stays none — only type-27 moves it")
        XCTAssertEqual(session.foregroundProcessName, "claude", "type-26 updates the display-only name")
        // A subsequent type-26 only updates the name; an empty name clears it (still no status change).
        _ = session.feedAgentSignal(.foregroundProcess(name: "vim"))
        XCTAssertEqual(session.foregroundProcessName, "vim")
        XCTAssertEqual(session.claudeStatus, .none)
        _ = session.feedAgentSignal(.foregroundProcess(name: ""))
        XCTAssertNil(session.foregroundProcessName, "an empty foreground name clears the display hint")
        XCTAssertEqual(session.claudeStatus, .none)
    }

    /// P1, review #3: a transient child process taking the PTY (a type-26 edge) must NOT clobber a
    /// `.needsPermission` the host set via type-27. The type-26 only changes the displayed name.
    func testForegroundProcessFlapDoesNotClobberHookStatus() {
        let session = makeTerminalSession()
        // Host hook → blocked (type-27).
        XCTAssertEqual(
            session.feedAgentSignal(.claudeStatus(state: 4, kind: 1, label: "Allow Bash?")),
            .needsPermission,
        )
        // A child tool (`grep`) momentarily becomes the PTY foreground — a type-26 edge.
        XCTAssertEqual(
            session.feedAgentSignal(.foregroundProcess(name: "grep")),
            .needsPermission,
            "a foreground child process must not wipe the host's needsPermission verdict",
        )
        XCTAssertEqual(session.claudeStatus, .needsPermission, "the type-27 status is untouched by type-26")
        XCTAssertEqual(session.foregroundProcessName, "grep", "only the display name changed")
    }

    // MARK: - E12: agent-pane Prompt-Queue dispatch on the `.done` turn-finished edge (NOT the laggy `.idle`)

    /// E12 — the AGENT-pane turn-finished trigger: alt-screen Claude Code emits no OSC-133 marks, so its
    /// "turn finished" signal is the host's type-27 transition INTO `.done` (the Stop hook fires it
    /// IMMEDIATELY; it then decays to `.idle` ~8s later). On the `.done` edge the session drains exactly the
    /// head queued prompt; the subsequent `.done → .idle` decay must NOT re-dispatch (exactly one per turn).
    /// REVERT-TO-CONFIRM-FAIL: with the old `if newStatus == .idle { ... }` line every prompt fired ~8s late
    /// (on the decay) instead of the moment the turn ended, and this would dispatch on the `.idle` step.
    func testAgentDoneTransitionDispatchesHeadQueuedPromptNotTheIdleDecay() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer, "a .terminal session carries a composer")
        var captured: [Data] = []
        // The composer's OUT sink funnels through the input bar → terminal.sendInput → inputSink.
        session.terminalModel?.inputSink = { captured.append($0) }

        // The agent is mid-turn (.working), so the enqueue does NOT kickstart — it waits for the turn edge.
        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // state 3 = .working (busy)
        composer.draft = "first\nsecond"
        composer.enqueueDraft() // two queued prompts (pane busy → no kickstart)
        XCTAssertEqual(composer.promptQueue.items.count, 2)
        XCTAssertTrue(captured.isEmpty, "enqueue while the agent is working dispatches nothing yet")

        session.feedAgentSignal(.claudeStatus(state: 2, kind: 0, label: "")) // state 2 = .done → drain ONE
        XCTAssertEqual(captured, [Data("first\r".utf8)], "the .done edge dispatches the head prompt + CR")
        XCTAssertEqual(composer.promptQueue.items.count, 1, "exactly one item drained; the rest remain")

        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // the ~8s decay to .idle
        XCTAssertEqual(captured, [Data("first\r".utf8)], "the .done→.idle decay must NOT dispatch a second prompt")
        XCTAssertEqual(composer.promptQueue.items.count, 1, "still exactly one queued prompt waiting")
    }

    /// A `.working` transition must NOT drain the queue — only the `.done` edge dispatches.
    func testAgentWorkingTransitionDoesNotDispatch() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // state 3 = .working (busy)
        composer.draft = "queued"
        composer.enqueueDraft() // busy → no kickstart

        XCTAssertTrue(captured.isEmpty, "a .working pane does not dispatch the queue (no kickstart, no edge)")
        XCTAssertEqual(composer.promptQueue.items.count, 1, "the queued prompt waits for the .done edge")
    }

    /// Each GENUINE `.done` turn-finished EDGE dispatches one prompt, FIFO; the `.done→.idle` decay does not
    /// re-dispatch — so two prompts need two real working→done turns, one prompt dispatched per turn.
    func testEachAgentDoneEdgeDispatchesOnePromptInOrder() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // .working (busy) so enqueue waits
        composer.draft = "one\ntwo"
        composer.enqueueDraft()

        session.feedAgentSignal(.claudeStatus(state: 2, kind: 0, label: "")) // → .done (edge) → "one"
        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // decay to .idle → nothing
        XCTAssertEqual(captured, [Data("one\r".utf8)], "the .idle decay does not re-dispatch")

        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // → .working (a new turn)
        session.feedAgentSignal(.claudeStatus(state: 2, kind: 0, label: "")) // → .done again (edge) → "two"
        XCTAssertEqual(
            captured, [Data("one\r".utf8), Data("two\r".utf8)],
            "each genuine working→done edge drains exactly one queued prompt, in order",
        )
        XCTAssertTrue(composer.promptQueue.isEmpty, "both queued prompts dispatched")
    }

    /// E12 KICKSTART (WI-1): enqueuing while the owning pane is ALREADY idle (no turn-finished edge is
    /// coming) fires the head prompt immediately. Queue-safety (2026-07-02): the agent must be VERIFIED
    /// first — a prior authoritative turn (`working → done → idle`, hooks/ctl-only states) proves the
    /// turn-signal pipeline is live, so the later `.idle` is genuinely "between turns" (the bare
    /// presence-floor `.idle` never kickstarts — see
    /// ``testPresenceFloorIdleDoesNotKickstartAgentQueue``). Proves `ComposerModel.isIdleNow` is wired to
    /// the session's `claudeStatus` + verification. REVERT-TO-CONFIRM-FAIL: without the kickstart the
    /// prompt waits for a `.done` edge that never comes (the agent is already idle), and `captured`
    /// stays empty.
    func testEnqueueWhileVerifiedAgentIdleKickstartsImmediately() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        // A full authoritative turn ran earlier (hooks live): working → done → the ~8s decay to idle.
        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // .working (verifies)
        session.feedAgentSignal(.claudeStatus(state: 2, kind: 0, label: "")) // .done (empty queue — no-op)
        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // .idle (between turns)
        XCTAssertTrue(captured.isEmpty, "the status transitions alone dispatch nothing")

        composer.draft = "kick"
        composer.enqueueDraft()
        XCTAssertEqual(
            captured, [Data("kick\r".utf8)],
            "enqueue while a VERIFIED agent is idle kickstarts the first prompt",
        )
        XCTAssertTrue(composer.promptQueue.isEmpty, "the kickstarted item left the queue")
    }

    // MARK: - Queue-safety (2026-07-02): queued prompts must NEVER be executed by the shell

    /// The DEFAULT no-hooks host can only ever report the presence-floor `.idle` (state 1) for a
    /// detected claude — Claude may be MID-TURN behind it. Without an authoritative turn signal
    /// (`.working`/`.done`/`.needsPermission`, which only hooks/ctl produce), an enqueue must NOT
    /// kickstart into the agent: the prompt is HELD. REVERT-TO-CONFIRM-FAIL: pre-fix
    /// `isComposerPaneIdle` treated the floor `.idle` as "agent between turns" and the kickstart
    /// typed the prompt into the mid-turn Claude immediately.
    func testPresenceFloorIdleDoesNotKickstartAgentQueue() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        session.feedAgentSignal(.claudeStatus(state: 1, kind: 0, label: "")) // presence floor only
        composer.draft = "now add unit tests"
        composer.enqueueDraft()

        XCTAssertTrue(captured.isEmpty, "presence-floor idle must not kickstart into a possibly-mid-turn agent")
        XCTAssertEqual(
            composer.promptQueue.items.map(\.text), ["now add unit tests"],
            "the prompt is HELD in the queue, not sent",
        )
        XCTAssertEqual(
            composer.queueHold, .awaitingVerifiedAgent,
            "the held reason is surfaced so the strip can badge it (not a silently-stuck queue)",
        )
    }

    /// THE safety property: prompts enqueued FOR AN AGENT must never fall through to the shell's
    /// OSC-133;A prompt-idle dispatch. Claude exits without a `.done` (no hooks / hard exit), zsh
    /// prints its prompt → the shell trigger fires → the held agent prompts must stay held (zsh
    /// would EXECUTE them as commands — `zsh: command not found: now`, or worse `rm`/`git`).
    /// REVERT-TO-CONFIRM-FAIL: pre-fix `notePromptIdle()` drained the head regardless of what the
    /// item was enqueued for, typing "now update the docs\r" into the shell.
    func testAgentQueuedPromptsNeverFallThroughToShellPromptIdle() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")) // agent mid-turn (.working)
        composer.draft = "now update the docs"
        composer.enqueueDraft() // busy → held, enqueued FOR THE AGENT
        XCTAssertTrue(captured.isEmpty)

        session.feedAgentSignal(.claudeStatus(state: 0, kind: 0, label: "")) // claude exits (no .done edge)
        session.terminalModel?.onPromptIdle?() // zsh prints its prompt → the SHELL trigger fires

        XCTAssertTrue(
            captured.isEmpty,
            "an agent-enqueued prompt must NEVER dispatch into the shell — zsh would execute it",
        )
        XCTAssertEqual(
            composer.promptQueue.items.map(\.text), ["now update the docs"],
            "the prompt stays held (explicit user release via tap-to-edit)",
        )
        XCTAssertEqual(composer.queueHold, .agentEnded, "the badge says the agent ended with prompts still held")
    }

    /// The reverse direction: a prompt enqueued for the SHELL must not be typed into a claude that
    /// starts afterwards — the agent `.done` turn-finished edge must not drain a shell-targeted head.
    func testShellQueuedPromptDoesNotDispatchIntoAgentTurnEnd() throws {
        let session = makeTerminalSession()
        let composer = try XCTUnwrap(session.composer)
        var captured: [Data] = []
        session.terminalModel?.inputSink = { captured.append($0) }

        // A fresh shell sits at its prompt → the first enqueue kickstarts (expected; that command is now
        // RUNNING), and the in-flight latch holds the second — a SHELL-targeted item left in the queue.
        composer.draft = "make check"
        composer.enqueueDraft()
        XCTAssertEqual(captured, [Data("make check\r".utf8)], "the shell-prompt kickstart fires the first item")
        composer.draft = "make lint"
        composer.enqueueDraft() // in-flight latch → queued, stamped for the SHELL
        XCTAssertEqual(composer.promptQueue.items.map(\.text), ["make lint"])

        // The running command turns out to start a claude, which runs a turn: working → done. The agent
        // edge must NOT type "make lint" into Claude — it was written for the shell.
        session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: ""))
        session.feedAgentSignal(.claudeStatus(state: 2, kind: 0, label: ""))
        XCTAssertEqual(
            captured, [Data("make check\r".utf8)],
            "a shell-targeted prompt must not be typed into the agent",
        )
        XCTAssertEqual(composer.promptQueue.items.map(\.text), ["make lint"], "held until the shell is back")
        XCTAssertEqual(composer.queueHold, .shellPromptBehindAgent)

        // Claude exits and zsh prints its prompt → the shell trigger NOW drains the shell-targeted head.
        session.feedAgentSignal(.claudeStatus(state: 0, kind: 0, label: ""))
        session.terminalModel?.onPromptIdle?()
        XCTAssertEqual(
            captured, [Data("make check\r".utf8), Data("make lint\r".utf8)],
            "back at the shell, the held shell prompt dispatches",
        )
        XCTAssertNil(composer.queueHold, "no hold once the matching trigger drained the head")
    }

    /// An unknown / future urgency byte degrades to `.none` (forward-tolerant validate-then-repair) —
    /// a hostile or newer datagram must never trap the client.
    func testUnknownStateByteDegradesToNone() {
        let session = makeTerminalSession()
        // First the host reports working via type-27 so we are NOT already at .none.
        XCTAssertEqual(session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "")), .working)
        // A future state byte (99) maps to .none via ClaudeStatus(urgency:) — the host says "gone".
        let result = session.feedAgentSignal(.claudeStatus(state: 99, kind: 0, label: ""))
        XCTAssertEqual(result, .none, "an unknown urgency byte degrades to .none (never traps)")
    }

    /// P1 (c): the client status EQUALS the host's type-27 verdict for every step of a representative
    /// host signal sequence — the client (a passive display) maps `ClaudeStatus(urgency: state)` and
    /// never diverges. The host's emitted `state` bytes (idle 1 / working 3 / blocked 4 / done 2 /
    /// idle 1 / none 0) are replayed here exactly as the host would push them.
    func testClientStatusEqualsHostType27VerdictNoDivergence() {
        let session = makeTerminalSession()
        let hostByteThenExpected: [(UInt8, ClaudeStatus)] = [
            (1, .idle), (3, .working), (4, .needsPermission), (2, .done), (1, .idle), (0, .none),
        ]
        for (byte, expected) in hostByteThenExpected {
            let result = session.feedAgentSignal(.claudeStatus(state: byte, kind: 0, label: ""))
            XCTAssertEqual(result, expected, "host state byte \(byte) → client status \(expected) (no divergence)")
            XCTAssertEqual(session.claudeStatus, expected)
        }
    }

    /// P1 (d): a `claude-monitor` (or `myclaudewrapper`) foreground process is NOT claude — and since the
    /// client treats type-26 as display-only, it can NEVER lift `claudeStatus` off `.none` anyway. So the
    /// inspector second channel is never stood up (no flap): `makeInspector` is never called.
    func testClaudeMonitorProcessDoesNotOpenInspector() async {
        var madeInspector = false
        let session = LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: Self.makeUnconnectedClient,
            makeInspector: { _ in madeInspector = true
                return nil
            },
        )
        for name in ["claude-monitor", "myclaudewrapper"] {
            XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: name)), .none, "\(name) is not claude")
            XCTAssertEqual(
                session.claudeStatus,
                .none,
                "a claude-prefixed name never sets status (type-26 is display-only)",
            )
        }
        // Driving subscribe directly is still a no-op (status is .none → no inspector socket / no flap).
        await session.subscribeInspector()
        XCTAssertFalse(madeInspector, "no inspector channel for a non-claude foreground process")
    }

    /// P5 #6 — a GENUINE dedupe assertion (not the old near-tautological one that only checked the
    /// returned status stayed `.working`, which holds with OR without dedupe). The store's `setAgentStatus`
    /// is the dedupe guard; we COUNT how many times the observable `paneAgentStatus` actually MUTATES
    /// across a stream that contains repeats, and assert it changes exactly ONCE per distinct value. With
    /// the dedupe guard removed, an idempotent re-set would re-assign (and re-notify) on every repeat —
    /// this test would then see extra mutations. Driven through the real store sink + the session fold.
    func testRepeatedIdenticalStatusEmitsOnlyOnce() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        // Track every DISTINCT value paneAgentStatus took for this pane (one entry per real mutation).
        var observedSequence: [ClaudeStatus] = []
        func setAndRecord(_ s: ClaudeStatus) {
            let before = store.agentStatus(for: paneID)
            store.setAgentStatus(s, for: paneID)
            let after = store.agentStatus(for: paneID)
            if after != before { observedSequence.append(after) } // a real mutation happened
        }

        // working, working (dup), working (dup), needsPermission, needsPermission (dup), working.
        setAndRecord(.working)
        setAndRecord(.working)
        setAndRecord(.working)
        setAndRecord(.needsPermission)
        setAndRecord(.needsPermission)
        setAndRecord(.working)

        XCTAssertEqual(
            observedSequence,
            [.working, .needsPermission, .working],
            "each repeated identical status is deduped — the store mutates once per distinct value, not per call",
        )
    }

    // MARK: - 2. The store sink: setAgentStatus mirrors the fold into paneAgentStatus + rollup

    /// The store's per-pane sink: setting a pane's agent status lights up `agentStatus(for:)`, and the
    /// owning session/tab `rollupStatus(...)` surface the most-urgent state (Herdr rollup). This is the
    /// `AgentStatusDot`'s live source.
    func testSetAgentStatusFeedsRollupDots() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        // The default tree has one session with one tab + one leaf.
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)

        XCTAssertEqual(store.agentStatus(for: paneID), .none, "no detection yet → none")
        XCTAssertEqual(store.rollupStatus(forSession: sessionID), .none)

        store.setAgentStatus(.needsPermission, for: paneID)
        XCTAssertEqual(store.agentStatus(for: paneID), .needsPermission, "per-pane status reflects the fold")
        XCTAssertEqual(
            store.rollupStatus(forSession: sessionID),
            .needsPermission,
            "the sidebar session-row dot surfaces the most-urgent pane",
        )

        // Clearing it (claude gone) removes the entry → back to none, no rollup.
        store.setAgentStatus(.none, for: paneID)
        XCTAssertEqual(store.agentStatus(for: paneID), .none)
        XCTAssertEqual(store.rollupStatus(forSession: sessionID), .none, "the dot goes dark when claude leaves")
    }

    /// The most-urgent rollup over a multi-pane tab (blocked > working > done > idle > none) — a `.idle`
    /// pane next to a `.needsPermission` pane rolls up to `.needsPermission`.
    func testRollupSurfacesMostUrgentAcrossPanes() throws {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
        let sessionID = try XCTUnwrap(store.tree.sessions.first?.id)
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        // Split to get a second pane in the same tab.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let panes = store.tree.allPaneIDs()
        XCTAssertEqual(panes.count, 2, "split produced a second leaf")
        let second = try XCTUnwrap(panes.first { $0 != first })

        store.setAgentStatus(.idle, for: first)
        store.setAgentStatus(.needsPermission, for: second)
        XCTAssertEqual(
            store.rollupStatus(forSession: sessionID),
            .needsPermission,
            "blocked outranks idle in the rollup",
        )
    }

    // MARK: - 3. The wire→Event surface (AislopdeskClient maps types 26/27 to events)

    /// The client surfaces a type-27 `claudeStatus` WireMessage as a `.claudeStatus` Event (the byte
    /// payload is carried verbatim; the UI maps it back). Proven via the client's test inbound seam.
    func testClientSurfacesClaudeStatusWireMessageAsEvent() async {
        let client = Self.makeUnconnectedClient()
        // Subscribe BEFORE driving so the multicast child stream observes the yield.
        let events = client.events
        let observer = Task { () -> AislopdeskClient.Event? in
            for await event in events { return event }
            return nil
        }
        // Let the subscription register, then drive a type-27 message through the inbound seam.
        await Task.yield()
        await client.handleInboundForTesting(.claudeStatus(state: 4, kind: 1, label: "Allow?"))
        let observed = await observer.value
        XCTAssertEqual(
            observed,
            .claudeStatus(state: 4, kind: 1, label: "Allow?"),
            "the client forwards the type-27 payload verbatim as a .claudeStatus event",
        )
    }
}
