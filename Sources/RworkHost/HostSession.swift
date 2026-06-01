import Foundation
import RworkProtocol
import RworkTransport

/// One live host session: a ``PTYProcess`` bridged to a client over an
/// ``RworkConnection``, with a host-side ``ReplayBuffer`` for lossless reconnect.
///
/// ## Relay shape (`DECISIONS.md` / [17])
/// - PTY master read -> assign seq via ``ReplayBuffer`` -> `output(seq:bytes:)` on
///   the **data** channel. No intermediate ring buffer; the relay thread runs at
///   `QOS_CLASS_USER_INTERACTIVE`.
/// - Client `input` (data channel) -> write to PTY master.
/// - Client `resize` (control channel) -> ``PTYProcess/setWindowSize(cols:rows:pxWidth:pxHeight:)``.
/// - Client `ack` -> ``ReplayBuffer/acknowledge(upTo:)``.
///
/// - Note: Documented seam for WF-3. Bodies are stubs.
public final class HostSession: @unchecked Sendable {
    /// Stable session identity, echoed in `helloAck` and used to recognize a
    /// returning client.
    public let sessionID: UUID

    /// The child process + its PTY.
    public let pty: PTYProcess

    /// Retained output for reconnect replay.
    public private(set) var replay: ReplayBuffer

    public init(sessionID: UUID = UUID(), pty: PTYProcess = PTYProcess()) {
        self.sessionID = sessionID
        self.pty = pty
        self.replay = ReplayBuffer()
    }

    /// Binds this session to a client connection and starts the bidirectional relay.
    public func attach(to connection: RworkConnection) async throws {
        // TODO(WF-3): start PTY->data relay (USER_INTERACTIVE), consume
        //   connection.data.inbound for `input`, connection.control.inbound for
        //   `resize`/`ack`/`bye`.
        throw HostError.notImplemented("HostSession.attach — WF-3")
    }
}
