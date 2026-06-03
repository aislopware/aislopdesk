import XCTest
import Foundation
import RworkProtocol
import RworkTransport
import RworkHost
@testable import RworkClient

/// Regression test for self-inflicted `.disconnected` suppression during intentional
/// transport teardown.
///
/// `connect()` (the reconnect entry) tears the OLD transport down before opening the new
/// one. Closing the old transport finishes the old inbound stream, which lands the old
/// inbound pump in `handleStreamEnded(error: nil)`. Without the `tearingDown` guard that
/// self-inflicted end surfaces ANOTHER `.disconnected`, which the ``ReconnectManager``
/// supervising loop treats as a fresh drop and answers with a SECOND, redundant reconnect
/// campaign. (`EventBroadcaster` buffers unbounded, so the spurious event is never dropped
/// — it really would queue a redundant campaign.)
///
/// This test drives the real supervising loop over loopback TCP, forces exactly ONE drop,
/// and asserts EXACTLY ONE reconnect campaign runs — i.e. no spurious extra `.disconnected`
/// reached the consumer and no redundant second campaign was queued.
///
/// Reparented onto ``HostServerE2ECase`` (ITEM #10): bring-up + the awaited
/// `server.stop()` / `client.close()` teardown live in the base class, and the per-test
/// ceiling sits above this suite's 15s inner waits so a hung supervisor FAILS instead of
/// wedging the shared test process.
final class RworkReconnectSuppressionTests: HostServerE2ECase {

    /// Inner waits cap at 15s plus a 500ms spurious-campaign window; 60s clears that with
    /// margin yet still kills a genuinely hung supervising loop.
    override var perTestTimeAllowance: TimeInterval { 60 }

    func testSingleDropRunsExactlyOneReconnectCampaign() async throws {
        let (_, port) = try await startHost()
        let client = try await connectedClient(toPort: port, ackInterval: .milliseconds(20))

        // Count reconnect campaigns started by the supervising loop. `start()` logs
        // "reconnect: transport dropped" exactly once at the head of each campaign, so the
        // count of that line == number of campaigns the loop launched.
        let log = CampaignLog()
        let reconnect = ReconnectManager(client: client, onLog: { line in log.record(line) })
        let supervisor = reconnect.start(host: "127.0.0.1", port: port)
        defer { supervisor.cancel() }

        // Drain output so the surfaced stream stays alive (the drop replaces only the
        // transport, not the surfaced streams).
        let drain = Task { for await _ in client.output {} }
        defer { drain.cancel() }

        // Emit a little output then ack it, so the reconnect is a real RETURNING_CLIENT
        // resume (preserved sessionID + seq), exercising the teardown-in-connect path.
        try await client.sendInput(Data("echo hello\n".utf8))
        try await waitUntil(timeout: .seconds(10)) { await client.highestContiguousSeq > 0 }
        await client.flushAck()

        // FORCE exactly one drop (no clean bye — simulate network loss). This yields one
        // `.disconnected`; the supervising loop must answer with exactly one campaign whose
        // own connect()-teardown must NOT surface a second `.disconnected`.
        await client._forceDropForTesting()

        // Wait for the single campaign to resume the session (sessionID stays set; the loop
        // logged the drop and reconnected).
        try await waitUntil(timeout: .seconds(15)) { log.dropCount() >= 1 }
        try await waitUntil(timeout: .seconds(15)) { log.resumedCount() >= 1 }

        // Give any spurious second campaign a generous window to (incorrectly) appear.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(log.dropCount(), 1,
                       "exactly one drop should be observed by the supervisor — a self-inflicted " +
                       "`.disconnected` from connect()'s teardown would push this to 2. Saw: \(log.lines())")
        XCTAssertEqual(log.resumedCount(), 1,
                       "exactly one reconnect campaign should have resumed. Saw: \(log.lines())")

        await client.close()
    }

    /// Directly exercises the guard's actual code path: a `connect()` that tears down a
    /// **still-live** transport (the reconnect-entry path) must NOT surface a spurious
    /// `.disconnected` from the old inbound pump's self-inflicted stream-end.
    ///
    /// This is the non-vacuous companion to ``testSingleDropRunsExactlyOneReconnectCampaign``:
    /// that test drives the drop via `_forceDropForTesting()`, which nils `transport` +
    /// `inboundTask` BEFORE the supervisor's `connect()` runs — so by the time `connect()`
    /// calls `teardownTransport()` there is nothing left to drain and the guarded path is
    /// never hit (the test passes with or without the guard). Here we instead replace a LIVE
    /// transport, so the old pump genuinely unwinds into `handleStreamEnded(nil)` while
    /// `tearingDown == true` — the exact condition `RworkClient.swift:280` suppresses.
    ///
    /// We subscribe to `events` BEFORE the second connect (the broadcaster is live + buffers
    /// per child, so no `.disconnected` can be missed) and assert ZERO disconnects from the
    /// live-transport replacement. Removing the `!tearingDown` clause makes this fail with
    /// exactly one spurious `.disconnected`.
    func testLiveTransportReplacementSurfacesNoDisconnect() async throws {
        let (_, port) = try await startHost()
        let client = try await connectedClient(toPort: port, ackInterval: .milliseconds(20))

        // Keep the surfaced output stream drained so the session stays live.
        let drain = Task { for await _ in client.output {} }
        defer { drain.cancel() }

        // Subscribe BEFORE the live replacement so every `.disconnected` is captured.
        let disconnects = DisconnectCounter()
        let watcher = Task {
            for await event in client.events {
                if case .disconnected = event { disconnects.bump() }
            }
        }
        defer { watcher.cancel() }

        // Establish a real resume baseline so the second connect is a RETURNING_CLIENT
        // resume over a genuinely live transport (the production reconnect-entry path).
        try await client.sendInput(Data("echo hi\n".utf8))
        try await waitUntil(timeout: .seconds(10)) { await client.highestContiguousSeq > 0 }
        await client.flushAck()

        // Replace the LIVE transport directly. `connect()` sets `tearingDown` around the
        // teardown; the old inbound pump unwinds into `handleStreamEnded(nil)` under the
        // guard. A correct guard suppresses that self-inflicted end → zero `.disconnected`.
        try await client.connect(host: "127.0.0.1", port: port)

        // Give any spurious self-inflicted `.disconnected` a generous window to surface.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(disconnects.count(), 0,
                       "tearing down a LIVE transport inside connect() must not surface a " +
                       "self-inflicted `.disconnected`; the `!tearingDown` guard suppresses it. " +
                       "Saw \(disconnects.count()).")

        await client.close()
    }

    // MARK: - Helpers

    /// Thread-safe `.disconnected` event counter.
    private final class DisconnectCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Thread-safe collector of `onLog` lines from the supervising loop.
    private final class CampaignLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ line: String) { lock.lock(); entries.append(line); lock.unlock() }

        func lines() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }

        /// Number of campaign starts (one "transport dropped" line per campaign).
        func dropCount() -> Int {
            lines().filter { $0.contains("transport dropped") }.count
        }

        /// Number of campaigns that successfully resumed.
        func resumedCount() -> Int {
            lines().filter { $0.contains("resumed after") }.count
        }
    }

    private func waitUntil(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        if await !condition() { throw SuppressionTestError.timedOut }
    }

    private enum SuppressionTestError: Error { case timedOut }
}
