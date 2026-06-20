import AislopdeskCtlCore
import Darwin
import Foundation

// aislopdesk-ctl — the reference client for the agent-control Unix-domain socket.
//
// Usage (subcommands map to protocol verbs):
//   aislopdesk-ctl [--socket PATH] list-panes [--json]
//   aislopdesk-ctl [--socket PATH] read <paneId> [--ansi] [--lines N]
//   aislopdesk-ctl [--socket PATH] write <paneId> --text "..."
//   aislopdesk-ctl [--socket PATH] run <paneId> --cmd "..."
//   aislopdesk-ctl [--socket PATH] wait <paneId> --until "<regex>" [--timeout-ms N]
//   aislopdesk-ctl [--socket PATH] spawn [--cmd "..."] [--cwd "..."] [--env K=V] [--rows N] [--cols N]
//   aislopdesk-ctl [--socket PATH] kill <paneId>
//
// Socket path resolved from (in priority order):
//   1. --socket flag
//   2. AISLOPDESK_CONTROL_SOCKET env var (injected by the host into every spawned PTY)
//   3. Fatal error with a clear message.
//
// Exit codes: 0 on success, 1 on error, 1 on wait-timeout (with "timeout" to stderr).

// MARK: - Fatal helpers

let programName = CommandLine.arguments.first
    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "aislopdesk-ctl"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
    exit(1)
}

func stdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// MARK: - Usage

func printUsage() {
    stdout("""
    usage: \(programName) [--socket PATH] <subcommand> [args...]

    Subcommands:
      list-panes [--json]
          List all live panes.  --json emits the raw NDJSON response line.

      read <paneId> [--ansi] [--lines N]
          Dump the pane's scrollback.  --ansi keeps ANSI escape codes (default: stripped).
          --lines N limits output to the last N lines.

      write <paneId> --text "..."
          Send raw text bytes to the pane's PTY master fd (no Enter appended).

      run <paneId> --cmd "..."
          Send text + Enter to the pane (execute a shell command).

      wait <paneId> --until "<regex>" [--timeout-ms N]
          Block until pane output matches <regex> (ANSI-stripped).
          Prints "matched (Nms)" and exits 0 on match.
          Prints "timeout after Nms" to stderr and exits 1 on timeout.
          Default timeout: 30000ms.

      spawn [--cmd "..."] [--cwd "..."] [--env K=V] [--rows N] [--cols N]
          Spawn a new standalone PTY pane.  Prints the new paneId to stdout.
          --cmd is passed as $SHELL -c "<cmd>".  Without --cmd, spawns the login shell.

      kill <paneId>
          Kill a pane by its UUID id.

    Flags:
      --socket PATH   Override the control socket path.

    Socket resolution (in order):
      1. --socket flag
      2. AISLOPDESK_CONTROL_SOCKET environment variable
      3. Fatal error — no socket known.

    """)
}

// MARK: - Socket path resolution

func resolveSocketPath(_ explicit: String) -> String {
    if !explicit.isEmpty { return explicit }
    if let env = ProcessInfo.processInfo.environment["AISLOPDESK_CONTROL_SOCKET"], !env.isEmpty {
        return env
    }
    die(
        "no control socket path: set AISLOPDESK_CONTROL_SOCKET or pass --socket PATH\n"
            + "\(programName): hint: run from inside a pane spawned by aislopdesk-hostd "
            + "with AISLOPDESK_AGENT_CONTROL=1",
    )
}

// MARK: - Unix socket I/O

/// Opens an AF_UNIX connection to `socketPath`, sends `requestLine` + LF, reads one
/// response line, and returns it (trailing LF stripped).
/// Any I/O error calls `die()`.
func sendRequest(socketPath: String, requestLine: String) -> String {
    // Guard path length before syscall (same cap as the server).
    let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard socketPath.utf8.count <= maxPath else {
        die("socket path too long: \(socketPath)")
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket(2) failed: \(String(cString: strerror(errno)))") }
    defer { close(fd) }

    // Connect.
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            strncpy(
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                cstr,
                maxPath,
            )
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        die("connect '\(socketPath)': \(String(cString: strerror(errno)))")
    }

    // Send the request line (ensure trailing LF).
    var line = requestLine
    if !line.hasSuffix("\n") { line += "\n" }
    let sendData = Data(line.utf8)
    sendData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        let total = raw.count
        while offset < total {
            let n = write(fd, base + offset, total - offset)
            if n > 0 { offset += n }
            else if n < 0, errno == EINTR { continue }
            else { die("write to socket failed: \(String(cString: strerror(errno)))") }
        }
    }

    // Read one response line (NDJSON: terminated by LF).
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let maxBytes = 64 * 1024 * 64 // generous: scrollback can be large
    outer: while response.count < maxBytes {
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { break }
        for i in 0..<n {
            response.append(chunk[i])
            if chunk[i] == 0x0A { break outer }
        }
    }

    if response.last == 0x0A { response.removeLast() }
    guard let str = String(bytes: response, encoding: .utf8) else {
        die("response from host is not valid UTF-8")
    }
    return str
}

