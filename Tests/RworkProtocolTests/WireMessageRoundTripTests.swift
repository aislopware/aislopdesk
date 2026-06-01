import XCTest
@testable import RworkProtocol

/// Encodes a message, feeds the resulting frame bytes through a fresh `FrameDecoder`,
/// and returns the decoded message — the canonical round-trip helper.
private func roundTrip(_ message: WireMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WireMessage? {
    var decoder = FrameDecoder()
    decoder.append(message.encode())
    return try decoder.nextMessage()
}

final class WireMessageRoundTripTests: XCTestCase {

    func testOutputRoundTripRepresentativeAndBoundary() throws {
        let cases: [WireMessage] = [
            .output(seq: 1, bytes: Data("hello".utf8)),
            .output(seq: Int64.max, bytes: Data()),                 // empty payload, max seq
            .output(seq: 42, bytes: Data([0x1b, 0x5b, 0x32, 0x4a])), // ESC [ 2 J
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testExitRoundTrip() throws {
        for code: Int32 in [0, 1, -1, Int32.max, Int32.min] {
            let message = WireMessage.exit(code: code)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testInputRoundTrip() throws {
        let cases: [WireMessage] = [
            .input(Data()),                                  // empty
            .input(Data("ls -la\n".utf8)),
            .input(Data([0x00, 0xff, 0x80, 0x7f])),          // arbitrary bytes incl NUL & high bit
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testHelloRoundTripNewAndResumeSessions() throws {
        let cases: [WireMessage] = [
            .hello(protocolVersion: Rwork.protocolVersion, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0),
            .hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: Int64.max),
            .hello(protocolVersion: UInt16.max, sessionID: UUID(), lastReceivedSeq: -1),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testResizeRoundTripBoundaries() throws {
        let cases: [WireMessage] = [
            .resize(cols: 0, rows: 0, pxWidth: 0, pxHeight: 0),
            .resize(cols: 65535, rows: 65535, pxWidth: 65535, pxHeight: 65535),
            .resize(cols: 80, rows: 24, pxWidth: 640, pxHeight: 384),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testAckRoundTrip() throws {
        for seq: Int64 in [0, 1, Int64.max, -1] {
            let message = WireMessage.ack(seq: seq)
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testByeRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.bye), .bye)
    }

    func testHelloAckRoundTrip() throws {
        let cases: [WireMessage] = [
            .helloAck(sessionID: UUID(), resumeFromSeq: 1, returningClient: true),
            .helloAck(sessionID: WireMessage.newSessionID, resumeFromSeq: 0, returningClient: false),
            .helloAck(sessionID: UUID(), resumeFromSeq: Int64.max, returningClient: true),
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testTitleRoundTripIncludingCJKAndEmoji() throws {
        let cases: [WireMessage] = [
            .title(""),                          // empty
            .title("zsh — ~/project"),
            .title("日本語タイトル"),               // CJK
            .title("build ✅ done 🚀 — café"),    // multi-byte emoji + accent
        ]
        for message in cases {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testBellRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.bell), .bell)
    }

    func testMessageTypeBytesMatchContract() {
        XCTAssertEqual(WireMessage.output(seq: 1, bytes: Data()).messageType, 1)
        XCTAssertEqual(WireMessage.exit(code: 0).messageType, 2)
        XCTAssertEqual(WireMessage.input(Data()).messageType, 3)
        XCTAssertEqual(WireMessage.hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: 0).messageType, 10)
        XCTAssertEqual(WireMessage.resize(cols: 0, rows: 0, pxWidth: 0, pxHeight: 0).messageType, 11)
        XCTAssertEqual(WireMessage.ack(seq: 0).messageType, 12)
        XCTAssertEqual(WireMessage.bye.messageType, 13)
        XCTAssertEqual(WireMessage.helloAck(sessionID: UUID(), resumeFromSeq: 0, returningClient: false).messageType, 20)
        XCTAssertEqual(WireMessage.title("").messageType, 21)
        XCTAssertEqual(WireMessage.bell.messageType, 22)
    }

    func testChannelAssignment() {
        XCTAssertEqual(WireMessage.output(seq: 1, bytes: Data()).channel, .data)
        XCTAssertEqual(WireMessage.exit(code: 0).channel, .data)
        XCTAssertEqual(WireMessage.input(Data()).channel, .data)
        XCTAssertEqual(WireMessage.hello(protocolVersion: 1, sessionID: UUID(), lastReceivedSeq: 0).channel, .control)
        XCTAssertEqual(WireMessage.bye.channel, .control)
        XCTAssertEqual(WireMessage.bell.channel, .control)
    }

    func testFrameLayoutLengthPrefixExcludesPrefixBytes() {
        // output(seq:1, bytes:"abc") => body = [type(1)] + [8-byte seq] + 3 bytes = 12.
        let frame = WireMessage.output(seq: 1, bytes: Data("abc".utf8)).encode()
        XCTAssertEqual(frame.count, 4 + 12)
        // Big-endian prefix == 12.
        let prefix = (UInt32(frame[0]) << 24) | (UInt32(frame[1]) << 16) | (UInt32(frame[2]) << 8) | UInt32(frame[3])
        XCTAssertEqual(prefix, 12)
        // First payload byte is the message type.
        XCTAssertEqual(frame[4], 1)
    }
}
