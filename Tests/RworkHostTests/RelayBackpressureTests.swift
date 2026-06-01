#if canImport(Darwin)
import Darwin
#endif
import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// WF-3 relay backpressure gate tests.
///
/// The full end-to-end backpressure path (offline client → 4 MiB replay backlog →
/// `drainPauses` true → read loop stops → kernel PTY buffer backpressures `yes`) is
/// covered with a real client in WF-4. Here we test the **gate logic directly**: a
/// fast PTY producer plus a `PTYReadLoop` whose pause we toggle, asserting that a
/// paused loop stops consuming the master fd and resumes when unpaused. This is the
/// load-bearing contract (`PTYReadLoop` parks with zero master syscalls while paused).
final class RelayBackpressureTests: XCTestCase {

    func testReadLoopGateStopsAndResumesConsumption() throws {
        // Fast producer: `yes` floods the PTY with "y\n" forever.
        let pty = PTYProcess()
        try pty.spawn("/usr/bin/yes", arguments: ["rwork"], environment: HostEnvironment.curated())

        let counter = ByteCounter()
        let loop = PTYReadLoop(
            fd: pty.masterFD,
            onChunk: { chunk in counter.add(chunk.count) },
            onEOF: {}
        )

        // PAUSED before start: the loop must not consume anything.
        loop.setPaused(true)
        loop.start()

        // Give the producer time to fill the kernel PTY buffer; the loop must stay at 0.
        Thread.sleep(forTimeInterval: 0.3)
        let pausedCount = counter.value
        XCTAssertEqual(pausedCount, 0, "read loop consumed \(pausedCount) bytes while paused")

        // RESUME: the loop should start draining the flood.
        loop.setPaused(false)
        let resumed = pollUntil(timeout: 3) { counter.value > 0 }
        XCTAssertTrue(resumed, "read loop did not resume consuming after unpause")
        let afterResume = counter.value
        XCTAssertGreaterThan(afterResume, 0)

        // PAUSE again: consumption must plateau (no meaningful new bytes while parked).
        loop.setPaused(true)
        Thread.sleep(forTimeInterval: 0.2)
        let plateau = counter.value
        Thread.sleep(forTimeInterval: 0.3)
        let afterPlateau = counter.value
        // Allow a small slack for at most one in-flight chunk that was mid-read when we
        // paused; the loop parks before its *next* read, so growth must be tiny.
        XCTAssertLessThanOrEqual(
            afterPlateau - plateau, PTYReadLoop.readChunkSize,
            "read loop kept consuming while paused (grew by \(afterPlateau - plateau))")

        loop.stop()
        pty.terminate()
    }

    /// End-to-end-ish gate: drive `HostSessionTransport`'s real `drainPauses` by marking
    /// the client offline and appending past the 4 MiB offline gate, asserting the
    /// transition fires `true`, then `false` after an ack drops below the gate.
    func testTransportDrainPausesTransitionsDriveGate() async throws {
        let transport = HostSessionTransport(sessionID: UUID())

        // Observe drainPauses transitions.
        let observed = TransitionRecorder()
        let observer = Task {
            for await pause in transport.drainPauses { observed.record(pause) }
        }

        // Client offline; push > 4 MiB of retained output to cross the offline gate.
        await transport.setClientOnline(false)
        let chunk = Data(count: 512 * 1024) // 0.5 MiB
        for _ in 0..<9 { // 4.5 MiB total > 4 MiB gate
            _ = try await transport.sendOutput(chunk)
        }
        let paused = await pollUntilAsync(timeout: 3) { observed.last == true }
        XCTAssertTrue(paused, "drainPauses never asserted true past the 4 MiB offline gate")

        // Ack everything: retained bytes drop to 0, below the gate → resume.
        await transport.acknowledge(upTo: await transport.highestSeq)
        let resumed = await pollUntilAsync(timeout: 3) { observed.last == false }
        XCTAssertTrue(resumed, "drainPauses never deasserted after acking the backlog")

        observer.cancel()
    }

    // MARK: helpers

    private func pollUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    private func pollUntilAsync(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

/// Thread-safe byte counter for the read-loop callback (called off the test thread).
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Records the last observed drain-pause boolean (off the test thread).
final class TransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Bool?
    func record(_ v: Bool) { lock.lock(); lastValue = v; lock.unlock() }
    var last: Bool? { lock.lock(); defer { lock.unlock() }; return lastValue }
}