// MARK: - Dispatch helpers

func requireOK(_ obj: [String: Any], context: String = "") {
    if let ok = obj["ok"] as? Bool, ok { return }
    let errMsg = obj["error"] as? String ?? "(no error message)"
    die(context.isEmpty ? "server error: \(errMsg)" : "\(context): \(errMsg)")
}

func callVerb(socketPath: String, method: String, params: [String: Any]) -> [String: Any] {
    guard let line = encodeRequestLine(id: "1", method: method, params: params) else {
        die("failed to encode \(method) request as JSON")
    }
    let resp = sendRequest(socketPath: socketPath, requestLine: line)
    guard let obj = decodeResponseLine(resp) else {
        die("malformed response from host: \(resp)")
    }
    return obj
}

// MARK: - Subcommand implementations

func cmdListPanes(socketPath: String, rest: [String]) {
    let jsonMode = rest.contains("--json")
    let obj = callVerb(socketPath: socketPath, method: "list-panes", params: listPanesParams())
    requireOK(obj, context: "list-panes")

    if jsonMode {
        // Re-encode sorted so it is stable and greppable.
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(bytes: data, encoding: .utf8)
        else { die("failed to re-encode JSON response") }
        stdout(line + "\n")
        return
    }

    let result = obj["result"] as? [String: Any] ?? [:]
    let panes = result["panes"] as? [[String: Any]] ?? []
    if panes.isEmpty {
        stdout("(no live panes)\n")
        return
    }
    // NOTE: build rows with manual left-padding — NEVER `String(format: "%s", swiftString)`.
    // `%s` reads its argument as a C `char *`, so passing a Swift `String` segfaults the CLI.
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
    stdout("\(pad("PANE-ID", 36))  \(pad("PID", 6))  \(pad("STATUS", 6))  TITLE\n")
    for pane in panes {
        let paneId = pane["paneId"] as? String ?? "-"
        let pid = pane["pid"] as? Int ?? -1
        let title = pane["title"] as? String ?? ""
        let isAlive = (pane["isAlive"] as? Bool) ?? false
        let status = isAlive ? "alive" : "dead"
        stdout("\(pad(paneId, 36))  \(pad(String(pid), 6))  \(pad(status, 6))  \(title)\n")
    }
}

func cmdRead(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("read requires <paneId>") }
    let paneId = rest[0]
    var keepAnsi = false
    var limitLines: Int?
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--ansi":
            keepAnsi = true
        case "--lines":
            guard idx + 1 < rest.count else { die("--lines requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--lines requires a positive integer") }
            limitLines = n
        default:
            die("unknown flag for read: \(rest[idx])")
        }
        idx += 1
    }

    let obj = callVerb(socketPath: socketPath, method: "read", params: readParams(paneId: paneId, ansiStrip: !keepAnsi))
    requireOK(obj, context: "read")

    let result = obj["result"] as? [String: Any] ?? [:]
    var text = result["text"] as? String ?? ""

    if let limit = limitLines {
        let lines = text.components(separatedBy: "\n")
        text = lines.suffix(limit).joined(separator: "\n")
    }

    stdout(text)
    if !text.hasSuffix("\n") { stdout("\n") }
}

func cmdWrite(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("write requires <paneId>") }
    let paneId = rest[0]
    var text: String?
    var idx = 1
    while idx < rest.count {
        if rest[idx] == "--text", idx + 1 < rest.count {
            idx += 1
            text = rest[idx]
        } else {
            die("unknown flag for write: \(rest[idx])")
        }
        idx += 1
    }
    guard let textValue = text else { die("write requires --text \"...\"") }
    let obj = callVerb(socketPath: socketPath, method: "write", params: writeParams(paneId: paneId, text: textValue))
    requireOK(obj, context: "write")
}

func cmdRun(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("run requires <paneId>") }
    let paneId = rest[0]
    var cmd: String?
    var idx = 1
    while idx < rest.count {
        if rest[idx] == "--cmd", idx + 1 < rest.count {
            idx += 1
            cmd = rest[idx]
        } else {
            die("unknown flag for run: \(rest[idx])")
        }
        idx += 1
    }
    guard let cmdValue = cmd else { die("run requires --cmd \"...\"") }
    let obj = callVerb(socketPath: socketPath, method: "run", params: runParams(paneId: paneId, cmd: cmdValue))
    requireOK(obj, context: "run")
}

