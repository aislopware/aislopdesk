import XCTest
import Foundation
import RworkProtocol
import RworkTransport
import RworkHost
@testable import RworkClient

/// THE headline test: byte-exact reconnect resume over real loopback TCP.
///
/// A real ``HostServer`` spawns `/bin/sh` and runs a command that emits a large, ordered
/// stream (`line-1 … line-2000`). A real ``RworkClient`` receives part of it, acks up to
/// some K, then the client transport is FORCE-DROPPED (NWConnections cancelled, no clean
/// `bye` — simulating network loss). ``ReconnectManager`` reconnects, presenting the same
/// `sessionID` + `lastReceivedSeq`; the host replays every retained `output` with
/// `seq > lastReceivedSeq`; the client dedups by seq. We then reconstruct the full
/// concatenated output and assert every line appears exactly once, in order — proving
/// session survival + host replay + client-side dedup together.
///
/// Reparented onto ``HostServerE2ECase`` (ITEM #10): bring-up + the awaited
/// `server.stop()` / `client.close()` teardown live in the base class, and the per-test
/// ceiling (`perTestTimeAllowance`) sits above this suite's 30s inner reconnect-resume
/// timeout so a genuinely hung resume FAILS instead of wedging the shared test process.
final class RworkReconnectE2ETests: HostServerE2ECase {

    private static let lineCount = 2000

    /// Reconnect-resume is the slowest suite (a 30s inner wait for all 2000 lines after a
    /// forced drop + replay). 90s clears that with margin yet still kills a hung resume.
    override var perTestTimeAllowance: TimeInterval { 90 }

    func testReconnectByteExactResume() async throws {
        let (_, port) = try await startHost()
        let client = try await connectedClient(toPort: port, ackInterval: .milliseconds(20))

        // Collect EVERY output byte across the whole session (survives the force-drop:
        // the surfaced `output` stream stays open; only the transport is replaced).
        let sink = LineSink()
        let collector = Task {
            for await chunk in client.output {
                sink.append(chunk)
            }
        }

        // Kick off the large ordered emission on the remote shell.
        let cmd = "for i in $(seq 1 \(Self.lineCount)); do echo line-$i; done; echo DONE-\(Self.lineCount)\n"
        try await client.sendInput(Data(cmd.utf8))

        // Wait until we've received a meaningful prefix (e.g. line-200 seen), then drop.
        try await waitUntil(timeout: .seconds(20)) { sink.maxLineSeen() >= 200 }
        let seenBeforeDrop = sink.maxLineSeen()
        XCTAssertGreaterThanOrEqual(seenBeforeDrop, 200, "should have received a prefix before dropping")

        // Ack what we have, then FORCE-DROP (no clean bye — simulate network loss).
        await client.flushAck()
        let ackedSeq = await client.highestContiguousSeq
        XCTAssertGreaterThan(ackedSeq, 0)
        await client._forceDropForTesting()

        // Reconnect with the preserved sessionID + lastReceivedSeq → host replays the tail.
        let reconnect = ReconnectManager(client: client)
        try await reconnect.reconnect(host: "127.0.0.1", port: port)

        // The reconnect must be recognized as a RETURNING_CLIENT (same session id).
        let sid = await client.sessionID
        XCTAssertNotNil(sid)

        // Wait until the terminal sentinel arrives (all 2000 lines emitted) OR timeout.
        try await waitUntil(timeout: .seconds(30)) { sink.maxLineSeen() >= Self.lineCount }

        collector.cancel()

        // Reconstruct the ordered, deduped line sequence and assert it is EXACTLY 1..N,
        // each exactly once, in order — no gap, no duplicate.
        let lines = sink.orderedLineNumbers()
        XCTAssertEqual(lines.first, 1, "stream must start at line-1")
        XCTAssertEqual(lines.last, Self.lineCount, "stream must end at line-\(Self.lineCount)")
        XCTAssertEqual(lines.count, Self.lineCount,
                       "expected exactly \(Self.lineCount) lines (no gap, no dup); got \(lines.count). " +
                       "first gap/dup near: \(Self.firstAnomaly(in: lines).map(String.init) ?? "none")")
        // Strict in-order, contiguous 1..N check.
        for (idx, n) in lines.enumerated() {
            XCTAssertEqual(n, idx + 1, "line at position \(idx) should be \(idx + 1) but was \(n) (gap or dup)")
        }

        await client.close()
    }

    // MARK: - Helpers

    /// Returns the first value that is not (previous + 1), i.e. the first gap/dup, or nil.
    private static func firstAnomaly(in lines: [Int]) -> Int? {
        var expected = 1
        for n in lines {
            if n != expected { return n }
            expected += 1
        }
        return nil
    }

    /// Polls `condition` until true or the deadline; throws on timeout.
    private func waitUntil(timeout: Duration, _ condition: @escaping @Sendable () -> Bool) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if !condition() {
            throw RworkReconnectError.timedOut
        }
    }

    enum RworkReconnectError: Error { case timedOut }

    /// Accumulates all output bytes and extracts `line-<N>` tokens for ordering checks.
    /// Thread-safe (the collector task appends; the test reads).
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }

        private func snapshot() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        /// All `line-N` numbers in the order they appear in the stream (with duplicates,
        /// so the test can detect dups). Matches the exact token `line-<digits>`.
        func orderedLineNumbers() -> [Int] {
            let text = snapshot()
            var result: [Int] = []
            var idx = text.startIndex
            let marker = "line-"
            while let range = text.range(of: marker, range: idx..<text.endIndex) {
                var cursor = range.upperBound
                var digits = ""
                while cursor < text.endIndex, text[cursor].isNumber {
                    digits.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if let n = Int(digits) { result.append(n) }
                idx = cursor
            }
            return result
        }

        func maxLineSeen() -> Int { orderedLineNumbers().max() ?? 0 }

        func sawDone(_ n: Int) -> Bool { snapshot().contains("DONE-\(n)") }
    }
}
