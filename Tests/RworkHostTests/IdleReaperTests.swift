#if canImport(Darwin)
import Darwin
#endif
import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// Item (3): the `idleTTL` session reaper.
///
/// A session whose client has been offline longer than `idleTTL` must be fully torn
/// down (forwarders stopped, child terminated, master fd closed) instead of leaking its
/// shell forever. These tests drive ``HostServer/reapIdleSessions(now:)`` with a
/// synthesized `now` so the TTL elapses deterministically — no wall-clock sleeps.
final class IdleReaperTests: XCTestCase {

    /// Spawns a real, long-lived PTY-backed ``HostSession`` (so the reaper has actual
    /// resources to release) and inserts it into `server` via the test seam. The child is
    /// `cat` with no input → it blocks forever until terminated.
    private func makeLiveSession(in server: HostServer) throws -> (HostSession, HostSessionTransport, PTYProcess) {
        let id = UUID()
        let transport = HostSessionTransport(sessionID: id)
        let pty = PTYProcess()
        // `cat` with no args reads stdin forever — a deterministic long-lived child.
        try pty.spawn("/bin/cat", environment: HostEnvironment.curated())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0, "spawned PTY must have a valid master fd")
        XCTAssertGreaterThan(pty.pid, 0)
        let session = HostSession(sessionID: id, pty: pty, transport: transport)
        server._insertSessionForTest(session)
        return (session, transport, pty)
    }

    func testOfflineSessionIsReapedAfterTTLElapses() async throws {
        let ttl: TimeInterval = 0.5
        // reapInterval set high so the background timer never races our manual reaps.
        let server = HostServer(port: 0, idleTTL: ttl, reapInterval: 3600)
        let (_, transport, pty) = try makeLiveSession(in: server)

        // The client is offline (no data channel bound). Drive the offline gate.
        await transport.setClientOnline(false)
        let online = await transport.clientOnline
        XCTAssertFalse(online)

        XCTAssertEqual(server.liveSessionIDs().count, 1)

        // 1. First reap at t0: records the offline-since mark; age is 0 < TTL → NOT reaped.
        let t0 = ContinuousClock.now
        let reaped0 = await server.reapIdleSessions(now: t0)
        XCTAssertTrue(reaped0.isEmpty, "a freshly-offline session must not be reaped before the TTL")
        XCTAssertEqual(server.liveSessionIDs().count, 1)
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0, "still-live session keeps its master fd")

        // 2. Reap at t0 + TTL + ε: the offline age now exceeds the TTL → reaped.
        let future = t0.advanced(by: .seconds(ttl) + .milliseconds(50))
        let reaped1 = await server.reapIdleSessions(now: future)
        XCTAssertEqual(reaped1.count, 1, "the session offline > TTL must be reaped")
        XCTAssertTrue(server.liveSessionIDs().isEmpty, "reaped session must be removed from the live map")

        // 3. Resources released: the master fd is closed (shutdown → closeMaster sets -1)
        //    and the child terminates (waitForExit returns).
        XCTAssertEqual(pty.masterFD, -1, "reaper must close the session's master fd")
        let exitCode = await withTimeout(seconds: 5) { await pty.waitForExit() }
        XCTAssertNotNil(exitCode, "the reaped session's child must terminate")
    }

    func testOnlineSessionIsNeverReaped() async throws {
        let server = HostServer(port: 0, idleTTL: 0.1, reapInterval: 3600)
        let (_, transport, pty) = try makeLiveSession(in: server)
        defer { server._reapAllForTestCleanup(pty: pty) }

        // Client is ONLINE (default for a fresh transport / or after bind).
        await transport.setClientOnline(true)
        let online = await transport.clientOnline
        XCTAssertTrue(online)

        // Even far past any TTL, an online session is never reaped.
        let future = ContinuousClock.now.advanced(by: .seconds(3600))
        let reaped = await server.reapIdleSessions(now: future)
        XCTAssertTrue(reaped.isEmpty, "an online session must never be reaped")
        XCTAssertEqual(server.liveSessionIDs().count, 1)
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
    }

    func testReconnectClearsOfflineMarkSoTTLRestarts() async throws {
        let ttl: TimeInterval = 0.5
        let server = HostServer(port: 0, idleTTL: ttl, reapInterval: 3600)
        let (_, transport, pty) = try makeLiveSession(in: server)
        defer { server._reapAllForTestCleanup(pty: pty) }

        // Offline at t0 → marks offline-since.
        await transport.setClientOnline(false)
        let t0 = ContinuousClock.now
        _ = await server.reapIdleSessions(now: t0)

        // Client reconnects (online) → a reap clears the offline mark.
        await transport.setClientOnline(true)
        let tReconnect = t0.advanced(by: .milliseconds(100))
        let reapedDuringOnline = await server.reapIdleSessions(now: tReconnect)
        XCTAssertTrue(reapedDuringOnline.isEmpty)

        // Goes offline AGAIN: the TTL clock restarts from the new offline mark, so a reap
        // at the ORIGINAL t0+TTL must NOT yet fire (the mark is now ~tReconnect, fresh).
        await transport.setClientOnline(false)
        let tOffline2 = t0.advanced(by: .seconds(ttl) + .milliseconds(10))
        // First reap after going offline again just RE-STAMPS offline-since at tOffline2.
        let reapedRestamp = await server.reapIdleSessions(now: tOffline2)
        XCTAssertTrue(reapedRestamp.isEmpty, "offline mark must restart after a reconnect, not carry the old age")
        XCTAssertEqual(server.liveSessionIDs().count, 1)
    }

    // MARK: helpers

    private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private extension HostServer {
    /// Best-effort cleanup for tests that leave a live session behind: terminate the
    /// child so `cat` does not linger past the test.
    func _reapAllForTestCleanup(pty: PTYProcess) {
        pty.terminate()
        pty.closeMaster()
    }
}
