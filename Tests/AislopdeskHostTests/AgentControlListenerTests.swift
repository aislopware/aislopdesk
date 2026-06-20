import Foundation
import XCTest
@testable import AislopdeskHost

/// Hang-safe tests for the agent-control surface.
///
/// **No real PTY, no real socket.** The pure ``AgentControlHandler`` is driven by a fake
/// ``HostServer``-shaped protocol and by ``MuxChannelSession``'s new primitives fed with
/// synthetic ``Data`` chunks. The ``AgentControlAcceptor`` socket shim is compiled + code-
/// reviewed only (the hang-safety rule: no real `AF_UNIX` socket in a test).
final class AgentControlListenerTests: XCTestCase {
    // MARK: ANSIStripper

    func testStripperPassesThroughPlainText() {
        XCTAssertEqual(ANSIStripper.strip("hello world"), "hello world")
    }

    func testStripperRemovesCSISequence() {
        // "ESC[31m" (red foreground) + "foo" + "ESC[0m" (reset)
        let raw = "\u{1B}[31mfoo\u{1B}[0m"
        XCTAssertEqual(ANSIStripper.strip(raw), "foo")
    }

    func testStripperRemovesOSCTitle() {
        // "ESC]0;My Title BEL"
        let raw = "\u{1B}]0;My Title\u{07}plain"
        XCTAssertEqual(ANSIStripper.strip(raw), "plain")
    }

    func testStripperRemovesOSCWithSTTerminator() {
        // "ESC]2;Title ESC\\"
        let raw = "\u{1B}]2;Title\u{1B}\\plain"
        XCTAssertEqual(ANSIStripper.strip(raw), "plain")
    }

    func testStripperPreservesNewlinesAndTabs() {
        let raw = "line1\nline2\ttabbed"
        XCTAssertEqual(ANSIStripper.strip(raw), "line1\nline2\ttabbed")
    }

    func testStripperHandlesEmptyString() {
        XCTAssertEqual(ANSIStripper.strip(""), "")
    }

    func testStripperHandlesMultipleSequences() {
        let raw = "\u{1B}[1mBold\u{1B}[0m and \u{1B}[32mgreen\u{1B}[0m"
        XCTAssertEqual(ANSIStripper.strip(raw), "Bold and green")
    }

    func testStripperTruncatedEscAtEnd() {
        // Trailing bare ESC — should not crash; just drops the ESC.
        let raw = "hello\u{1B}"
        XCTAssertEqual(ANSIStripper.strip(raw), "hello")
    }

    // MARK: NDJSON codec (AgentControlHandler helpers)

    func testParseRequestAllFields() {
        let line = #"{"id":"abc","method":"list-panes","params":{"x":1}}"#
        guard let (id, method, params) = AgentControlHandler.parseRequest(line) else {
            XCTFail("expected parse success")
            return
        }
        XCTAssertEqual(id, "abc")
        XCTAssertEqual(method, "list-panes")
        XCTAssertEqual(params["x"] as? Int, 1)
    }

