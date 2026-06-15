import CAislopdeskFFI

// Platform-free mux routing for the host video orchestrator. NO sockets, no SCStream, no
// clock — exactly the discipline of ``InputDatagramRouter`` / ``VideoSessionStateMachine`` in
// VideoSessionLogic.swift. The live UDP receive loop (``NWVideoMuxDatagramTransport``) feeds
// decoded `(channelID, VideoChannel, bytesCount)` through this under its mux lock.

/// PER-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// When several remote-window sessions share one host UDP socket, each datagram is
/// fronted by a `UInt32` channelID (see ``VideoMuxHeaderCodec``). This router decides
/// which session a freshly-arrived datagram belongs to — purely from the channelID it
/// is told plus the admitted/retired bookkeeping it holds. It owns NO sockets and NO
/// session objects: it returns a ``Decision`` and lets the IO layer act.
///
/// **Reconnect-generation safety.** A reconnecting client is admitted under a NEW
/// channelID (the prior one is `retire`d). In-flight datagrams that were already on
/// the wire for the OLD channelID must be DROPPED, not misrouted to the new session —
/// otherwise a stale frame/input from the previous generation would leak into the
/// fresh one. The router therefore keeps a retired set distinct from an "never seen"
/// channelID: a retired id is dropped with ``Decision/dropRetired`` (a known, benign
/// drop), while a genuinely unknown id is ``Decision/rejectUnadmitted``.
///
/// The routing ALGORITHM (the admitted/retired/draining bookkeeping + the wrap-aware retired-set
/// bound) lives in the Rust core (`aislopdesk_core::video_mux_router`, the SINGLE SOURCE OF TRUTH
/// shared with Android over the C ABI); this class is a thin owner of the opaque core handle,
/// reached via ``RustVideoHostFFI``. It is a `final class` (not the former value struct) so it can
/// own the handle and free it in `deinit`. `@unchecked Sendable` is sound because the single owner
/// (``NWVideoMuxDatagramTransport``) serializes every call under its mux `lock` (and the tests run
/// on one thread), so no two threads race the handle.
public final class VideoMuxRouter: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() {
        handle = RustVideoHostFFI.videoMuxRouterNew()
    }

    deinit {
        RustVideoHostFFI.videoMuxRouterFree(handle)
    }

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
        /// The `channelID` is mid-teardown (the reaper is stopping its session) — drop EVERY
        /// datagram (incl. a hello) until ``endDrain`` transitions it to `retired`.
        case dropDraining
        /// Drop for another reason (e.g. an empty/zero-byte datagram). `reason` is a
        /// short human-readable explanation (never a fatal condition).
        case drop(reason: String)
    }

    /// Admits `channelID` as a live lane. Idempotent. Admitting a previously-retired
    /// id clears its retired mark (a fresh generation may legitimately reuse an id). Delegates to
    /// the Rust core.
    public func admit(_ channelID: UInt32) {
        RustVideoHostFFI.videoMuxRouterAdmit(handle, channelID: channelID)
    }

    /// Retires `channelID` (reconnect/teardown): it stops being admitted and any
    /// further in-flight datagram for it is dropped via ``Decision/dropRetired``. Delegates to the
    /// Rust core (which also bounds the retired set wrap-aware).
    public func retire(_ channelID: UInt32) {
        RustVideoHostFFI.videoMuxRouterRetire(handle, channelID: channelID)
    }

    /// Begin tearing a lane down on the reaper path: stop routing it and HOLD it (draining) so a
    /// reconnect racing the async `session.stop()` drops cleanly rather than hitting the dying
    /// session's still-registered sink or re-minting early. Pair with ``endDrain`` once stopped.
    /// Delegates to the Rust core.
    public func beginDrain(_ channelID: UInt32) {
        RustVideoHostFFI.videoMuxRouterBeginDrain(handle, channelID: channelID)
    }

    /// Finish a reaper teardown: the session is stopped, so move the lane draining → retired (where a
    /// fresh `hello` may now re-admit it, FIX #2). Idempotent if the lane was not draining. Delegates
    /// to the Rust core.
    public func endDrain(_ channelID: UInt32) {
        RustVideoHostFFI.videoMuxRouterEndDrain(handle, channelID: channelID)
    }

    /// Whether `channelID` is currently an admitted (routable) lane.
    public func isAdmitted(_ channelID: UInt32) -> Bool {
        RustVideoHostFFI.videoMuxRouterIsAdmitted(handle, channelID: channelID)
    }

    /// Whether `channelID` is currently draining (reaper teardown in flight).
    public func isDraining(_ channelID: UInt32) -> Bool {
        RustVideoHostFFI.videoMuxRouterIsDraining(handle, channelID: channelID)
    }

    /// Decides what to do with one received datagram on `channel` carrying `channelID`. Delegates to
    /// the Rust core; the `.route` case carries back the same `channelID`, and the only `.drop` the
    /// core produces is the empty-datagram drop (its `reason` is descriptive — never inspected by the
    /// live path or the tests).
    ///
    /// - Parameters:
    ///   - channelID: the lane the datagram is fronted with (from ``VideoMuxHeaderCodec``).
    ///   - channel: the logical sub-stream the datagram arrived on (control / video /
    ///     geometry / cursor / input / recovery). Carried through for the IO layer;
    ///     the admit/retire decision is per-channelID, not per-channel.
    ///   - bytesCount: the datagram's byte length (an empty datagram is dropped).
    public func route(channelID: UInt32, channel: VideoChannel, bytesCount: Int) -> Decision {
        switch RustVideoHostFFI.videoMuxRouterRoute(
            handle, channelID: channelID, channel: channel.rawValue, bytesCount: bytesCount,
        ) {
        case UInt8(AISD_MUX_DECISION_ROUTE): .route(channelID: channelID)
        case UInt8(AISD_MUX_DECISION_DROP_RETIRED): .dropRetired
        case UInt8(AISD_MUX_DECISION_DROP_DRAINING): .dropDraining
        case UInt8(AISD_MUX_DECISION_DROP): .drop(reason: "empty datagram")
        default: .rejectUnadmitted
        }
    }

    /// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram (the lane is
    /// unadmitted OR retired), given the router's ``route`` decision, the channel it arrived on, and
    /// whether its payload decoded as a `hello`. PURE (the hello-peek itself is done once by the
    /// caller and passed in as `payloadIsHello`) so it is unit-testable without a socket — the
    /// "decider beside the actor" pattern.
    ///
    /// - FIX #2: a RETIRED channelID re-admits ONLY when its `.control` datagram is an actual hello
    ///   (cross-process channelID reuse after a client restart — the dead old process has no
    ///   in-flight old-gen datagrams left, so an explicit hello is a safe re-admission). A non-hello
    ///   for a retired id still drops (reconnect-generation safety: stale old-gen video/input must
    ///   never reach a survivor).
    /// - FIX #6: an UNADMITTED (`.rejectUnadmitted`) lane bootstraps (and the transport stamps its
    ///   reply flow) ONLY when its first `.control` datagram is a hello — a stray/adversarial
    ///   non-hello control datagram drops WITHOUT the transport remembering its flow (which would
    ///   otherwise leak `channelMediaConn` for never-helloed ids).
    public enum BootstrapAction: Equatable, Sendable {
        /// Remember the lane's reply flow and deliver the datagram to the registry (it mints/admits).
        case bootstrapDeliver
        /// Drop without touching any flow bookkeeping (stray/retired non-hello, or non-control).
        case dropNoStamp
    }

    /// Pure bootstrap decision, delegated to the Rust core (no handle needed).
    public static func bootstrapAction(
        for decision: Decision,
        channel: VideoChannel,
        payloadIsHello: Bool,
        payloadIsListRequest: Bool = false,
    ) -> BootstrapAction {
        let kind =
            switch decision {
            case .route: UInt8(AISD_MUX_DECISION_ROUTE)
            case .rejectUnadmitted: UInt8(AISD_MUX_DECISION_REJECT_UNADMITTED)
            case .dropRetired: UInt8(AISD_MUX_DECISION_DROP_RETIRED)
            case .dropDraining: UInt8(AISD_MUX_DECISION_DROP_DRAINING)
            case .drop: UInt8(AISD_MUX_DECISION_DROP)
            }
        switch RustVideoHostFFI.videoMuxRouterBootstrapAction(
            decision: kind, channel: channel.rawValue,
            payloadIsHello: payloadIsHello, payloadIsListRequest: payloadIsListRequest,
        ) {
        case UInt8(AISD_MUX_BOOTSTRAP_DELIVER): return .bootstrapDeliver
        default: return .dropNoStamp
        }
    }
}
