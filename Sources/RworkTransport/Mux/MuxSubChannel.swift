import Foundation
import RworkProtocol

/// One logical Rwork channel multiplexed over a shared physical mux connection.
///
/// A `MuxSubChannel` is the mux-layer analogue of ``NWMessageChannel``: it conforms to the
/// SAME ``MessageChannel`` protocol (so ``MuxClientTransport`` / a host relay can drive it
/// exactly like a real one-TCP-pair channel), but instead of owning an `NWConnection` it is
/// backed by:
/// - a `channelID` (its logical address on the shared connection), and
/// - a `muxSend` closure — given the channel's framed ``WireMessage`` bytes, the owner wraps
///   them in a `.channelData` mux envelope and writes them on the shared physical connection.
///
/// Its ``inbound`` is an `AsyncThrowingStream<WireMessage>` fed by a PER-CHANNEL
/// ``RworkProtocol/FrameDecoder``: the owning ``MuxNWConnection`` demuxes the shared byte
/// stream into per-channel `.channelData` payloads and calls ``deliver(payload:)``, which
/// reassembles whole inner ``WireMessage`` frames for THIS channel and yields them here. So
/// interleaved frames from many channels on one connection land on the correct per-channel
/// inbound stream — the headline mux property.
///
/// ### Framing (two nested length-prefixed layers)
/// The inner ``WireMessage`` is framed by `msg.encode()` exactly as on a real channel; that
/// opaque inner frame becomes the BODY of an OUTER ``MuxFrame/channelData`` envelope. The mux
/// layer never parses the inner bytes — see ``MuxEnvelopeCodec``. This nesting is what lets the
/// existing per-channel `FrameDecoder` work unchanged inside the mux.
///
/// All mutable state (the decoder, the inbound continuation) lives inside this `actor`.
public actor MuxSubChannel: MessageChannel {
    /// Which logical channel kind this carries (advisory — framing is identical, mirroring
    /// ``NWMessageChannel``). The mux carries data + control over the SAME physical pair.
    public nonisolated let channel: Channel

    /// This channel's logical id on the shared mux connection (odd = client-allocated).
    public nonisolated let channelID: UInt32

    /// Writes one channel's framed ``WireMessage`` bytes out on the shared connection (the owner
    /// wraps them in a `.channelData` envelope). `@Sendable` so it can be captured across actors.
    private let muxSend: @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void

    /// Per-channel streaming frame decoder. Lives inside the actor (not `Sendable`) — one per
    /// logical channel, exactly as ``NWMessageChannel`` owns one per physical connection.
    private var decoder = FrameDecoder()

    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inboundContinuation: AsyncThrowingStream<WireMessage, Error>.Continuation

    /// - Parameters:
    ///   - channelID: the logical channel id on the shared connection.
    ///   - channel: the advisory ``Channel`` kind (data/control).
    ///   - muxSend: writes this channel's framed bytes out, wrapped in a `.channelData` envelope.
    public init(
        channelID: UInt32,
        channel: Channel,
        muxSend: @escaping @Sendable (_ channelID: UInt32, _ innerFrame: Data) async throws -> Void
    ) {
        self.channelID = channelID
        self.channel = channel
        self.muxSend = muxSend
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> { inboundStream }

    /// Frames `message` (`msg.encode()`) and hands it to `muxSend` to write — wrapped by the owner
    /// in a `.channelData` envelope for this channel. Suspends until the write is accepted; throws
    /// on a write failure or a closed shared connection.
    public func send(_ message: WireMessage) async throws {
        try await muxSend(channelID, message.encode())
    }

    /// Feeds an inbound `.channelData` payload for THIS channel into its decoder and yields every
    /// complete inner ``WireMessage`` frame. Called by the owning ``MuxNWConnection`` after it
    /// demuxes the shared stream. A decode fault is fatal for this channel only (it finishes the
    /// inbound stream with the error) — other channels on the shared connection are untouched.
    func deliver(payload: Data) {
        decoder.append(payload)
        do {
            while let message = try decoder.nextMessage() {
                inboundContinuation.yield(message)
            }
        } catch {
            inboundContinuation.finish(throwing: error)
        }
    }

    /// Finishes the inbound stream cleanly (the channel closed / the shared connection FIN'd).
    func finish() {
        inboundContinuation.finish()
    }

    /// Finishes the inbound stream with `error` (the shared connection failed under this channel).
    func finish(throwing error: Error) {
        inboundContinuation.finish(throwing: error)
    }
}
