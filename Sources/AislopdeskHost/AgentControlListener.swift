import AislopdeskTransport
import Darwin
import Foundation

/// Agent-control socket server — the herdr/zellij-style control surface for AI agents.
///
/// Binds an `AF_UNIX` stream socket at `$TMPDIR/aislopdesk-ctl-<pid>.sock` (chmod 0600),
/// accepts connections, and speaks **NDJSON** over each: one UTF-8 JSON object per line,
/// request `{"id":"…","method":"…","params":{…}}` → response `{"id":"…","ok":true,"result":{…}}`
/// or `{"id":"…","ok":false,"error":"…"}`.
///
/// ## Hang-safety
/// The accept loop and per-connection read loop run on dedicated background threads (never
/// on the cooperative-concurrency pool), so a blocked `read(2)` or a slow shell write never
/// parks a Swift concurrency thread. The `wait` verb (the only blocking verb) parks its
/// connection thread on an `NSCondition` until the PTY fires a chunk matching the regex or
/// the timeout elapses.
///
/// ## Pure handler split (same pattern as ``AgentHookListener``)
/// - ``AgentControlHandler`` — the PURE verb dispatcher: given an `(id, method, params)` triple
///   and a reference to the ``HostServer``, it executes the verb and returns the JSON
///   response line. No socket I/O; fully unit-testable with a fake `HostServer`.
/// - ``AgentControlAcceptor`` — the THIN `AF_UNIX` shim: binds, accepts, reads NDJSON lines,
///   routes each to ``AgentControlHandler``, and writes the response. Never instantiated in a
///   test (hang-safety rule: no real socket in a unit test).
///
/// **Validate-then-drop**: any request line that is not valid UTF-8, not valid JSON, exceeds
/// 64 KiB, or has an unknown method receives an error response — the server never traps.
public final class AgentControlListener: @unchecked Sendable {
    private let acceptor: AgentControlAcceptor
    /// The socket path exported to PTY envs and logged at startup.
    public let socketPath: String

    public var onLog: (@Sendable (String) -> Void)?

    public init(socketPath: String, server: HostServer) {
        self.socketPath = socketPath
        acceptor = AgentControlAcceptor(server: server)
    }

    /// Binds the socket and begins accepting. Throws on bind/listen failure.
    public func start() throws {
        acceptor.onLog = onLog
        try acceptor.start(path: socketPath)
    }

    /// Closes the listener and unlinks the socket file. Idempotent.
    public func stop() {
        acceptor.stop()
    }
}

// MARK: - Pure handler

/// The PURE verb dispatcher for the agent-control protocol.
///
/// Given a parsed request triple `(id, method, params)` and the host server, executes the
/// requested verb and returns a complete NDJSON response line (UTF-8, newline-terminated).
///
/// **All methods are synchronous** except `wait`, which must be called on a background thread
/// (it blocks via `NSCondition`). The `wait` result is also returned as a NDJSON line.
///
/// Unit-tested with a fake host — no real socket, no real PTY.
public struct AgentControlHandler: Sendable {
    /// Max bytes accumulated in the `wait` regex buffer before the oldest half is trimmed.
    static let waitBufferCap = 4 * 1024 * 1024

    // MARK: Dispatch

    /// Dispatches one decoded request and returns a response line (UTF-8, newline-terminated).
    /// May block on the calling thread for the `wait` verb.
    public static func dispatch(
        id: String,
        method: String,
        params: [String: Any],
        server: HostServer,
    ) -> String {
        switch method {
        case "list-panes":
            listPanes(id: id, server: server)
        case "read":
            readPane(id: id, params: params, server: server)
        case "write":
            writePane(id: id, params: params, server: server)
        case "run":
            runPane(id: id, params: params, server: server)
        case "wait":
            waitPane(id: id, params: params, server: server)
        case "spawn":
            spawnPane(id: id, params: params, server: server)
        case "kill":
            killPane(id: id, params: params, server: server)
        case "resize":
            resizePane(id: id, params: params, server: server)
        default:
            errorResponse(id: id, message: "unknown method: \(method)")
        }
    }

    // MARK: Verb implementations

    /// `list-panes` → `{panes: [{paneId, title, pid, isAlive}]}`
    static func listPanes(id: String, server: HostServer) -> String {
        let panes = server.listPanesForControl()
        let items = panes.map { p -> [String: Any] in
            ["paneId": p.paneId, "title": p.title, "pid": Int(p.pid), "isAlive": p.isAlive]
        }
        return successResponse(id: id, result: ["panes": items])
    }

