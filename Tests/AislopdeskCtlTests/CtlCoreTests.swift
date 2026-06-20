import AislopdeskCtlCore
import Foundation
import XCTest

/// Hang-safe tests for the aislopdesk-ctl CLI's pure core.
///
/// No real socket, no real PTY. The ``AislopdeskCtlCore`` library (arg-parsing +
/// NDJSON helpers + verb param builders) is driven directly. The ``aislopdesk-ctl``
/// executable's socket I/O (``sendRequest``) is NOT exercised here — it lives in
/// ``main.swift`` and is compiled + code-reviewed only (hang-safety rule: no real
/// AF_UNIX socket in a unit test).
final class CtlCoreTests: XCTestCase {
    // MARK: - parseGlobal

    func testParseGlobalSubcommandOnly() {
        let result = parseGlobal(["aislopdesk-ctl", "list-panes"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "list-panes")
        XCTAssertEqual(g.socketPath, "")
        XCTAssertTrue(g.rest.isEmpty)
    }

    func testParseGlobalSocketFlag() {
        let result = parseGlobal(["aislopdesk-ctl", "--socket", "/tmp/test.sock", "read", "some-uuid"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.socketPath, "/tmp/test.sock")
        XCTAssertEqual(g.subcommand, "read")
        XCTAssertEqual(g.rest, ["some-uuid"])
    }

    func testParseGlobalHelpShort() {
        let result = parseGlobal(["aislopdesk-ctl", "-h"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "help")
    }

    func testParseGlobalHelpLong() {
        let result = parseGlobal(["aislopdesk-ctl", "--help"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "help")
    }

    func testParseGlobalUnknownFlagBeforeSubcommand() {
        let result = parseGlobal(["aislopdesk-ctl", "--bogus"])
        guard case let .failure(err) = result else {
            XCTFail("expected failure on unknown flag")
            return
        }
        XCTAssertEqual(err, .unknownFlag("--bogus"))
    }

    func testParseGlobalSocketMissingValue() {
        let result = parseGlobal(["aislopdesk-ctl", "--socket"])
        guard case let .failure(err) = result else {
            XCTFail("expected failure on missing value")
            return
        }
        XCTAssertEqual(err, .missingValue("--socket"))
    }

    func testParseGlobalRestArgs() {
        // `run foo --cmd ls` → subcommand="run", rest=["foo", "--cmd", "ls"]
        let result = parseGlobal(["aislopdesk-ctl", "run", "foo-uuid", "--cmd", "ls"])
        guard case let .success(g) = result else {
            XCTFail("expected success")
            return
        }
        XCTAssertEqual(g.subcommand, "run")
        XCTAssertEqual(g.rest, ["foo-uuid", "--cmd", "ls"])
    }

    func testParseGlobalEmptyArgs() {
        let result = parseGlobal(["aislopdesk-ctl"])
        guard case let .success(g) = result else {
            XCTFail("expected success even with no subcommand")
            return
        }
        XCTAssertEqual(g.subcommand, "")
        XCTAssertTrue(g.rest.isEmpty)
    }

    // MARK: - encodeRequestLine

    func testEncodeRequestLineShape() throws {
        let line = try XCTUnwrap(encodeRequestLine(id: "42", method: "list-panes", params: [:]))
        // Must be valid JSON.
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "42")
        XCTAssertEqual(obj["method"] as? String, "list-panes")
        XCTAssertNotNil(obj["params"])
        // No trailing LF — the caller appends it.
        XCTAssertFalse(line.hasSuffix("\n"), "encodeRequestLine must NOT append a newline")
    }

    func testEncodeRequestLineWithParams() throws {
        let line = try XCTUnwrap(
            encodeRequestLine(id: "1", method: "read", params: ["paneId": "abc", "ansiStrip": true]),
        )
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(params["paneId"] as? String, "abc")
        XCTAssertEqual(params["ansiStrip"] as? Bool, true)
    }

    // MARK: - decodeResponseLine

    func testDecodeResponseSuccess() {
        let line = #"{"id":"1","ok":true,"result":{"text":"hello"}}"#
        let obj = decodeResponseLine(line)
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        let result = obj?["result"] as? [String: Any]
        XCTAssertEqual(result?["text"] as? String, "hello")
    }

    func testDecodeResponseError() {
        let line = #"{"id":"1","ok":false,"error":"pane not found"}"#
        let obj = decodeResponseLine(line)
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["error"] as? String, "pane not found")
    }

    func testDecodeResponseMalformed() {
        XCTAssertNil(decodeResponseLine("{not valid json"))
    }

    func testDecodeResponseEmpty() {
        XCTAssertNil(decodeResponseLine(""))
    }

    // MARK: - Verb param builders

    func testRunParamsEncoding() throws {
        // The key behaviour being tested: `run foo --cmd ls` must encode as
        // {"method":"run","params":{"paneId":"foo","text":"ls"}} so that
        // the server sends "ls\r" to the PTY master fd (the Enter is appended
        // server-side by the `run` verb handler).
        let params = runParams(paneId: "foo-uuid", cmd: "ls")
        XCTAssertEqual(params["paneId"] as? String, "foo-uuid")
        XCTAssertEqual(params["text"] as? String, "ls")
        // Validate that the full request line encodes correctly.
        let line = try XCTUnwrap(encodeRequestLine(id: "1", method: "run", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedParams = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "run")
        XCTAssertEqual(decodedParams["paneId"] as? String, "foo-uuid")
        XCTAssertEqual(decodedParams["text"] as? String, "ls")
    }

    func testWaitParamsDefaults() {
        let params = waitParams(paneId: "p1", until: "\\$")
        XCTAssertEqual(params["paneId"] as? String, "p1")
        XCTAssertEqual(params["until"] as? String, "\\$")
        XCTAssertEqual(params["timeoutMs"] as? Double, 30000)
    }

    func testWaitParamsCustomTimeout() {
        let params = waitParams(paneId: "p1", until: "DONE", timeoutMs: 5000)
        XCTAssertEqual(params["timeoutMs"] as? Double, 5000)
    }

    func testSpawnParamsNoCmd() {
        let params = spawnParams(cmd: nil, cwd: nil, env: [:], rows: 24, cols: 80)
        XCTAssertNil(params["cmd"], "no --cmd → no cmd param (server spawns login shell)")
        XCTAssertEqual(params["rows"] as? Int, 24)
        XCTAssertEqual(params["cols"] as? Int, 80)
    }

    func testSpawnParamsWithCmd() {
        let params = spawnParams(
            cmd: "ls -la",
            cwd: "/tmp",
            env: ["FOO": "bar"],
            rows: 30,
            cols: 120,
            shellPath: "/bin/zsh",
        )
        let cmd = params["cmd"] as? [String]
        XCTAssertEqual(cmd, ["/bin/zsh", "-c", "ls -la"])
        XCTAssertEqual(params["cwd"] as? String, "/tmp")
        let env = params["env"] as? [String: String]
        XCTAssertEqual(env?["FOO"], "bar")
        XCTAssertEqual(params["rows"] as? Int, 30)
        XCTAssertEqual(params["cols"] as? Int, 120)
    }

    func testReadParamsDefaultAnsiStrip() {
        let params = readParams(paneId: "x")
        XCTAssertEqual(params["ansiStrip"] as? Bool, true)
    }

    func testReadParamsKeepAnsi() {
        let params = readParams(paneId: "x", ansiStrip: false)
        XCTAssertEqual(params["ansiStrip"] as? Bool, false)
    }

    func testWriteParams() {
        let params = writeParams(paneId: "y", text: "hello\u{03}")
        XCTAssertEqual(params["paneId"] as? String, "y")
        XCTAssertEqual(params["text"] as? String, "hello\u{03}")
    }

    func testKillParams() {
        let params = killParams(paneId: "z")
        XCTAssertEqual(params["paneId"] as? String, "z")
    }

    // MARK: - Round-trip: encode then decode

    func testRoundTripRunRequest() throws {
        // Simulate what the CLI does for `aislopdesk-ctl run foo --cmd ls`:
        //   parseGlobal → subcommand="run", rest=["foo", "--cmd", "ls"]
        //   runParams(paneId:"foo", cmd:"ls")
        //   encodeRequestLine → JSON string
        //   (CLI sends over socket; server sends back response)
        //   decodeResponseLine → obj
        let args = ["aislopdesk-ctl", "run", "foo", "--cmd", "ls"]
        guard case let .success(global) = parseGlobal(args) else {
            XCTFail("parse failed")
            return
        }
        XCTAssertEqual(global.subcommand, "run")
        // Simulate the CLI's subcommand dispatch:
        // guard !rest.isEmpty → paneId = rest[0]
        // --cmd → cmd = rest[2] (rest = ["foo", "--cmd", "ls"])
        XCTAssertEqual(global.rest, ["foo", "--cmd", "ls"])
        let paneId = global.rest[0]
        XCTAssertEqual(paneId, "foo")
        // In the CLI: parse --cmd from rest[1..].
        var cmd: String?
        var idx = 1
        while idx < global.rest.count {
            if global.rest[idx] == "--cmd", idx + 1 < global.rest.count {
                idx += 1
                cmd = global.rest[idx]
            }
            idx += 1
        }
        XCTAssertEqual(cmd, "ls")
        // Build the params and encode the request.
        let params = try runParams(paneId: paneId, cmd: XCTUnwrap(cmd))
        let line = try XCTUnwrap(encodeRequestLine(id: "req-1", method: "run", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedParams = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "req-1")
        XCTAssertEqual(obj["method"] as? String, "run")
        XCTAssertEqual(decodedParams["paneId"] as? String, "foo")
        XCTAssertEqual(
            decodedParams["text"] as? String,
            "ls",
            "run verb sends the cmd string as 'text'; server appends \\r",
        )
    }

    func testRoundTripWaitRequest() throws {
        // `aislopdesk-ctl wait abc --until "\\$" --timeout-ms 5000`
        let args = ["aislopdesk-ctl", "wait", "abc", "--until", "\\$", "--timeout-ms", "5000"]
        guard case let .success(global) = parseGlobal(args) else {
            XCTFail("parse failed")
            return
        }
        XCTAssertEqual(global.subcommand, "wait")
        XCTAssertEqual(global.rest, ["abc", "--until", "\\$", "--timeout-ms", "5000"])
        // Parse rest as the CLI would.
        let paneId = global.rest[0]
        var until: String?
        var timeoutMs: Double = 30000
        var idx = 1
        while idx < global.rest.count {
            switch global.rest[idx] {
            case "--until" where idx + 1 < global.rest.count:
                idx += 1
                until = global.rest[idx]
            case "--timeout-ms" where idx + 1 < global.rest.count:
                idx += 1
                timeoutMs = Double(global.rest[idx]) ?? 30000
            default: break
            }
            idx += 1
        }
        XCTAssertEqual(until, "\\$")
        XCTAssertEqual(timeoutMs, 5000)
        let params = try waitParams(paneId: paneId, until: XCTUnwrap(until), timeoutMs: timeoutMs)
        let line = try XCTUnwrap(encodeRequestLine(id: "w1", method: "wait", params: params))
        let data = try XCTUnwrap(line.data(using: .utf8))
        let obj = try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dp = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(dp["paneId"] as? String, "abc")
        XCTAssertEqual(dp["until"] as? String, "\\$")
        XCTAssertEqual(dp["timeoutMs"] as? Double, 5000)
    }
}
