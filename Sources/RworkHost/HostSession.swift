import Foundation
import RworkProtocol
import RworkTransport

/// One live host session: a ``PTYProcess`` bridged to a client through a
/// ``HostSessionTransport`` (which owns the dual data/control channels + the
/// per-session `ReplayBuffer`), wired by the no-buffer relay.
///
/// ## Relay shape (`DECISIONS.md` / [17] / [12] Part B)
/// - **Output:** ``PTYReadLoop`` reads the master fd at `QOS_CLASS_USER_INTERACTIVE`
///   and hands each chunk straight to ``HostSessionTransport/sendOutput(_:)`` (which
///   assigns the seq via the `ReplayBuffer`, retains for replay, and writes `output`
///   on the data channel). No intermediate buffer.
/// - **Input:** ``HostSessionTransport/inboundInput`` → `write()` to the master fd.
/// - **Resize:** ``HostSessionTransport/inboundResize`` →
///   ``PTYProcess/setWindowSize(cols:rows:pxWidth:pxHeight:)`` (`TIOCSWINSZ` + `SIGWINCH`).
/// - **Backpressure:** ``HostSessionTransport/drainPauses`` → ``PTYReadLoop/setPaused(_:)``.
/// - **Exit:** the child's exit code is surfaced as `WireMessage.exit(code:)` on the
///   data channel.
///
/// ## Session survival across reconnect ([12] §6 / [18] §H)
/// The daemon keeps the `PTYProcess` (master fd + child shell) and the relay tasks
/// ALIVE when the client disconnects — it does **not** kill the shell on channel
/// failure. `HostTransport` rebinds the fresh channels onto the **same**
/// `HostSessionTransport` (and replays the un-acked tail via its `resume()`) on a
/// RETURNING_CLIENT reconnect, so the inbound streams and `drainPauses` this session
/// consumes are stable across the reconnect: nothing here needs to be re-wired. The
/// shell never learns the client left (the kernel backpressures it while offline).
///
/// `@unchecked Sendable`: the only mutable state (`relayTasks`, `started`) is touched
/// under `taskLock`; the PTY/transport/read-loop are themselves thread-safe.
public final class HostSession: @unchecked Sendable {
    /// Stable session identity (== the transport's `sessionID`).
    public let sessionID: UUID

    /// The child process + its PTY.
    public let pty: PTYProcess

    /// The transport for this session (replay buffer + dual channels), owned by
    /// `HostTransport` and rebound in place on reconnect.
    public let transport: HostSessionTransport

    private let taskLock = NSLock()
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var readLoop: PTYReadLoop?
    private var started = false

    /// Builds a session around an already-spawned PTY and an already-bound transport.
    public init(sessionID: UUID, pty: PTYProcess, transport: HostSessionTransport) {
        self.sessionID = sessionID
        self.pty = pty
        self.transport = transport
    }

    /// Starts the bidirectional relay. Call once, after ``PTYProcess/spawn(_:arguments:environment:argv0:cols:rows:)``
    /// and after the transport has been bound. Idempotent.
    public func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock(); return }
        started = true
        taskLock.unlock()

        let pty = self.pty
        let transport = self.transport
        let masterFD = pty.masterFD

        // OUTPUT: no-buffer read loop → sendOutput. The closure bridges from the
        // user-interactive read queue into the transport actor via an unstructured
        // Task; ordering is preserved because each chunk is enqueued in read order and
        // sendOutput assigns the seq on the actor in that same order.
        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { chunk in
                Task { try? await transport.sendOutput(chunk) }
            },
            onEOF: {
                // EOF on the master: child closed its tty. The reaper Task surfaces the
                // real exit code; nothing to do here (we don't synthesize an exit).
            }
        )
        self.readLoop = readLoop

        // BACKPRESSURE: drain-pause transitions gate the read loop. Start this BEFORE
        // the read loop so an early pause is honored.
        drainTask = Task {
            for await pause in transport.drainPauses {
                readLoop.setPaused(pause)
            }
        }

        readLoop.start()

        // INPUT: client input bytes → master fd. A blocking write on the (blocking)
        // master is fine: keystrokes/paste are tiny and the kernel tty buffer is large.
        inputTask = Task.detached {
            for await bytes in transport.inboundInput {
                Self.writeAll(fd: masterFD, data: bytes)
            }
        }

        // RESIZE: client resize → TIOCSWINSZ.
        resizeTask = Task {
            for await message in transport.inboundResize {
                if case let .resize(cols, rows, px, py) = message {
                    pty.setWindowSize(cols: cols, rows: rows, pxWidth: px, pxHeight: py)
                }
            }
        }

        // ACK: drained inside the transport's `acknowledge(upTo:)`; we consume the
        // surfaced stream so it does not back up (the release already happened).
        ackTask = Task {
            for await _ in transport.inboundAck { /* release handled in transport */ }
        }

        // EXIT: when the child exits, surface `exit(code:)` on the data channel so the
        // client's byte stream terminates cleanly. (If the client is offline this send
        // simply no-ops at the transport; the code is not replayed — control/lifecycle.)
        exitTask = Task {
            let code = await pty.waitForExit()
            try? await transport.sendExit(code: code)
        }
    }

    /// Tears down the relay and the PTY. The daemon calls this only when it actually
    /// wants the session gone (NOT on a client disconnect — see session survival).
    public func shutdown() {
        taskLock.lock()
        readLoop?.stop()
        inputTask?.cancel()
        resizeTask?.cancel()
        ackTask?.cancel()
        drainTask?.cancel()
        exitTask?.cancel()
        taskLock.unlock()
        pty.terminate()
    }

    // MARK: Helpers

    /// Writes all of `data` to `fd`, looping over partial writes / EINTR.
    private static func writeAll(fd: Int32, data: Data) {
        #if canImport(Darwin)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    return // fd closed / errored; drop (session likely tearing down).
                } else {
                    return
                }
            }
        }
        #endif
    }
}
