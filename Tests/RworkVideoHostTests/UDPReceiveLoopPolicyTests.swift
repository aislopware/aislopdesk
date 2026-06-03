#if os(macOS)
import XCTest
@testable import RworkVideoHost

/// BUG-L regression (host side): the host's UDP receive loop must survive a transient
/// per-datagram error and keep itself armed, stopping ONLY when the flow is dead.
///
/// The old loop re-armed `if error == nil`, so a single recoverable per-datagram error
/// (e.g. ICMP port-unreachable surfaced as ECONNREFUSED while the flow stays `.ready`)
/// ended the loop forever and the host silently stopped receiving the client's input /
/// recovery requests. The re-arm decision is now purely "is the flow still alive?"
/// (driven by the connection's state handler, not the per-receive error). The live
/// socket teardown still needs the hardware video pass.
final class UDPReceiveLoopPolicyTests: XCTestCase {
    func testRearmsWhileFlowAlive() {
        XCTAssertTrue(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true))
    }

    func testStopsWhenFlowDead() {
        XCTAssertFalse(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false))
    }
}
#endif
