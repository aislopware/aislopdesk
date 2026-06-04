import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkClient

/// Smoke tests so the target compiles and the basic seams behave. Real connect /
/// reconnect / dedup are exercised by the e2e tests in this target.
final class RworkClientSmokeTests: XCTestCase {

    /// An `RworkClient` whose transport factory is inert (never invoked — these tests never
    /// `connect()`). Mirrors how production injects a `MuxClientTransport` over a shared connection.
    private func makeUnconnectedClient() -> RworkClient {
        RworkClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw RworkTransportError.notConnected("inert test transport") },
                release: { _, _, _ in }
            )
        })
    }

    func testRworkClientStartsUnconnected() async {
        let client = makeUnconnectedClient()
        let sid = await client.sessionID
        let seq = await client.highestContiguousSeq
        XCTAssertNil(sid)
        XCTAssertEqual(seq, 0)
    }

    func testReconnectManagerDefaultBackoffCappedAtTwoSeconds() {
        let manager = ReconnectManager(client: makeUnconnectedClient())
        XCTAssertEqual(manager.backoff.multiplier, 2.0)
        XCTAssertEqual(manager.backoff.maximum, .seconds(2))
    }

    func testBackoffNextCapsAtMaximum() {
        let backoff = ReconnectManager.Backoff(initial: .milliseconds(250), maximum: .seconds(2), multiplier: 2.0)
        var d = backoff.initial
        XCTAssertEqual(d, .milliseconds(250))
        d = backoff.next(after: d) // 500ms
        XCTAssertEqual(d, .milliseconds(500))
        d = backoff.next(after: d) // 1s
        XCTAssertEqual(d, .seconds(1))
        d = backoff.next(after: d) // 2s (cap)
        XCTAssertEqual(d, .seconds(2))
        d = backoff.next(after: d) // stays 2s
        XCTAssertEqual(d, .seconds(2))
    }
}
