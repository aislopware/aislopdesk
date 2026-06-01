import XCTest
import RworkProtocol
@testable import RworkHost

/// Smoke tests so the target compiles and runs. Real PTY spawn + relay land in WF-3.
final class RworkHostSmokeTests: XCTestCase {

    func testPTYProcessInstantiatesWithUnsetFDAndPID() {
        let pty = PTYProcess()
        XCTAssertEqual(pty.masterFD, -1)
        XCTAssertEqual(pty.pid, -1)
    }

    func testHostSessionExposesStableID() {
        let id = UUID()
        let session = HostSession(sessionID: id)
        XCTAssertEqual(session.sessionID, id)
    }

    func testHostServerHoldsPortAndStartsEmpty() {
        let server = HostServer(port: 7420)
        XCTAssertEqual(server.port, 7420)
        XCTAssertTrue(server.sessions.isEmpty)
    }
}
