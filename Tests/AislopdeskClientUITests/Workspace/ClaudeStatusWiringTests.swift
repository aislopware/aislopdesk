import AislopdeskAgentDetect
import AislopdeskTransport
import XCTest
@testable import AislopdeskClient
@testable import AislopdeskClientUI

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

    /// A type-26 `foregroundProcess("claude")` lifts the presence FLOOR to `.idle`; a non-claude name
    /// (or empty) clears it back to `.none` (the coarse presence signal).
    func testForegroundProcessPresenceFloorAndClear() {
        let session = makeTerminalSession()
        XCTAssertEqual(
            session.feedAgentSignal(.foregroundProcess(name: "claude")),
            .idle,
            "claude present → idle floor",
        )
        XCTAssertEqual(session.claudeStatus, .idle)
        XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: "vim")), .none, "non-claude clears presence")
        XCTAssertEqual(session.claudeStatus, .none)
    }

    /// An unknown / future urgency byte degrades to `.none` (forward-tolerant validate-then-repair) —
    /// a hostile or newer datagram must never trap the client.
    func testUnknownStateByteDegradesToNone() {
        let session = makeTerminalSession()
        // First detect a claude so we are NOT already at .none.
        XCTAssertEqual(session.feedAgentSignal(.foregroundProcess(name: "claude")), .idle)
        // A future state byte (99) maps to .none via ClaudeStatus(urgency:) — the host says "gone".
        let result = session.feedAgentSignal(.claudeStatus(state: 99, kind: 0, label: ""))
        XCTAssertEqual(result, .none, "an unknown urgency byte degrades to .none (never traps)")
    }

    /// `feedAgentSignal` dedupes: feeding the SAME status twice does not churn (idempotent) — the
    /// store's `setAgentStatus` is also a no-op on equal updates.
    func testFeedAgentSignalIsIdempotentOnEqualUpdates() {
        let session = makeTerminalSession()
        _ = session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "x"))
        XCTAssertEqual(session.claudeStatus, .working)
        // Same urgency again → still working, no change.
        let again = session.feedAgentSignal(.claudeStatus(state: 3, kind: 0, label: "x"))
        XCTAssertEqual(again, .working, "a duplicate status update is a no-op")
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
