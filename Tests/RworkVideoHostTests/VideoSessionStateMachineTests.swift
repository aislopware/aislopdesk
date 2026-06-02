import XCTest
@testable import RworkVideoHost
import RworkVideoProtocol

/// PURE logic only — drives the host video session state machine with synthetic
/// control messages and asserts the transitions + emitted effects. NO live
/// SCStream / VTCompressionSession / socket is touched (hang-safety rule).
final class VideoSessionStateMachineTests: XCTestCase {
    private let bounds = VideoRect(x: 10, y: 20, width: 800, height: 600)
    private let acceptAll: (UInt32, VideoSize) -> (UInt16, UInt16)? = { _, _ in (800, 600) }

    func testStartGoesIdleToListening() {
        var sm = VideoSessionStateMachine()
        XCTAssertEqual(sm.state, .idle)
        let effects = sm.start()
        XCTAssertEqual(sm.state, .listening)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertFalse(sm.mediaFlowing)
    }

    func testValidHelloAcceptsAndStartsCapture() {
        var sm = VideoSessionStateMachine(nextStreamID: 7)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        XCTAssertEqual(sm.state, .streaming)
        XCTAssertTrue(sm.mediaFlowing)
        XCTAssertEqual(sm.windowID, 42)
        XCTAssertEqual(sm.captureWidth, 800)
        XCTAssertEqual(sm.captureHeight, 600)

        // Ack first, then start capture — in that order.
        XCTAssertEqual(effects.count, 2)
        guard case .sendControl(let ack) = effects[0] else { return XCTFail("expected sendControl first") }
        XCTAssertEqual(ack, .helloAck(accepted: true, streamID: 7, captureWidth: 800, captureHeight: 600, windowBoundsCG: bounds))
        XCTAssertEqual(effects[1], .startCapture(windowID: 42, width: 800, height: 600))
    }

    func testWrongProtocolVersionRejected() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let badVersion: UInt16 = RworkVideoProtocol.version &+ 1
        let hello = VideoControlMessage.hello(protocolVersion: badVersion, requestedWindowID: 1, viewport: VideoSize(width: 100, height: 100))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        XCTAssertEqual(sm.state, .listening) // stayed listening — no accept
        XCTAssertFalse(sm.mediaFlowing)
        XCTAssertEqual(effects.count, 1)
        guard case .sendControl(.helloAck(let accepted, _, _, _, _)) = effects[0] else { return XCTFail("expected reject ack") }
        XCTAssertFalse(accepted)
    }

    func testResolveCaptureSizeNilRejects() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 99, viewport: VideoSize(width: 1, height: 1))
        let effects = sm.handleControl(hello, windowBoundsCG: bounds) { _, _ in nil } // host rejects this window

        XCTAssertEqual(sm.state, .listening)
        XCTAssertEqual(effects.count, 1)
        guard case .sendControl(.helloAck(let accepted, _, _, _, _)) = effects[0] else { return XCTFail("expected reject") }
        XCTAssertFalse(accepted)
    }

    func testDuplicateHelloWhileStreamingReAcksWithoutRestartingCapture() {
        var sm = VideoSessionStateMachine(nextStreamID: 3)
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        // Client retransmits the (unreliable UDP) hello for the SAME window.
        let again = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .streaming)
        // Re-ack only — NO second startCapture.
        XCTAssertEqual(again.count, 1)
        guard case .sendControl(.helloAck(let accepted, let streamID, _, _, _)) = again[0] else { return XCTFail("expected re-ack") }
        XCTAssertTrue(accepted)
        XCTAssertEqual(streamID, 3, "re-ack keeps the same streamID, does not mint a new one")
    }

    func testByeStopsCapture() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)

        let effects = sm.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertFalse(sm.mediaFlowing)
        XCTAssertEqual(effects, [.stopCapture])
    }

    func testStopWhileStreamingEmitsStopCapture() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 42, viewport: VideoSize(width: 800, height: 600))
        _ = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.stop(), [.stopCapture])
        XCTAssertEqual(sm.state, .stopped)
        // A second stop is a no-op.
        XCTAssertTrue(sm.stop().isEmpty)
    }

    func testStopWhileMerelyListeningEmitsNothing() {
        var sm = VideoSessionStateMachine()
        _ = sm.start()
        XCTAssertTrue(sm.stop().isEmpty)
        XCTAssertEqual(sm.state, .stopped)
    }

    func testHelloIgnoredBeforeStart() {
        var sm = VideoSessionStateMachine()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 1, viewport: VideoSize(width: 1, height: 1))
        // No start() — state is .idle, a hello must not accept.
        let effects = sm.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    func testEachAcceptedSessionGetsAFreshStreamID() {
        var a = VideoSessionStateMachine(nextStreamID: 1)
        _ = a.start()
        let hello = VideoControlMessage.hello(protocolVersion: RworkVideoProtocol.version, requestedWindowID: 5, viewport: VideoSize(width: 10, height: 10))
        let e1 = a.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, let s1, _, _, _)) = e1[0] else { return XCTFail() }
        XCTAssertEqual(s1, 1)

        var b = VideoSessionStateMachine(nextStreamID: 2)
        _ = b.start()
        let e2 = b.handleControl(hello, windowBoundsCG: bounds, resolveCaptureSize: acceptAll)
        guard case .sendControl(.helloAck(_, let s2, _, _, _)) = e2[0] else { return XCTFail() }
        XCTAssertEqual(s2, 2)
    }
}
