import XCTest
import RworkClient
import RworkTerminal
@testable import RworkClientUI

/// State-transition tests for the `@MainActor @Observable` ``TerminalViewModel``: it folds
/// `RworkClient.Event`s + `output` chunks into observable connection / title / byte-count /
/// exit state. Driven synchronously via `handle`/`ingestOutput` (the same path
/// `observe(client:)` uses), so the transitions are deterministic and need no network.
@MainActor
final class TerminalViewModelTests: XCTestCase {

    func testFirstOutputFlipsConnectingToConnected() {
        let model = TerminalViewModel()
        XCTAssertEqual(model.connectionStatus, .idle)

        // observe() sets .connecting; simulate that precondition.
        model.markReconnecting()
        XCTAssertEqual(model.connectionStatus, .reconnecting)

        model.ingestOutput(Data("hello".utf8))
        XCTAssertEqual(model.connectionStatus, .connected, "first byte after reconnecting → connected")
        XCTAssertEqual(model.bytesReceived, 5)
    }

    func testTitleEvent() {
        let model = TerminalViewModel()
        model.handle(.title("~/proj — zsh"))
        XCTAssertEqual(model.title, "~/proj — zsh")
    }

    func testBellEventSetsAndClears() {
        let model = TerminalViewModel()
        XCTAssertFalse(model.bellPending)
        model.handle(.bell)
        XCTAssertTrue(model.bellPending)
        model.clearBell()
        XCTAssertFalse(model.bellPending)
    }

    func testExitEvent() {
        let model = TerminalViewModel()
        model.handle(.exit(code: 130))
        XCTAssertEqual(model.connectionStatus, .exited(code: 130))
    }

    func testDisconnectedEvent() {
        let model = TerminalViewModel()
        model.handle(.disconnected(reason: "stream ended (FIN)"))
        XCTAssertEqual(model.connectionStatus, .disconnected(reason: "stream ended (FIN)"))
    }

    func testReconnectedEventRestoresConnectedAndResumeSeq() {
        let model = TerminalViewModel()
        let sid = UUID()
        model.handle(.disconnected(reason: "drop"))
        model.markReconnecting()
        model.handle(.reconnected(sessionID: sid, resumeFromSeq: 42))
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.sessionID, sid)
        XCTAssertEqual(model.lastResumeSeq, 42)
    }

    func testOutputFeedsSurface() {
        final class CapturingSurface: TerminalSurface, @unchecked Sendable {
            var fed = Data()
            func feed(_ bytes: Data) { fed.append(bytes) }
            func setSize(cols: UInt16, rows: UInt16) {}
            func handleInput(_ bytes: Data) {}
            var onWrite: ((Data) -> Void)?
        }
        let surface = CapturingSurface()
        let model = TerminalViewModel(surface: surface)
        model.ingestOutput(Data([0x41, 0x42]))
        model.ingestOutput(Data([0x43]))
        XCTAssertEqual(surface.fed, Data([0x41, 0x42, 0x43]), "model mirrors output into the renderer seam")
        XCTAssertEqual(model.bytesReceived, 3)
    }

    func testSendInputRoutesThroughInputSinkInOrder() {
        let model = TerminalViewModel()
        var captured = Data()
        model.inputSink = { captured.append($0) }
        model.sendInput(Data([0x61, 0x62]))
        model.sendInput(Data([0x63]))
        XCTAssertEqual(captured, Data([0x61, 0x62, 0x63]), "sendInput funnels through inputSink, in order")
    }

    func testSendInputWithoutSinkIsNoOp() {
        let model = TerminalViewModel()
        // Disconnected (no inputSink): keystrokes are dropped, never crash.
        model.sendInput(Data([0x61]))
        XCTAssertNil(model.inputSink)
    }

    func testSendResizeRoutesThroughResizeSink() {
        let model = TerminalViewModel()
        var captured: [(cols: UInt16, rows: UInt16)] = []
        model.resizeSink = { captured.append((cols: $0, rows: $1)) }
        model.sendResize(cols: 120, rows: 40)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.cols, 120)
        XCTAssertEqual(captured.first?.rows, 40)
    }

    func testSendResizeWithoutSinkIsNoOp() {
        let model = TerminalViewModel()
        model.sendResize(cols: 80, rows: 24)
        XCTAssertNil(model.resizeSink)
    }

    func testSendResizeCoalescesConsecutiveDuplicates() {
        let model = TerminalViewModel()
        var calls: [(cols: UInt16, rows: UInt16)] = []
        model.resizeSink = { calls.append((cols: $0, rows: $1)) }
        model.sendResize(cols: 80, rows: 24)
        model.sendResize(cols: 80, rows: 24)   // duplicate (libghostty double-emits) → coalesced
        model.sendResize(cols: 100, rows: 30)  // changed → forwarded
        model.sendResize(cols: 100, rows: 30)  // duplicate → coalesced
        XCTAssertEqual(calls.count, 2, "consecutive duplicate resizes are coalesced")
        XCTAssertEqual(calls.first?.cols, 80)
        XCTAssertEqual(calls.last?.cols, 100)
    }

    func testResetReArmsResize() {
        let model = TerminalViewModel()
        var calls = 0
        model.resizeSink = { _, _ in calls += 1 }
        model.sendResize(cols: 80, rows: 24)
        model.reset()                          // a fresh session must re-assert its grid size
        model.sendResize(cols: 80, rows: 24)
        XCTAssertEqual(calls, 2, "reset re-arms coalescing so the same size re-sends on reconnect")
    }

    func testResetClearsState() {
        let model = TerminalViewModel()
        model.handle(.title("x"))
        model.ingestOutput(Data("abc".utf8))
        model.handle(.bell)
        model.reset()
        XCTAssertNil(model.title)
        XCTAssertEqual(model.bytesReceived, 0)
        XCTAssertFalse(model.bellPending)
        XCTAssertEqual(model.connectionStatus, .idle)
    }
}
