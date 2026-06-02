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
        // The plain-shell path advertises the SAME libghostty TERM as the Claude Code
        // path (single source of truth) — the client renders with libghostty.
        XCTAssertEqual(env["TERM"], "xterm-ghostty")
        XCTAssertEqual(env["TERM"], HostEnvironment.defaultTerm)
        XCTAssertEqual(env["TERM"], ClaudeCodeProfile.Term.ghostty.rawValue,
                       "plain-shell TERM must share the ClaudeCodeProfile ghostty source of truth")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["NCURSES_NO_UTF8_ACS"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testCuratedEnvironmentHonoursExplicitTermOverride() {
        // The TERM is a parameter so a caller can select the documented fallback
        // (xterm-256color, #54700) symmetrically with ClaudeCodeProfile's toggle.
        let env = HostEnvironment.curated(
            parent: ["PATH": "/usr/bin"],
            term: ClaudeCodeProfile.Term.xterm256.rawValue
        )
        XCTAssertEqual(env["TERM"], "xterm-256color")
    }

    func testLoginArgv0HasLeadingDash() {
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/bin/zsh"), "-zsh")
        XCTAssertEqual(HostEnvironment.loginArgv0(forShell: "/usr/local/bin/fish"), "-fish")
    }

    // MARK: rwork-hostd arg parsing → LaunchMode mapping

    func testParseDefaultsToShellLaunchMode() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["rwork-hostd"]))
        XCTAssertEqual(parsed.port, 7420)
        XCTAssertNil(parsed.shell)
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    func testParseClaudeWithXterm256YieldsClaudeCodeWithXterm256Term() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["rwork-hostd", "--claude", "--xterm256"]))
        XCTAssertEqual(
            parsed.launchMode,
            .claudeCode(ClaudeCodeProfile(term: .xterm256)),
            "--claude --xterm256 must select the claudeCode launch mode with TERM=xterm-256color"
        )
        // Spell the TERM out explicitly so a regression in the toggle is obvious.
        guard case let .claudeCode(profile) = parsed.launchMode else {
            return XCTFail("expected claudeCode launch mode")
        }
        XCTAssertEqual(profile.term, .xterm256)
        XCTAssertEqual(profile.term.rawValue, "xterm-256color")
    }

    func testParseClaudeWithoutXterm256DefaultsToGhosttyTerm() throws {
        let parsed = try XCTUnwrap(HostdArguments.parse(["rwork-hostd", "--claude"]))
        XCTAssertEqual(parsed.launchMode, .claudeCode(ClaudeCodeProfile(term: .ghostty)))
    }

    func testParseXterm256WithoutClaudeStaysShell() throws {
        // --xterm256 only has meaning with --claude; on its own it is a no-op.
        let parsed = try XCTUnwrap(HostdArguments.parse(["rwork-hostd", "--xterm256"]))
        XCTAssertEqual(parsed.launchMode, .shell)
    }

    func testParseHelpReturnsNil() {
        XCTAssertNil(HostdArguments.parse(["rwork-hostd", "--help"]))
        XCTAssertNil(HostdArguments.parse(["rwork-hostd", "-h"]))
    }

    func testParsePortAndShellAlongsideClaude() throws {
        let parsed = try XCTUnwrap(
            HostdArguments.parse(["rwork-hostd", "--port", "9001", "--shell", "/bin/bash", "--claude"])
        )
        XCTAssertEqual(parsed.port, 9001)
        XCTAssertEqual(parsed.shell, "/bin/bash")
        XCTAssertEqual(parsed.launchMode, .claudeCode(ClaudeCodeProfile(term: .ghostty)))
    }
}