    /// `read` → `{text: "…"}` — scrollback snapshot for a pane (ANSI stripped by default).
    static func readPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true
        let text = session.scrollbackTextForControl(ansiStrip: ansiStrip)
        return successResponse(id: id, result: ["text": text])
    }

    /// `write` — injects raw text into the PTY (no Enter).
    static func writePane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let text = params["text"] as? String else {
            return errorResponse(id: id, message: "missing params.text")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let bytes = Data(text.utf8)
        session.writeRawForControl(bytes)
        return successResponse(id: id, result: [:])
    }

    /// `run` — injects `text + "\r"` atomically (Enter key).
    static func runPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let text = params["text"] as? String else {
            return errorResponse(id: id, message: "missing params.text")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        let bytes = Data((text + "\r").utf8)
        session.writeRawForControl(bytes)
        return successResponse(id: id, result: [:])
    }

    /// `wait` — blocks until pane output matches `until` regex or `timeoutMs` elapses.
    ///
    /// **Blocking** — must be called on a background thread (not the cooperative pool).
    /// Uses `NSCondition` to park; the output observer signals it from the PTY read-loop
    /// thread. The accumulated buffer is capped at ``waitBufferCap`` (oldest half trimmed).
    ///
    /// Response: `{matched: Bool, elapsed: <ms>}`.
    static func waitPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let untilPattern = params["until"] as? String else {
            return errorResponse(id: id, message: "missing params.until")
        }
        let timeoutMs = (params["timeoutMs"] as? Double) ?? 30000
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }

        // Compile the regex once (validate-then-drop: a bad pattern is an error, not a crash).
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: untilPattern)
        } catch {
            return errorResponse(id: id, message: "invalid regex: \(error.localizedDescription)")
        }

        // Box the mutable accumulator + matched flag in a class so the @Sendable observer
        // closure (which runs on the PTY read-loop thread) and the NSCondition wait (which
        // runs on the connection thread) can share state safely without capturing `var`s
        // across concurrency boundaries — required by Swift 6 strict sendability.
        final class WaitState: @unchecked Sendable {
            let condition = NSCondition()
            var matched = false
            var accumulator = Data()
        }
        let state = WaitState()

        let observerID = UUID()
        // Register the observer; it runs on the PTY read-loop thread.
        session.registerOutputObserver(id: observerID) { chunk in
            state.condition.lock()
            state.accumulator.append(chunk)
            // Trim the oldest half if the buffer exceeds the cap.
            if state.accumulator.count > waitBufferCap {
                state.accumulator = Data(state.accumulator.suffix(waitBufferCap / 2))
            }
            // ANSI-strip the accumulated text and test the regex.
            let bytes = state.accumulator
            let rawStr: String =
                if let utf8 = String(bytes: bytes, encoding: .utf8) {
                    utf8
                } else {
                    String(bytes.map { $0 < 0x80 ? $0 : UInt8(0x3F) }
                        .map { Character(UnicodeScalar($0)) })
                }
            let text = ANSIStripper.strip(rawStr)
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                state.matched = true
                state.condition.signal()
            }
            state.condition.unlock()
        }

        let startNanos = DispatchTime.now().uptimeNanoseconds
        state.condition.lock()
        let deadline = Date(timeIntervalSinceNow: timeoutMs / 1000.0)
        while !state.matched {
            // `wait(until:)` returns false on timeout.
            if !state.condition.wait(until: deadline) { break }
        }
        let didMatch = state.matched
        state.condition.unlock()

        session.removeOutputObserver(id: observerID)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000.0
        return successResponse(id: id, result: ["matched": didMatch, "elapsed": elapsedMs])
    }

    /// `spawn` — forks a new standalone pane. Returns `{paneId: "…"}`.
    static func spawnPane(id: String, params: [String: Any], server: HostServer) -> String {
        let cmd = params["cmd"] as? [String]
        let cwd = params["cwd"] as? String
        let env = params["env"] as? [String: String]
        let rows = UInt16((params["rows"] as? Int) ?? 24)
        let cols = UInt16((params["cols"] as? Int) ?? 80)

        let paneId: String
        do {
            paneId = try await_spawnStandalonePane(
                server: server, cmd: cmd, cwd: cwd, env: env, rows: rows, cols: cols,
            )
        } catch {
            return errorResponse(id: id, message: "spawn failed: \(error)")
        }
        return successResponse(id: id, result: ["paneId": paneId])
    }

    /// Bridges the `async` ``HostServer/spawnStandalonePane`` into the synchronous dispatch.
    /// Uses a `DispatchSemaphore` and an `@unchecked Sendable` box to pass the result across
    /// the Task→thread boundary without capturing `var`s (Swift 6 strict sendability).
    private static func await_spawnStandalonePane(
        server: HostServer,
        cmd: [String]?,
        cwd: String?,
        env: [String: String]?,
        rows: UInt16,
        cols: UInt16,
    ) throws -> String {
        final class SpawnResult: @unchecked Sendable {
            var value: Result<String, Error>?
        }
        let box = SpawnResult()
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let paneId = try await server.spawnStandalonePane(
                    cmd: cmd, cwd: cwd, env: env, rows: rows, cols: cols,
                )
                box.value = .success(paneId)
            } catch {
                box.value = .failure(error)
            }
            sema.signal()
        }
        sema.wait()
        guard let result = box.value else {
            throw ControlSpawnError.noResult
        }
        return try result.get()
    }

    private enum ControlSpawnError: Error { case noResult }

    /// `kill` — kills a pane by paneId. Returns `{}` on success.
    static func killPane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        let found = server.killPaneForControl(paneId: paneId)
        if found {
            return successResponse(id: id, result: [:])
        }
        return errorResponse(id: id, message: "pane not found: \(paneId)")
    }

    /// `resize` — sets the PTY window size via `TIOCSWINSZ`. Returns `{}` on success.
    ///
    /// Validates `rows` and `cols` are in `1…65535` (validate-then-drop on out-of-range).
    /// The kernel delivers `SIGWINCH` to the foreground process group automatically.
    static func resizePane(id: String, params: [String: Any], server: HostServer) -> String {
        guard let paneId = params["paneId"] as? String else {
            return errorResponse(id: id, message: "missing params.paneId")
        }
        guard let rowsRaw = params["rows"] as? Int, rowsRaw >= 1, rowsRaw <= 65535 else {
            return errorResponse(id: id, message: "rows must be 1..65535")
        }
        guard let colsRaw = params["cols"] as? Int, colsRaw >= 1, colsRaw <= 65535 else {
            return errorResponse(id: id, message: "cols must be 1..65535")
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            return errorResponse(id: id, message: "pane not found: \(paneId)")
        }
        session.resizeForControl(rows: UInt16(rowsRaw), cols: UInt16(colsRaw))
        return successResponse(id: id, result: [:])
    }

    // MARK: JSON helpers (pure, no Foundation JSONEncoder/Decoder — avoids cyclic-import risk)

    /// Encodes a success response as a NDJSON line.
    static func successResponse(id: String, result: [String: Any]) -> String {
        var obj: [String: Any] = ["id": id, "ok": true]
        if !result.isEmpty { obj["result"] = result }
        return encodeJSON(obj) + "\n"
    }

    /// Encodes an error response as a NDJSON line.
    static func errorResponse(id: String, message: String) -> String {
        let obj: [String: Any] = ["id": id, "ok": false, "error": message]
        return encodeJSON(obj) + "\n"
    }

    /// Minimal JSON encoder — handles the fixed types the verb results produce.
    /// `JSONSerialization` is the right choice here (Foundation is already imported everywhere;
    /// no `Codable` ceremony for a simple string→Any dict).
    static func encodeJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"ok":false,"error":"json encode failure"}"#
        }
        return String(bytes: data, encoding: .utf8) ?? #"{"ok":false,"error":"utf8 encode failure"}"#
    }

    /// Parses one NDJSON request line. Returns `nil` on validate-then-drop (malformed or
    /// oversized lines already filtered by the socket layer).
    public static func parseRequest(_ line: String)
        -> (id: String, method: String, params: [String: Any])?
    {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String
        else { return nil }
        let params = obj["params"] as? [String: Any] ?? [:]
        return (id, method, params)
    }
}