func cmdWait(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("wait requires <paneId>") }
    let paneId = rest[0]
    var until: String?
    var timeoutMs: Double = 30000
    var idx = 1
    while idx < rest.count {
        switch rest[idx] {
        case "--until":
            guard idx + 1 < rest.count else { die("--until requires a value") }
            idx += 1
            until = rest[idx]
        case "--timeout-ms":
            guard idx + 1 < rest.count else { die("--timeout-ms requires a value") }
            idx += 1
            guard let ms = Double(rest[idx]), ms > 0 else { die("--timeout-ms requires a positive number") }
            timeoutMs = ms
        default:
            die("unknown flag for wait: \(rest[idx])")
        }
        idx += 1
    }
    guard let pattern = until else { die("wait requires --until \"<regex>\"") }

    let obj = callVerb(
        socketPath: socketPath,
        method: "wait",
        params: waitParams(paneId: paneId, until: pattern, timeoutMs: timeoutMs),
    )
    requireOK(obj, context: "wait")

    let result = obj["result"] as? [String: Any] ?? [:]
    let matched = (result["matched"] as? Bool) ?? false
    let elapsed = result["elapsed"] as? Double ?? 0
    if matched {
        stdout(String(format: "matched (%.0fms)\n", elapsed))
        exit(0)
    } else {
        FileHandle.standardError.write(Data("\(programName): timeout after \(Int(elapsed))ms\n".utf8))
        exit(1)
    }
}

func cmdSpawn(socketPath: String, rest: [String]) {
    var cmd: String?
    var cwd: String?
    var extraEnv: [String: String] = [:]
    var rows = 24
    var cols = 80
    var idx = 0
    while idx < rest.count {
        switch rest[idx] {
        case "--cmd":
            guard idx + 1 < rest.count else { die("--cmd requires a value") }
            idx += 1
            cmd = rest[idx]
        case "--cwd":
            guard idx + 1 < rest.count else { die("--cwd requires a value") }
            idx += 1
            cwd = rest[idx]
        case "--env":
            guard idx + 1 < rest.count else { die("--env requires a K=V value") }
            idx += 1
            let pair = rest[idx]
            guard let eq = pair.firstIndex(of: "=") else { die("--env requires K=V format, got '\(pair)'") }
            let key = String(pair[pair.startIndex..<eq])
            let val = String(pair[pair.index(after: eq)...])
            extraEnv[key] = val
        case "--rows":
            guard idx + 1 < rest.count else { die("--rows requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--rows requires a positive integer") }
            rows = n
        case "--cols":
            guard idx + 1 < rest.count else { die("--cols requires a value") }
            idx += 1
            guard let n = Int(rest[idx]), n > 0 else { die("--cols requires a positive integer") }
            cols = n
        default:
            die("unknown flag for spawn: \(rest[idx])")
        }
        idx += 1
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let params = spawnParams(cmd: cmd, cwd: cwd, env: extraEnv, rows: rows, cols: cols, shellPath: shell)
    let obj = callVerb(socketPath: socketPath, method: "spawn", params: params)
    requireOK(obj, context: "spawn")

    let result = obj["result"] as? [String: Any] ?? [:]
    let paneId = result["paneId"] as? String ?? ""
    stdout(paneId + "\n")
}

func cmdKill(socketPath: String, rest: [String]) {
    guard !rest.isEmpty else { die("kill requires <paneId>") }
    let paneId = rest[0]
    let obj = callVerb(socketPath: socketPath, method: "kill", params: killParams(paneId: paneId))
    requireOK(obj, context: "kill")
    stdout("killed \(paneId)\n")
}

// MARK: - Entry point

let args = CommandLine.arguments

let parseResult = parseGlobal(args)
let global: GlobalArgs
switch parseResult {
case let .success(g): global = g
case let .failure(err):
    switch err {
    case let .unknownFlag(flag): die("unknown flag '\(flag)' (run with --help)")
    case let .missingValue(flag): die("'\(flag)' requires a value")
    }
}

if global.subcommand.isEmpty || global.subcommand == "help" {
    printUsage()
    exit(global.subcommand == "help" ? 0 : 2)
}

let socketPath = resolveSocketPath(global.socketPath)

switch global.subcommand {
case "list-panes":
    cmdListPanes(socketPath: socketPath, rest: global.rest)
case "read":
    cmdRead(socketPath: socketPath, rest: global.rest)
case "write":
    cmdWrite(socketPath: socketPath, rest: global.rest)
case "run":
    cmdRun(socketPath: socketPath, rest: global.rest)
case "wait":
    cmdWait(socketPath: socketPath, rest: global.rest)
case "spawn":
    cmdSpawn(socketPath: socketPath, rest: global.rest)
case "kill":
    cmdKill(socketPath: socketPath, rest: global.rest)
default:
    die("unknown subcommand '\(global.subcommand)' (run with --help)")
}
