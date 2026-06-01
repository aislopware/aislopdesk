import Foundation
import RworkProtocol
import RworkTransport

/// Client-side session driver: connects to a host, performs the `hello`/`helloAck`
/// handshake, and routes inbound `output`/`exit`/`title`/`bell` to a sink while
/// encoding outbound `input`/`resize`/`ack`/`bye`.
///
/// On reconnect it sends `hello(lastReceivedSeq:)` so the host replays only the
/// missing tail (see ``ReconnectManager`` and ``ReplayBuffer``).
///
/// - Note: Documented seam for WF-4. Bodies are stubs; signatures are the intended API.
public final class ClientConnection: @unchecked Sendable {
    /// Authoritative session id, learned from `helloAck` (echoes ours, or a fresh
    /// one the host minted for a new session).
    public private(set) var sessionID: UUID?

    /// Highest contiguous output seq we have received — sent in `ack` and in
    /// `hello.lastReceivedSeq` on reconnect.
    public private(set) var lastReceivedSeq: Int64 = 0

    /// The live transport, once connected.
    public private(set) var connection: RworkConnection?

    public init() {}

    /// Connects to `host:port`, opening the DATA + CONTROL channels and completing
    /// the handshake. `resume` carries an existing session id (or
    /// ``WireMessage/newSessionID`` for a fresh session).
    public func connect(host: String, port: UInt16, resume sessionID: UUID = WireMessage.newSessionID) async throws {
        // TODO(WF-4): RworkConnection.connect(...); send hello(version, sessionID,
        //   lastReceivedSeq); await helloAck; store sessionID; start receive loops.
        throw ClientError.notImplemented("ClientConnection.connect — WF-4")
    }

    /// Encodes raw keystroke/paste bytes as `input` on the data channel.
    public func sendInput(_ bytes: Data) async throws {
        // TODO(WF-4): connection.data.send(.input(bytes))
        throw ClientError.notImplemented("ClientConnection.sendInput — WF-4")
    }

    /// Sends a `resize` on the control channel.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        // TODO(WF-4): connection.control.send(.resize(...))
        throw ClientError.notImplemented("ClientConnection.sendResize — WF-4")
    }

    /// Records the highest contiguous output seq received (called by the receive
    /// loop) so it can be acked and used for reconnect replay.
    public func noteReceivedOutput(seq: Int64) {
        // Contiguous-advance only; gaps wait for the missing seq.
        if seq == lastReceivedSeq + 1 {
            lastReceivedSeq = seq
        }
        // TODO(WF-4): handle out-of-order / gap accounting if it can occur.
    }
}

/// Client-side errors.
public enum ClientError: Error, Equatable, Sendable {
    /// A seam that WF-4 has not implemented yet.
    case notImplemented(String)
    /// The host's `helloAck` did not match what we expected (e.g. version mismatch).
    case handshakeRejected(String)
}
