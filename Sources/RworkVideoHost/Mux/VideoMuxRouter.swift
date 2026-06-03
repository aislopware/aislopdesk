import Foundation
import RworkVideoProtocol

// Pure, platform-free mux routing for the host video orchestrator. NO sockets, no
// SCStream, no clock — exactly the discipline of ``InputDatagramRouter`` /
// ``VideoSessionStateMachine`` in VideoSessionLogic.swift, so this is headlessly
// unit-testable in isolation. A later (gated) stage will wire the live UDP receive
// loop to feed decoded `(channelID, VideoChannel, bytesCount)` through this; for now
// nothing constructs it, so a single-pane run is byte-identical to today.

/// PURE per-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// When several remote-window sessions share one host UDP socket, each datagram is
/// fronted by a `UInt32` channelID (see ``VideoMuxHeaderCodec``). This router decides
/// which session a freshly-arrived datagram belongs to — purely from the channelID it
/// is told plus the admitted/retired bookkeeping it holds. It owns NO sockets and NO
/// session objects: it returns a ``Decision`` and lets the (later-built) IO layer act.
///
/// **Reconnect-generation safety.** A reconnecting client is admitted under a NEW
/// channelID (the prior one is `retire`d). In-flight datagrams that were already on
/// the wire for the OLD channelID must be DROPPED, not misrouted to the new session —
/// otherwise a stale frame/input from the previous generation would leak into the
/// fresh one. The router therefore keeps a retired set distinct from an "never seen"
/// channelID: a retired id is dropped with ``Decision/dropRetired`` (a known, benign
/// drop), while a genuinely unknown id is ``Decision/rejectUnadmitted``.
public struct VideoMuxRouter: Sendable {
    /// Currently-admitted lanes (one per live session). Routable for data.
    private var admitted: Set<UInt32> = []
    /// Lanes retired by a reconnect/teardown. Their in-flight datagrams are dropped
    /// (reconnect-generation safety) rather than rejected or misrouted.
    private var retired: Set<UInt32> = []

    public init() {}

    /// The decision for one received muxed datagram. Mirrors
    /// `InputDatagramRouter.Decision`'s pure style (a closed enum the IO layer acts on,
    /// never a fatal condition for a single bad packet).
    public enum Decision: Equatable, Sendable {
        /// Route the datagram to the session bound to `channelID`.
        case route(channelID: UInt32)
        /// The `channelID` was never admitted (an unknown / stray lane) — reject it.
        case rejectUnadmitted
        /// The `channelID` was retired by a reconnect/teardown — drop the in-flight
        /// datagram so a previous generation's bytes never reach the new session.
        case dropRetired
        /// Drop for another reason (e.g. an empty/zero-byte datagram). `reason` is a
        /// short human-readable explanation (never a fatal condition).
        case drop(reason: String)
    }

    /// Admits `channelID` as a live lane. Idempotent. Admitting a previously-retired
    /// id clears its retired mark (a fresh generation may legitimately reuse an id).
    public mutating func admit(_ channelID: UInt32) {
        admitted.insert(channelID)
        retired.remove(channelID)
    }

    /// Retires `channelID` (reconnect/teardown): it stops being admitted and any
    /// further in-flight datagram for it is dropped via ``Decision/dropRetired``.
    public mutating func retire(_ channelID: UInt32) {
        admitted.remove(channelID)
        retired.insert(channelID)
    }

    /// Whether `channelID` is currently an admitted (routable) lane.
    public func isAdmitted(_ channelID: UInt32) -> Bool { admitted.contains(channelID) }

    /// Decides what to do with one received datagram on `channel` carrying `channelID`.
    ///
    /// - Parameters:
    ///   - channelID: the lane the datagram is fronted with (from ``VideoMuxHeaderCodec``).
    ///   - channel: the logical sub-stream the datagram arrived on (control / video /
    ///     geometry / cursor / input / recovery). Carried through for the IO layer;
    ///     the admit/retire decision is per-channelID, not per-channel.
    ///   - bytesCount: the datagram's byte length (an empty datagram is dropped).
    public func route(channelID: UInt32, channel: VideoChannel, bytesCount: Int) -> Decision {
        _ = channel
        guard bytesCount > 0 else { return .drop(reason: "empty datagram") }
        if admitted.contains(channelID) { return .route(channelID: channelID) }
        if retired.contains(channelID) { return .dropRetired }
        return .rejectUnadmitted
    }
}
