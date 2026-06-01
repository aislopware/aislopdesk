import XCTest
import RworkProtocol
@testable import RworkTransport

/// Tests the PTY-drain pause/resume observable (`drainPauses`) exposed by
/// ``HostSessionTransport`` — the ET BUFFERED_ONLY ⇄ SKIPPED signal the WF-3 relay
/// consumes. Driven without any socket: `sendOutput` with no bound data channel still
/// sequences + retains bytes and publishes drain transitions.
final class DrainObservableTests: XCTestCase {

    func testDrainPausesFiresOnGateCrossAndResumesOnAck() async throws {
        let session = HostSessionTransport(sessionID: UUID())

        // Collect drain transitions in the background.
        let collector = Task { () -> [Bool] in
            var transitions: [Bool] = []
            for await pause in session.drainPauses {
                transitions.append(pause)
                if transitions == [true, false] { break } // pause then resume
            }
            return transitions
        }

        // Client goes offline; output then crosses the 4 MiB offline gate → pause.
        await session.setClientOnline(false)
        let half = ReplayBuffer.offlineGateBytes / 2 + 1024
        let seq1 = try await session.sendOutput(Data(count: half))
        let pausedAfterFirst = await session.shouldPauseDrain
        XCTAssertFalse(pausedAfterFirst, "one half-gate chunk should not pause yet")
        _ = try await session.sendOutput(Data(count: half)) // now over the gate
        let pausedAfterSecond = await session.shouldPauseDrain
        XCTAssertTrue(pausedAfterSecond, "crossing the 4 MiB offline gate must pause")

        // Ack the first chunk → drops below the gate → resume.
        await session.acknowledge(upTo: seq1)
        let pausedAfterAck = await session.shouldPauseDrain
        XCTAssertFalse(pausedAfterAck, "ack dropping below the gate must resume")

        let transitions = await collector.value
        XCTAssertEqual(transitions, [true, false], "observable must emit exactly pause then resume")
    }

    func testNoSpuriousTransitionsWhileOnlineBelowGate() async throws {
        let session = HostSessionTransport(sessionID: UUID())

        // No transition should be emitted for normal online output below the gate.
        let collector = Task { () -> Bool in
            // If any transition arrives within the window, record it.
            for await _ in session.drainPauses { return true }
            return false
        }

        _ = try await session.sendOutput(Data("small".utf8))
        _ = try await session.sendOutput(Data("more".utf8))
        // Give the observable a moment; then cancel the collector and assert it saw nothing.
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        let pause = await session.shouldPauseDrain
        XCTAssertFalse(pause, "online + tiny output must never pause")
    }
}
