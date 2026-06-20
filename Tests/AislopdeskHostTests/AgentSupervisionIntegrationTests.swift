import AislopdeskAgentDetect
import Foundation
import XCTest
@testable import AislopdeskHost

/// PIECE 2 + 1 + 5 integration — drives a REAL standalone PTY pane through `HostServer`
/// (PTYs are allowed in tests; only SCStream/VT/Metal/Ghostty/NSWindow are forbidden) to prove
/// the NEW cross-pane plumbing end-to-end without a socket:
///   - a `report` transition fans the server-level `agent_status_changed` observer,
///   - `listPanesForControl()` surfaces the reported per-pane state,
///   - `spawnStandalonePane` injects the P1 self-orientation env sentinel.
///
/// These FAIL on the un-fixed code: before P1 there was no `onAgentStatusChanged` hook, no
/// server-level observer registry, no `state` on `PaneInfo`, and no `AISLOPDESK_CTL` sentinel.
final class AgentSupervisionIntegrationTests: XCTestCase {
    /// A report transition on a live pane invokes a registered cross-pane observer with the pane's
    /// id and the mapped supervision state.
    func testReportFansCrossPaneObserver() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }

        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )

        // Register a cross-pane observer and capture the first transition for THIS pane.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _hit: (paneId: String, state: String)?
            func set(_ pid: String, _ state: String) {
                lock.lock()
                defer { lock.unlock() }
                if _hit == nil { _hit = (pid, state) }
            }

            var hit: (paneId: String, state: String)? {
                lock.lock()
                defer { lock.unlock() }
                return _hit
            }
        }
        let box = Box()
        let obsID = UUID()
        server.registerAgentStatusObserver(id: obsID) { pid, state, _, _ in box.set(pid, state) }
        defer { server.removeAgentStatusObserver(id: obsID) }

        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("spawned pane not found")
            return
        }
        // Self-report "working" → an authoritative transition (none → working) must fan out.
        session.reportAgentStatusForControl(state: "working", message: nil)

        // The fan-out runs synchronously on the report call's thread, but allow a brief poll for
        // robustness against any scheduling.
        for _ in 0..<40 where box.hit == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let hit = box.hit
        XCTAssertEqual(hit?.paneId, paneId, "the fan-out carries the reporting pane's id")
        XCTAssertEqual(hit?.state, "working", "none → working transition fanned as 'working'")
    }

    /// `listPanesForControl()` reflects a reported state on the matching pane.
    func testListPanesReflectsReportedState() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }

        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("pane not found")
            return
        }
        session.reportAgentStatusForControl(state: "blocked", message: "approve?")

        let panes = server.listPanesForControl()
        let mine = panes.first { $0.paneId == paneId }
        XCTAssertEqual(mine?.state, "blocked", "list-panes surfaces the reported supervision state")
    }

    /// PIECE 5 — `spawnStandalonePane` injects the FULL self-orientation env sentinel
    /// (`AISLOPDESK_CTL=1`, `AISLOPDESK_CTL_BIN`, `AISLOPDESK_CONTROL_SOCKET`, `AISLOPDESK_PANE_ID`)
    /// into the spawned child's environment. Proven by running a child that echoes those vars and
    /// reading the result back through the same scrollback path the `read` verb uses. This FAILS if
    /// the injection lines at `HostServer.spawnStandalonePane` are removed (the echoed line would be
    /// empty / missing the keys), unlike the constant-equality unit checks which never touch the wiring.
    func testSpawnInjectsSelfOrientationEnv() async throws {
        let socketPath = "/tmp/aislopdesk-test-ctl-\(UUID().uuidString).sock"
        let ctlBin = "/tmp/aislopdesk-test-ctl-bin-\(UUID().uuidString)"
        let server = HostServer(
            port: 0,
            agentControlSocketPath: socketPath,
            ctlBinaryPath: ctlBin,
        )
        defer { Task { await server.stop() } }

        // A child that prints each sentinel on its own clearly-delimited line, then exits.
        let script = """
        echo "CTL=$AISLOPDESK_CTL"
        echo "BIN=$AISLOPDESK_CTL_BIN"
        echo "SOCK=$AISLOPDESK_CONTROL_SOCKET"
        echo "PANE=$AISLOPDESK_PANE_ID"
        """
        let paneId = try await server.spawnStandalonePane(
            cmd: ["/bin/sh", "-c", script], cwd: nil, env: nil, rows: 24, cols: 80,
        )
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            XCTFail("spawned pane not found")
            return
        }

        // Poll the scrollback (the child's stdout flows into the ReplayBuffer) until all four
        // sentinels have landed or a generous deadline elapses.
        var text = ""
        for _ in 0..<100 {
            text = session.scrollbackTextForControl(ansiStrip: true)
            if text.contains("CTL=1"), text.contains("PANE=\(paneId)") { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(text.contains("CTL=1"), "AISLOPDESK_CTL=1 injected; got:\n\(text)")
        XCTAssertTrue(text.contains("BIN=\(ctlBin)"), "AISLOPDESK_CTL_BIN injected; got:\n\(text)")
        XCTAssertTrue(text.contains("SOCK=\(socketPath)"), "AISLOPDESK_CONTROL_SOCKET injected; got:\n\(text)")
        XCTAssertTrue(text.contains("PANE=\(paneId)"), "AISLOPDESK_PANE_ID == the returned paneId; got:\n\(text)")
    }

    /// A freshly-spawned pane reports a state in the closed supervision set (a live pane with no
    /// claude → "idle"), never an enum case name or empty string.
    func testFreshPaneStateIsInClosedSet() async throws {
        let server = HostServer(port: 0)
        defer { Task { await server.stop() } }
        let paneId = try await server.spawnStandalonePane(
            cmd: nil, cwd: nil, env: nil, rows: 24, cols: 80,
        )
        let panes = server.listPanesForControl()
        let mine = panes.first { $0.paneId == paneId }
        XCTAssertNotNil(mine)
        XCTAssertTrue(
            AgentControlState.isValid(mine?.state ?? ""),
            "fresh pane state must be a valid supervision state",
        )
    }
}
