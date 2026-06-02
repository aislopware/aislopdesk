import XCTest
import Foundation
@testable import RworkClient
import RworkHost
import RworkProtocol
@testable import RworkClientUI

/// Drives the `@MainActor @Observable` ``ConnectionViewModel`` against a REAL in-process
/// PATH 1 stack — a ``HostServer`` (RworkHost, `/bin/sh` in a PTY) + a ``RworkClient`` over a
/// 127.0.0.1 ephemeral port — so the connect → connected → live-output → disconnect state
/// transitions are exercised end-to-end (not against a mock). The same pattern as
/// `RworkClientTests`.
@MainActor
final class ConnectionViewModelTests: XCTestCase {

    private func startHost(shell: String = "/bin/sh") async throws -> (server: HostServer, port: UInt16) {
        let server = HostServer(port: 0, shellPath: shell)
        try await server.start()
        guard let port = await server.boundPort() else {
            await server.stop()
            throw XCTSkip("host did not bind a port")
        }
        return (server, port)
    }

    /// Polls a `@MainActor` predicate until true or the deadline passes (avoids fixed sleeps).
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    func testConnectReachesConnectedAndReceivesOutput() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: port)
        XCTAssertEqual(vm.status, .disconnected)
        XCTAssertTrue(vm.canConnect)

        await vm.connect()
        XCTAssertEqual(vm.status, .connected, "connect() resolves to connected on a successful handshake")
        XCTAssertNotNil(vm.sessionID)
        XCTAssertNotNil(vm.activeClient)

        // OUT-path wiring: connect() must arm the renderer→host sinks on the terminal model
        // (the SAME funnel GhosttyTerminalView's onWrite/onResize bridge uses).
        XCTAssertNotNil(terminal.inputSink, "connect() wires the OUT-path input sink")
        XCTAssertNotNil(terminal.resizeSink, "connect() wires the OUT-path resize sink")

        // Drive a shell echo THROUGH the model funnel (terminal.sendInput → inputSink →
        // client.sendInput → host PTY), not the client directly — this exercises the renderer
        // OUT seam end-to-end. The host echoes it back as output.
        terminal.sendInput(Data("echo RWORK_UI_OK\n".utf8))
        let sawOutput = await waitUntil { terminal.bytesReceived > 0 && terminal.connectionStatus == .connected }
        XCTAssertTrue(sawOutput, "terminal model received output and is connected; bytes=\(terminal.bytesReceived)")

        // Drive a grid resize through the model funnel; the session must stay healthy
        // (host maps it to TIOCSWINSZ on the control channel).
        terminal.sendResize(cols: 132, rows: 43)
        let stillConnected = await waitUntil { vm.status == .connected }
        XCTAssertTrue(stillConnected, "session healthy after a model-funnelled resize")

        await vm.disconnect()
        XCTAssertEqual(vm.status, .disconnected, "deliberate disconnect → disconnected (no reconnect)")
        XCTAssertNil(terminal.inputSink, "disconnect() clears the OUT-path input sink")
        XCTAssertNil(terminal.resizeSink, "disconnect() clears the OUT-path resize sink")
    }

    /// END-TO-END consistency across a real `.disconnected` → `.reconnected` cycle delivered
    /// through `client.events` while BOTH the chrome events loop and the terminal output pump
    /// are live. Before the multicast/single-consumer fix the two view-models raced for each
    /// event (a `.disconnected`/`.reconnected` reached only one), so the chrome and terminal
    /// statuses could diverge. Here we force a hard transport drop (no `bye`, like an iOS TCP
    /// teardown), let the `ReconnectManager` resume the SAME host session, and assert BOTH the
    /// chrome `status` and the terminal `connectionStatus` end consistently `.connected`.
    func testReconnectCycleKeepsChromeAndTerminalConsistent() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            host: "127.0.0.1",
            port: port,
            backoff: .init(initial: .milliseconds(20), maximum: .milliseconds(60), multiplier: 2)
        )
        await vm.connect()
        XCTAssertEqual(vm.status, .connected)
        guard let client = vm.activeClient else { return XCTFail("no active client") }

        // Drive some output so the terminal model is firmly .connected before the drop.
        try await client.sendInput(Data("echo PRE_DROP\n".utf8))
        let pre = await waitUntil { terminal.connectionStatus == .connected && terminal.bytesReceived > 0 }
        XCTAssertTrue(pre, "terminal reached .connected before the drop")

        // Hard drop (no bye): the inbound stream ends → `.disconnected` → ReconnectManager resumes.
        await client._forceDropForTesting()

        // The reconnect campaign should restore BOTH statuses to .connected. (We don't assert
        // the transient .reconnecting — the resume can be fast; we assert the consistent end.)
        let converged = await waitUntil(timeout: .seconds(10)) {
            vm.status == .connected && terminal.connectionStatus == .connected
        }
        XCTAssertTrue(
            converged,
            "chrome + terminal both .connected after resume; chrome=\(vm.status) terminal=\(terminal.connectionStatus)"
        )
        // And they must AGREE (the divergence the race produced): never one .reconnecting while
        // the other is .connected at the converged point.
        XCTAssertEqual(vm.status, .connected)
        XCTAssertEqual(terminal.connectionStatus, .connected)

        await vm.disconnect()
    }

    /// A `.title` event delivered through the live `client.events` stream must reach the
    /// TERMINAL model (which renders it) even though the chrome events loop is the sole
    /// consumer — i.e. the chrome forwards every event onward. Before the fix, `observeEvents`
    /// could swallow the `.title` (it ignored it) so the terminal never saw it.
    func testTitleReachesTerminalWhileChromeLoopIsLive() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: port)
        await vm.connect()
        XCTAssertEqual(vm.status, .connected)
        guard let client = vm.activeClient else { return XCTFail("no active client") }

        // Inject a `.title` through the SAME path the live inbound pump uses, so it is yielded
        // onto the events broadcast both the chrome loop (forwarder) and nothing else observe.
        await client._handleInboundForTesting(.title("~/proj — rwork"))

        let sawTitle = await waitUntil { terminal.title == "~/proj — rwork" }
        XCTAssertTrue(sawTitle, "terminal model received the title via the chrome forward; got \(String(describing: terminal.title))")

        await vm.disconnect()
    }

    func testInvalidPortFails() async {
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: 7420)
        vm.port = "not-a-port"
        XCTAssertFalse(vm.canConnect)
        await vm.connect()
        if case .failed = vm.status {} else {
            XCTFail("expected .failed for an unparseable port, got \(vm.status)")
        }
    }

    func testConnectToDeadPortFails() async {
        let terminal = TerminalViewModel()
        // Port 1 on loopback: nothing listening → handshake times out / refuses.
        let vm = ConnectionViewModel(
            terminal: terminal,
            host: "127.0.0.1",
            port: 1,
            backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20), multiplier: 2)
        )
        // Shorten the wait: connect() awaits the first handshake which will fail.
        await vm.connect()
        if case .failed = vm.status {} else {
            XCTFail("expected .failed connecting to a dead port, got \(vm.status)")
        }
    }

    func testDeliberateDisconnectDoesNotReconnect() async throws {
        let (server, port) = try await startHost()
        defer { Task { await server.stop() } }

        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(terminal: terminal, host: "127.0.0.1", port: port)
        await vm.connect()
        XCTAssertEqual(vm.status, .connected)

        await vm.disconnect()
        XCTAssertEqual(vm.status, .disconnected)
        XCTAssertNil(vm.activeClient, "client is torn down on deliberate disconnect")

        // Give any (incorrect) reconnect a window to fire; status must stay disconnected.
        let stayedDisconnected = await waitUntil(timeout: .milliseconds(300)) {
            vm.status != .disconnected
        }
        XCTAssertFalse(stayedDisconnected, "no reconnect after a deliberate disconnect")
    }
}
