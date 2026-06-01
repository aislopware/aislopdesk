import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// Smoke tests so the target compiles and basic wiring holds. Real PTY spawn + relay
/// + backpressure live in `PTYProcessTests` / `RelayBackpressureTests`.
final class RworkHostSmokeTests: XCTestCase {

    func testPTYProcessInstantiatesWithUnsetFDAndPID() {
        let pty = PTYProcess()
        XCTAssertEqual(pty.masterFD, -1)
        XCTAssertEqual(pty.pid, -1)
    }

    func testHostSessionExposesStableID() {
        let id = UUID()
        let transport = HostSessionTransport(sessionID: id)
        let session = HostSession(sessionID: id, pty: PTYProcess(), transport: transport)
        XCTAssertEqual(session.sessionID, id)
        XCTAssertEqual(session.transport.sessionID, id)
    }

    func testHostServerHoldsPortAndStartsEmpty() {
        let server = HostServer(port: 7420)
        XCTAssertEqual(server.port, 7420)
        XCTAssertTrue(server.liveSessionIDs().isEmpty)
        XCTAssertTrue(server.shellPath.hasPrefix("/"))
    }

    func testCuratedEnvironmentHasSaneTerminalDefaults() {
        let env = HostEnvironment.curated(parent: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        XCTAssertEqual(env["TERM"], "xterm-256color") // TODO(WF-7): xterm-ghostty
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["NCURSES_NO_UTF8_ACS"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testLoginArgv0HasLeadingDash() {
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/bin/zsh"), "-zsh")
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/usr/local/bin/fish"), "-fish")
    }
}