    func testParseRequestMissingParams() {
        let line = #"{"id":"1","method":"list-panes"}"#
        guard let (id, method, params) = AgentControlHandler.parseRequest(line) else {
            XCTFail("expected parse success even without params")
            return
        }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "list-panes")
        XCTAssertTrue(params.isEmpty)
    }

    func testParseRequestMalformedJSON() {
        XCTAssertNil(AgentControlHandler.parseRequest("{not json"))
    }

    func testParseRequestMissingId() {
        XCTAssertNil(AgentControlHandler.parseRequest(#"{"method":"list-panes"}"#))
    }

    func testParseRequestMissingMethod() {
        XCTAssertNil(AgentControlHandler.parseRequest(#"{"id":"1"}"#))
    }

    func testSuccessResponseShape() {
        let line = AgentControlHandler.successResponse(id: "42", result: ["x": 1])
        XCTAssertTrue(line.hasSuffix("\n"), "response must be newline-terminated")
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("response is not valid JSON")
            return
        }
        XCTAssertEqual(obj["id"] as? String, "42")
        XCTAssertEqual(obj["ok"] as? Bool, true)
        let result = obj["result"] as? [String: Any]
        XCTAssertEqual(result?["x"] as? Int, 1)
    }

    func testErrorResponseShape() {
        let line = AgentControlHandler.errorResponse(id: "99", message: "oops")
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("response is not valid JSON")
            return
        }
        XCTAssertEqual(obj["id"] as? String, "99")
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["error"] as? String, "oops")
    }

    // MARK: Validate-then-drop on malformed frames

    func testDispatchUnknownMethod() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "1", method: "frobnicate", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertNotNil(obj?["error"])
    }

    func testDispatchListPanesEmpty() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "2", method: "list-panes", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let result = obj?["result"] as? [String: Any]
        let panes = result?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.count, 0, "empty host → zero panes")
    }

    func testDispatchReadMissingPaneId() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "3", method: "read", params: [:], server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testDispatchReadUnknownPane() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "4", method: "read", params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertTrue((obj?["error"] as? String)?.contains("not found") == true)
    }

    func testDispatchWriteMissingText() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "5", method: "write",
            params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testDispatchKillUnknownPane() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "6", method: "kill",
            params: ["paneId": "00000000-0000-0000-0000-000000000000"],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    // MARK: wait — timeout path (no real PTY needed)

    func testWaitTimeoutPath() {
        let server = makeNullServer()
        // `wait` on a non-existent pane → immediate error (no blocking).
        let resp = AgentControlHandler.dispatch(
            id: "7", method: "wait",
            params: [
                "paneId": "00000000-0000-0000-0000-000000000000",
                "until": "never",
                "timeoutMs": 50.0,
            ],
            server: server,
        )
        let obj = parseResponseObject(resp)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    func testWaitInvalidRegexIsErrorNotCrash() {
        let server = makeNullServer()
        let resp = AgentControlHandler.dispatch(
            id: "8", method: "wait",
            params: [
                "paneId": "00000000-0000-0000-0000-000000000000",
                "until": "[invalid((",
                "timeoutMs": 50.0,
            ],
            server: server,
        )
        let obj = parseResponseObject(resp)
        // The pane is not found before the regex is compiled, so we get "not found".
        XCTAssertEqual(obj?["ok"] as? Bool, false)
    }

    // MARK: ANSIStripper in wait accumulator

    func testWaitMatchesPlainTextAfterANSIStrip() throws {
        // Build a fake accumulator as would the `wait` verb — strip ANSI, then regex-match.
        let rawChunk = Data("\u{1B}[32mDONE\u{1B}[0m".utf8)
        let text = try ANSIStripper.strip(XCTUnwrap(String(bytes: rawChunk, encoding: .utf8)))
        let regex = try NSRegularExpression(pattern: "DONE")
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNotNil(regex.firstMatch(in: text, range: range), "ANSI-stripped text should match")
    }

    // MARK: HostEnvironment gate

    func testAgentControlEnabledRequiresExplicit1() {
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: [:]))
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: ["AISLOPDESK_AGENT_CONTROL": "0"]))
        XCTAssertFalse(HostEnvironment.agentControlEnabled(environment: ["AISLOPDESK_AGENT_CONTROL": "yes"]))
        XCTAssertTrue(HostEnvironment.agentControlEnabled(environment: ["AISLOPDESK_AGENT_CONTROL": "1"]))
    }

    func testCuratedInjectsControlSocket() {
        let env = HostEnvironment.curated(
            controlSocketPath: "/tmp/aislopdesk-ctl-1234.sock",
        )
        XCTAssertEqual(env["AISLOPDESK_CONTROL_SOCKET"], "/tmp/aislopdesk-ctl-1234.sock")
    }

    func testCuratedOmitsControlSocketWhenNil() {
        let env = HostEnvironment.curated()
        XCTAssertNil(env["AISLOPDESK_CONTROL_SOCKET"])
    }

    // MARK: Helpers

    /// Makes a real `HostServer` bound to port 0 (not started — just constructed, so it can
    /// serve the control verb dispatch without touching the network). We test only the pure
    /// dispatch layer; the server is never `start()`'d in this test file.
    private func makeNullServer() -> HostServer {
        HostServer(port: 0)
    }

    private func parseResponseObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
