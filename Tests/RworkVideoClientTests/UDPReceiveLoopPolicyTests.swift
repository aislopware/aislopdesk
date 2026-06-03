#if canImport(Network)
import XCTest
@testable import RworkVideoClient

/// BUG-L regression (client side): the UDP receive loop must survive a transient
/// per-datagram error and keep itself armed, stopping ONLY when the connection is dead.
///
/// The old loop re-armed `if error == nil`, so a single recoverable per-datagram error
/// (e.g. ICMP port-unreachable surfaced as ECONNREFUSED while the `NWConnection` stays
/// `.ready`) ended the loop forever and the client silently stopped receiving all video.
/// The re-arm decision is now purely "is the connection still alive?" (driven by the
/// connection's `stateUpdateHandler`, not the per-receive error), which is unit-testable
/// without a socket. The live socket teardown still needs the hardware video pass.
final class UDPReceiveLoopPolicyTests: XCTestCase {
    func testRearmsWhileConnectionAlive() {
        // A transient receive error with the connection still alive → keep receiving.
        XCTAssertTrue(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true))
    }

    func testStopsWhenConnectionDead() {
        // The state handler marked the connection dead (.failed/.cancelled) → stop the
        // loop; do NOT spin on a genuinely dead socket.
        XCTAssertFalse(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false))
    }
}
#endif
