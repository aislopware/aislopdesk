import Foundation
import RworkProtocol

/// A full Rwork session transport: the **dual** data + control channels over two
/// TCP connections to one peer (`DECISIONS.md` dual-channel decision).
///
/// Splitting the channels means a burst of PTY `output` on the data channel cannot
/// delay a `resize`/`bye` on the control channel (the Zellij lesson). Both sockets
/// get `TCP_NODELAY` via ``TransportParameters/makeTCP()``.
///
/// This is a thin holder: it pairs two already-associated, ready ``MessageChannel``s.
/// The session handshake (hello/helloAck) and channel association live in
/// ``ClientTransport`` / ``HostTransport``, which produce instances of this type. The
/// higher layers (WF-3 host PTY relay, WF-4 client) read `output`/send `input` etc.
/// through these channels and never touch `NWConnection` directly.
///
/// `Sendable` via automatic conformance: both stored properties are immutable `let`s
/// of `Sendable` types (`any MessageChannel` is `Sendable`). No `@unchecked`.
public final class RworkConnection: Sendable {
    /// PTY byte stream: `output`/`exit`/`input`.
    public let data: any MessageChannel
    /// Session lifecycle & sizing: `hello`/`helloAck`/`resize`/`ack`/`bye`/`title`/`bell`.
    public let control: any MessageChannel

    /// Pairs two already-established, associated channels into one logical session.
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
}
