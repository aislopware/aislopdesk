import Foundation
import RworkProtocol

/// A bidirectional, framed transport for ``WireMessage`` over one TCP connection.
///
/// One channel maps to one ``Channel`` (data or control). The concrete
/// implementation (WF-2) wraps an `NWConnection` with `TCP_NODELAY` set immediately
/// after connect — Nagle can add up to ~200ms to single-keystroke writes, so it is
/// mandatory on every PATH 1 socket (`DECISIONS.md`).
///
/// Sending is an `async` call; receiving is an `AsyncThrowingStream` so the receive
/// loop can `for try await` decoded messages produced by a per-channel
/// ``FrameDecoder``.
public protocol MessageChannel: Sendable {
    /// Which logical channel this transport carries.
    var channel: Channel { get }

    /// Frames and writes one message. Throws if the connection has failed.
    func send(_ message: WireMessage) async throws

    /// A stream of fully decoded inbound messages for this channel. Bytes arrive
    /// in arbitrary chunks and are reassembled by a ``FrameDecoder`` before being
    /// yielded here. The stream finishes when the peer closes cleanly and errors
    /// on transport / decode failure.
    var inbound: AsyncThrowingStream<WireMessage, Error> { get }
}
