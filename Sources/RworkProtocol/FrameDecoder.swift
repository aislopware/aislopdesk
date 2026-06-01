import Foundation

/// Incremental, streaming decoder that turns arbitrary chunks of TCP bytes into
/// whole ``WireMessage`` values.
///
/// TCP is a byte stream with no message boundaries: one `recv` may deliver half a
/// frame, three frames, or a frame split across many reads. `FrameDecoder` buffers
/// raw bytes via ``append(_:)`` and yields complete messages via ``nextMessage()``,
/// returning `nil` whenever no complete frame is buffered yet (it simply waits for
/// more bytes — a partial frame is **not** an error).
///
/// This is a value type. It is intentionally **not** `Sendable`: it carries mutable
/// buffer state and is meant to live inside a single actor / task (e.g. the
/// per-connection receive loop). One decoder per channel per connection.
public struct FrameDecoder {
    /// Length of the big-endian `UInt32` frame-length prefix.
    private static let prefixLength = 4

    /// Unconsumed received bytes. Completed frames are dropped from the front as
    /// they are parsed.
    private var buffer = Data()

    public init() {}

    /// Appends a freshly received chunk of bytes to the internal buffer.
    /// Safe to call with empty data, a single byte, or many frames' worth.
    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or `nil` if a full frame is not yet
    /// buffered (caller should `append` more bytes and retry).
    ///
    /// - Throws: ``RworkError/frameTooLarge(_:)`` if a length prefix exceeds
    ///   ``Rwork/maxFramePayloadLength``; or any error from
    ///   ``WireMessage/decode(payload:)`` (unknown type, malformed/truncated body).
    public mutating func nextMessage() throws -> WireMessage? {
        // Need at least the length prefix to know how big the frame is.
        guard buffer.count >= Self.prefixLength else { return nil }

        let payloadLength = Int(readPrefix())

        // Reject implausibly large frames before allocating / waiting for them.
        guard payloadLength <= Rwork.maxFramePayloadLength else {
            throw RworkError.frameTooLarge(payloadLength)
        }

        // Wait until the whole payload has arrived (partial read — not an error).
        let frameLength = Self.prefixLength + payloadLength
        guard buffer.count >= frameLength else { return nil }

        // Slice out the payload (after the prefix) and consume the frame bytes.
        let start = buffer.startIndex
        let payloadStart = start + Self.prefixLength
        let payload = Data(buffer[payloadStart ..< start + frameLength])
        buffer.removeSubrange(start ..< start + frameLength)

        return try WireMessage.decode(payload: payload)
    }

    /// Reads the 4-byte big-endian length prefix at the front of the buffer
    /// without consuming it. (Consumption happens in ``nextMessage()`` once the
    /// full frame is confirmed present, so an incomplete frame leaves the prefix
    /// in place for the next call.)
    private func readPrefix() -> UInt32 {
        let start = buffer.startIndex
        var value: UInt32 = 0
        for i in 0 ..< Self.prefixLength {
            value = (value << 8) | UInt32(buffer[start + i])
        }
        return value
    }
}