// MARK: - Thin socket shim

/// The THIN `AF_UNIX` stream socket shim for the agent-control protocol.
///
/// One accepted connection gets one background thread that reads NDJSON lines (bounded to
/// ``maxRequestBytes`` per line), dispatches each to ``AgentControlHandler``, and writes the
/// response. Connections are long-lived (agents pipeline requests).
///
/// **Compiled + code-reviewed only** — never bound in a unit test (hang-safety: no real socket
/// in tests; the pure ``AgentControlHandler`` is tested separately).
public final class AgentControlAcceptor: @unchecked Sendable {
    private let server: HostServer
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPath: String?

    public var onLog: (@Sendable (String) -> Void)?

    /// Max bytes per request line (validate-then-drop beyond this).
    static let maxRequestBytes = 64 * 1024

    public init(server: HostServer) {
        self.server = server
    }

    /// Binds the socket at `path`, chmods it 0600, and begins accepting.
    public func start(path: String) throws {
        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxPath else {
            throw AgentSocketError.pathTooLong(path)
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr,
                    maxPath,
                )
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw AgentSocketError.bindFailed(e)
        }

        // Restrict to the running user (agents on the same machine, same uid only).
        Darwin.chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw AgentSocketError.listenFailed(e)
        }

        lock.lock()
        listenFD = fd
        boundPath = path
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd) }
        onLog?("agent-control socket listening at \(path)")
    }

    /// Closes the listener and unlinks the socket file. Idempotent.
    public func stop() {
        lock.lock()
        let fd = listenFD
        let path = boundPath
        listenFD = -1
        boundPath = nil
        lock.unlock()
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    // MARK: Accept loop

    private func acceptLoop(fd listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { return } // listen fd closed by stop() → exit
            // Each connection gets its own background thread for the blocking read loop.
            let server = server
            let log = onLog
            Thread.detachNewThread {
                Self.serveConnection(fd: conn, server: server, log: log)
                close(conn)
            }
        }
    }

    // MARK: Per-connection NDJSON loop

    /// Reads NDJSON lines from `fd`, dispatches each to ``AgentControlHandler``, writes the
    /// response, and loops until EOF or an I/O error.
    private static func serveConnection(
        fd: Int32,
        server: HostServer,
        log: (@Sendable (String) -> Void)?,
    ) {
        var lineBuffer = Data()

        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // EOF or error — connection closed

            lineBuffer.append(contentsOf: chunk[0..<n])

            // Process all complete lines (delimited by '\n') in the buffer.
            while let nlIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[lineBuffer.startIndex..<nlIndex]
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: nlIndex)...])

                // Validate-then-drop: oversized or non-UTF-8 request lines.
                guard lineData.count <= maxRequestBytes else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "request too large")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }
                guard let line = String(bytes: lineData, encoding: .utf8) else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "invalid UTF-8")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                // Parse and dispatch (validate-then-drop bad JSON / missing fields).
                guard let (reqID, method, params) = AgentControlHandler.parseRequest(trimmed) else {
                    let resp = AgentControlHandler.errorResponse(id: "?", message: "malformed request")
                    writeAll(fd: fd, data: Data(resp.utf8))
                    continue
                }

                // `subscribe` hijacks the connection: it streams NDJSON event lines and never
                // returns to the request-dispatch loop. The server does NOT emit an initial
                // {id,ok,result} handshake line — it immediately begins streaming events.
                if method == "subscribe" {
                    serveSubscribe(fd: fd, id: reqID, params: params, server: server, log: log)
                    return // connection consumed; caller closes fd
                }

                // Dispatch (may block for `wait`).
                let response = AgentControlHandler.dispatch(
                    id: reqID, method: method, params: params, server: server,
                )
                writeAll(fd: fd, data: Data(response.utf8))
            }

            // Drop an oversized partial line (validate-then-drop).
            if lineBuffer.count > maxRequestBytes {
                log?("agent-control: oversized partial line (\(lineBuffer.count) bytes) — discarding")
                lineBuffer.removeAll(keepingCapacity: false)
            }
        }
    }

    // MARK: subscribe — streaming event pump

    /// Implements the `subscribe` verb: streams NDJSON event lines to `fd` until the pane exits
    /// or the client disconnects (EPIPE). No initial handshake line is sent — event streaming
    /// begins immediately. The connection fd is consumed (this method owns it until return).
    ///
    /// Event shapes (one UTF-8 NDJSON line per event, newline-terminated):
    /// - `{"event":"output","text":"<plain-text chunk>"}` — zero or more per PTY read chunk
    ///   (ANSI-stripped for clean agent consumption).
    /// - `{"event":"closed"}` — exactly one, after the PTY's read loop has fully drained to EOF
    ///   (guaranteed to arrive after all `output` events for the session).
    ///
    /// Cleanup: both the output observer and the close observer are removed on any disconnect
    /// or pane exit. The pump runs on the connection thread already detached by the acceptor —
    /// no new thread is needed.
    private static func serveSubscribe(
        fd: Int32,
        id: String,
        params: [String: Any],
        server: HostServer,
        log _: (@Sendable (String) -> Void)?,
    ) {
        guard let paneId = params["paneId"] as? String else {
            let resp = AgentControlHandler.errorResponse(id: id, message: "missing params.paneId")
            writeAll(fd: fd, data: Data(resp.utf8))
            return
        }
        guard let session = server.lookupPaneForControl(paneId: paneId) else {
            let resp = AgentControlHandler.errorResponse(id: id, message: "pane not found: \(paneId)")
            writeAll(fd: fd, data: Data(resp.utf8))
            return
        }

        // `ansiStrip` — default ON (strip ANSI for clean agent text). The client may pass
        // `ansiStrip: false` to receive raw PTY bytes (e.g. to parse colour codes itself).
        let ansiStrip = (params["ansiStrip"] as? Bool) ?? true

        // Box shared state under NSCondition so the output observer (PTY read-loop thread) and
        // close observer (exit task thread) can deliver events to the pump thread safely.
        // Swift 6 strict sendability: mutable state lives in an @unchecked Sendable class; the
        // NSCondition serialises all accesses — no captured `var`s across concurrency boundaries.
        final class SubscribeState: @unchecked Sendable {
            let condition = NSCondition()
            var lines: [Data] = [] // pending NDJSON event lines buffered by observers
            var closed = false // set by the close observer when the PTY exits
        }
        let state = SubscribeState()
        let observerID = UUID()

        // Output observer — runs on the PTY read-loop thread for every raw chunk.
        session.registerOutputObserver(id: observerID) { chunk in
            // Optionally strip ANSI for clean agent text (PUA glyphs and charset designators
            // removed). When ansiStrip is false the raw PTY bytes are passed through.
            let rawStr: String =
                if let utf8 = String(bytes: chunk, encoding: .utf8) {
                    utf8
                } else {
                    String(chunk.map { $0 < 0x80 ? $0 : UInt8(0x3F) }
                        .map { Character(UnicodeScalar($0)) })
                }
            let text = ansiStrip ? ANSIStripper.strip(rawStr) : rawStr
            guard !text.isEmpty else { return }
            let eventObj: [String: Any] = ["event": "output", "text": text]
            guard let eventData = try? JSONSerialization.data(withJSONObject: eventObj, options: [.sortedKeys]),
                  var lineData = Optional(eventData)
            else { return }
            lineData.append(0x0A)
            state.condition.lock()
            if !state.closed {
                state.lines.append(lineData)
                state.condition.signal()
            }
            state.condition.unlock()
        }

        // Close observer — runs from the exit task after awaitEOFOrTimeout (all output
        // observer calls for this pane have completed before this fires).
        session.registerCloseObserver(id: observerID) {
            state.condition.lock()
            state.closed = true
            state.condition.signal()
            state.condition.unlock()
        }

        // Pump loop: park on the condition, drain the pending batch, write to fd.
        // Detect client disconnect via write(2) failure (EPIPE / -1).
        var clientDisconnected = false
        while !clientDisconnected {
            state.condition.lock()
            while state.lines.isEmpty, !state.closed {
                state.condition.wait()
            }
            let batch = state.lines
            let isClosed = state.closed
            state.lines.removeAll(keepingCapacity: true)
            state.condition.unlock()

            for line in batch {
                var ok = true
                line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { ok = false
                        return
                    }
                    var offset = 0
                    let total = raw.count
                    while offset < total {
                        let n = write(fd, base + offset, total - offset)
                        if n > 0 { offset += n }
                        else if n < 0, errno == EINTR { continue }
                        else { ok = false
                            return
                        } // EPIPE or other error → client gone
                    }
                }
                if !ok {
                    clientDisconnected = true
                    break
                }
            }
            if isClosed { break } // pane exited; emit closed event below and return
        }

        // Deregister both observers before touching the fd again.
        session.removeOutputObserver(id: observerID)
        session.removeCloseObserver(id: observerID)

        // Emit {"event":"closed"} only on a clean pane-exit (not on client disconnect so we
        // do not write to a broken pipe). `state.closed` is set exclusively by the close
        // observer and is only true when the PTY exit task fired — not on write failure.
        if !clientDisconnected {
            let closedObj: [String: Any] = ["event": "closed"]
            if var closedData = try? JSONSerialization.data(withJSONObject: closedObj, options: [.sortedKeys]) {
                closedData.append(0x0A)
                writeAll(fd: fd, data: closedData)
            }
        }
    }

    // MARK: writeAll helper (handles EINTR + partial writes)

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 { offset += n }
                else if n < 0 { if errno == EINTR { continue }
                    return
                } else { return }
            }
        }
    }
}
