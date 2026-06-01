import Foundation
import RworkProtocol

/// A full Rwork session transport: the **dual** data + control channels over two
/// TCP connections to one peer (`DECISIONS.md` dual-channel decision).
///
/// Splitting the channels means a burst of PTY `output` on the data channel cannot
/// delay a `resize`/`bye` on the control channel (the Zellij lesson). Both sockets
/// get `TCP_NODELAY`.
///
/// - Note: This is a documented seam. WF-2 implements the `NWConnection` wiring,
///   the receive loops, and reconnect. Bodies here are minimal stubs so the package
///   compiles; they intentionally do not pretend to work.
public final class RworkConnection: @unchecked Sendable {
    /// PTY byte stream: `output`/`exit`/`input`.
    public let data: any MessageChannel
    /// Session lifecycle & sizing: `hello`/`helloAck`/`resize`/`ack`/`bye`/`title`/`bell`.
    public let control: any MessageChannel

    /// Wraps two already-established channels. WF-2 will add the connecting /
    /// listening factory methods (`connect(host:port:)`, `accept(...)`) that set
    /// `TCP_NODELAY` and build the channels.
    public init(data: any MessageChannel, control: any MessageChannel) {
        self.data = data
        self.control = control
    }

    /// Returns the channel transport for a logical ``Channel``.
    public func channel(for channel: Channel) -> any MessageChannel {
        switch channel {
        case .data: return data
        case .control: return control
        }
    }

    // TODO(WF-2): static func connect(host:port:) async throws -> RworkConnection
    //   — opens DATA then CONTROL TCP connections, sets TCP_NODELAY on both,
    //     performs the hello/helloAck handshake, returns the live connection.
    // TODO(WF-2): close() — send `bye` on control, tear down both NWConnections.
    // TODO(WF-2): reconnect — build fresh NWConnections after `.failed`, re-hello
    //     with lastReceivedSeq so the host replays via ReplayBuffer.
}
