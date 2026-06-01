import XCTest
import RworkProtocol
@testable import RworkClient

/// Smoke tests so the target compiles and runs. Real connect/reconnect land in WF-4.
final class RworkClientSmokeTests: XCTestCase {

    func testClientConnectionStartsUnconnected() {
        let connection = ClientConnection()
        XCTAssertNil(connection.sessionID)
        XCTAssertNil(connection.connection)
        XCTAssertEqual(connection.lastReceivedSeq, 0)
    }

    func testNoteReceivedOutputAdvancesContiguously() {
        let connection = ClientConnection()
        connection.noteReceivedOutput(seq: 1)
        connection.noteReceivedOutput(seq: 2)
        XCTAssertEqual(connection.lastReceivedSeq, 2)
        // A gap (skip to 4) must not advance the contiguous counter.
        connection.noteReceivedOutput(seq: 4)
        XCTAssertEqual(connection.lastReceivedSeq, 2)
    }

    func testReconnectManagerDefaultBackoff() {
        let manager = ReconnectManager(connection: ClientConnection())
        XCTAssertEqual(manager.backoff.multiplier, 2.0)
    }
}
