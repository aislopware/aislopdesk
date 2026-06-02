import XCTest
import Network
import RworkProtocol
@testable import RworkTransport

/// Item (2): host-side half-open handshake reaper.
///
/// A client can complete the CONTROL handshake (preamble + `hello` → `helloAck`) and
/// then never open the DATA connection — the iOS-background / NetBird-flap case. Without
/// a reaper the `pending[id]` entry and its control `NWMessageChannel` (+ NWConnection)
/// leak forever. These tests open ONLY the control channel, drive a deterministic reap
/// (no wall-clock sleep), and assert the pending map empties and the control channel is
/// closed (the client observes FIN on its control connection).
final class HostHalfOpenReaperTests: XCTestCase {

    /// Starts a host with an injected (small) `pendingDataTimeout`. The reap itself is
    /// driven deterministically via `reapExpiredPending(now:)`, so the timeout value only
    /// needs to be finite — we use a small one to also keep the background timer cheap.
    private func startHost(pendingDataTimeout: Duration = .milliseconds(200)) async throws
        -> (host: HostTransport, port: UInt16)
    {
        let host = HostTransport(handshakeTimeout: .seconds(10), pendingDataTimeout: pendingDataTimeout)
        try await host.start(port: 0)
        let bound = await host.boundPort
        let port = try XCTUnwrap(bound)
        XCTAssertNotEqual(port, 0)
        return (host, port)
    }

    /// Opens ONLY a CONTROL connection, sends the control preamble + `hello`, and reads
    /// the `helloAck`. Returns the control channel and the authoritative session id. The
    /// DATA connection is deliberately never opened.
    private func openControlOnly(
        port: UInt16,
        resume: UUID = WireMessage.newSessionID,
        lastReceivedSeq: Int64 = 0
    ) async throws -> (control: NWMessageChannel, sessionID: UUID) {
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: TransportParameters.makeTCP()
        )
        try await conn.startAndWaitReady(on: DispatchQueue(label: "rwork.test.ctrl"))
        try await conn.sendRaw(ChannelAssociation.controlPreamble())

        let control = NWMessageChannel(connection: conn, channel: .control)
        await control.start()
        try await control.send(.hello(
            protocolVersion: Rwork.protocolVersion,
            sessionID: resume,
            lastReceivedSeq: lastReceivedSeq
        ))

        // Read exactly the helloAck.
        var ack: WireMessage?
        for try await message in control.inbound {
            ack = message
            break
        }
        guard case let .helloAck(authoritativeID, _, _)? = ack else {
            throw RworkTransportError.handshakeFailed("expected helloAck, got \(String(describing: ack))")
        }
        return (control, authoritativeID)
    }

    // MARK: The headline test

    func testHalfOpenControlIsReapedAndPendingEmptied() async throws {
        let (host, port) = try await startHost()
        defer { Task { await host.stop() } }

        // 1. Complete the CONTROL handshake; never open DATA.
        let (control, sessionID) = try await openControlOnly(port: port)

        // 2. The host now holds exactly one pending (half-open) handshake for this id.
        try await waitUntil(timeout: .seconds(5)) { await host.isPending(sessionID) }
        let pendingBefore = await host.pendingCount()
        XCTAssertEqual(pendingBefore, 1, "the half-open control handshake must be pending")

        // 3. Drive the reaper deterministically with an instant past every deadline —
        //    NO wall-clock sleep. This is exactly what the background timer would do.
        let future = await host.instantPastAllPendingDeadlines()
        await host.reapExpiredPending(now: future)

        // 4. Pending must be empty: the leaked entry is gone.
        let pendingAfter = await host.pendingCount()
        XCTAssertEqual(pendingAfter, 0, "the reaper must remove the half-open pending entry")
        let stillPending = await host.isPending(sessionID)
        XCTAssertFalse(stillPending)

        // 5. The control channel must be closed host-side: the client observes FIN, so
        //    its control inbound stream finishes (no more messages, no error).
        try await assertInboundFinishes(control, timeout: .seconds(5))
    }

    /// A reap BEFORE the deadline must NOT touch a still-young pending entry.
    func testReapBeforeDeadlineKeepsPending() async throws {
        let (host, port) = try await startHost(pendingDataTimeout: .seconds(30))
        defer { Task { await host.stop() } }

        let (_, sessionID) = try await openControlOnly(port: port)
        try await waitUntil(timeout: .seconds(5)) { await host.isPending(sessionID) }

        // Reap "now" (the entry was just created with a 30s timeout): nothing expires.
        let now = await host.instantNowForTest()
        await host.reapExpiredPending(now: now)

        let stillPending = await host.isPending(sessionID)
        XCTAssertTrue(stillPending, "an entry younger than the timeout must survive a reap")
        let count = await host.pendingCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: Helpers

    /// Asserts the channel's inbound stream finishes (FIN / close) within `timeout`,
    /// i.e. the host closed its end. A finish (no element) is success; a thrown error is
    /// also acceptable evidence the connection was torn down.
    private func assertInboundFinishes(_ channel: NWMessageChannel, timeout: Duration) async throws {
        let finished: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await _ in channel.inbound { /* drain any stray frame */ }
                    return true // clean finish (FIN)
                } catch {
                    return true // errored finish (also "closed")
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        XCTAssertTrue(finished, "control channel must close (inbound stream must finish) after the reap")
    }

    /// Polls `condition` until true or `timeout`.
    private func waitUntil(timeout: Duration, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        if await condition() { return }
        throw RworkTransportError.timedOut("waitUntil condition")
    }
}
