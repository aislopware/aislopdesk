import CAislopdeskFFI

/// DELIVERY-KEYED recovery-IDR admission policy (component 2, 2026-06-11) — replaces the
/// capturer's sent-keyed F1 cooldown (`AISLOPDESK_MIN_IDR_MS`, 500 ms) as the single authority on
/// whether a client recovery request may force a real IDR.
///
/// THE BUG THIS FIXES (the ranked-#1 hitch): the F1 gate keyed the cooldown on keyframe SEND
/// time. When BOTH kfDup copies of a recovery IDR were lost (burst), the client's 2·RTT
/// escalation re-requested every ~2·RTT — and EVERY request landing inside the 500 ms window was
/// suppressed (the host kept shipping P-frames the broken client could not use). Worst case
/// ~600 ms of freeze, C-dominated and RTT-independent. Delivery-keying removes the C term: a
/// request that carries `lastDecodedFrameID < newest sent keyframe` past the in-flight grace
/// PROVES that keyframe is a casualty ⇒ grant immediately (the casualty bypass).
///
/// Decision table (`r` = request's lastDecoded, `K` = newest sent keyframe):
///  - r ≥ K                       ⇒ the request itself proves K delivered + reports a genuinely
///                                  new post-K loss ⇒ grant (token-gated).
///  - r < K, age(K) <  grace      ⇒ request plausibly crossed K in flight ⇒ suppress; if K was
///                                  lost the client re-escalates 2·RTT later into the next row.
///  - r < K, age(K) ≥  grace      ⇒ K presumed a casualty ⇒ THE BYPASS: grant immediately.
///  - r < a keyframe the client decode-ACKED ⇒ stale request from before the client's own
///                                  re-anchor ⇒ suppress at zero cost regardless of age.
///  - token bucket (cap 2, refill 1/500 ms) caps everything that reaches "grant": sustained
///    rate identical to the old F1 (≤2/s), burst of 2 so the casualty-bypass second IDR is
///    never blocked.
///
/// PURE + WALL-CLOCK-ONLY: all time injected as `Double` seconds (the session's `systemUptime`
/// domain), zero frame counting — immune to FPS-governor cadence changes. Headlessly
/// unit-testable like ``LiveCongestionController``.
///
/// The admission ALGORITHM (the delivery-keyed decision table + token bucket) lives in the Rust
/// core (`aislopdesk_core::recovery_idr_policy`, the SINGLE SOURCE OF TRUTH shared with Android
/// over the C ABI); this class is a thin owner of the opaque core handle, reached via
/// ``RustVideoHostFFI``. It is a `final class` (not the former value struct) so it can own the
/// handle and free it in `deinit`. `@unchecked Sendable` is sound because the single owner
/// (``AislopdeskVideoHostSession``) only touches it on the session actor (and the tests /
/// loopback-validate from one thread), so no two threads race the handle. ``Config`` stays a pure
/// Swift value type — env resolution (`AISLOPDESK_IDR_*`) stays Swift-side and the resolved scalars
/// cross to the core at init.
public final class RecoveryIDRPolicy: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// In-flight grace = `graceFraction × smoothedRTT`, clamped to [floor, ceil]. A crossing
        /// request arrives ≤ RTT/2 + jitter after the keyframe send; 0.75×RTT adds ~50% jitter
        /// margin (the measured path jitters RTT 10-59 ms).
        public var graceFraction: Double = 0.75
        /// Covers the rtt-unknown bootstrap (smoothedRTT = 0 before the first netstats fold).
        public var graceFloorSeconds: Double = 0.040
        /// = kfDupMinInterval: beyond it the kfDup second copy has also long been sent, so
        /// further suppression only adds freeze.
        public var graceCeilSeconds: Double = 0.250
        /// Burst allowance: exactly one ordinary grant + one casualty-bypass grant back-to-back
        /// (recovery IDRs are compact + kfDup-doubled ⇒ 2 grants ≈ 4 wire copies in <500 ms —
        /// bounded; 3+ would re-open the F1 storm).
        public var bucketCapacity: Double = 2.0
        /// 1 token / 500 ms sustained — preserves the old F1 spacing ceiling exactly.
        public var refillTokensPerSecond: Double = 2.0
        /// A granted-but-unserviced latch suppresses duplicates until this expires. Sized above
        /// the worst legitimate latch-service path: a freshly-quiet window waits the
        /// StaticIDRDecider quietWindow (1.0 s) + timer tick (0.25 s) + margin. Prevents both
        /// premature double-grants and a permanent wedge if capture dies.
        public var grantPendingTimeout: Double = 1.5
        /// Keyframes are rare (recovery + static-crisp + first-frame; motion heartbeat default
        /// OFF) — 4 covers every keyframe plausibly in flight within one ack round-trip.
        public var keyframeRingCapacity: Int = 4
        public init() {}
    }

    public enum Verdict: Equatable, Sendable {
        case grant
        /// An IDR grant is already latched and unexpired — the duplicate-request absorber.
        case suppressGrantPending
        /// The request provably predates a keyframe the client DECODED (acked) — zero-cost
        /// suppression regardless of age.
        case suppressStale
        /// The newest sent keyframe plausibly is still in flight to the client.
        case suppressInFlight
        /// Token bucket empty — the storm cap.
        case suppressRateLimited
    }

    private let handle: OpaquePointer

    public init(config: Config = Config()) {
        handle = RustVideoHostFFI.recoveryIdrPolicyNew(
            graceFraction: config.graceFraction,
            graceFloorSeconds: config.graceFloorSeconds,
            graceCeilSeconds: config.graceCeilSeconds,
            bucketCapacity: config.bucketCapacity,
            refillTokensPerSecond: config.refillTokensPerSecond,
            grantPendingTimeout: config.grantPendingTimeout,
            keyframeRingCapacity: config.keyframeRingCapacity,
        )
    }

    deinit {
        RustVideoHostFFI.recoveryIdrPolicyFree(handle)
    }

    /// Read-only token level (observability/tests — proves suppress* verdicts spend nothing).
    public var availableTokens: Double { RustVideoHostFFI.recoveryIdrPolicyAvailableTokens(handle) }

    /// Called from `onEncodedFrame` for EVERY keyframe handed to the wire (recovery, first-frame,
    /// static-crisp, heartbeat) with `packetizer.peekNextFrameID` read BEFORE packetize. Delegates
    /// to the Rust core.
    public func noteKeyframeSent(frameID: UInt32, now: Double) {
        RustVideoHostFFI.recoveryIdrPolicyNoteKeyframeSent(handle, frameID: frameID, now: now)
    }

    /// Called from the `.ack` fold. Idempotent; only ids matching a ring entry count (an LTR-P
    /// ack must not masquerade as keyframe delivery). Wrap-aware keep-newest. Delegates to the
    /// Rust core.
    public func noteKeyframeDelivered(frameID: UInt32) {
        RustVideoHostFFI.recoveryIdrPolicyNoteKeyframeDelivered(handle, frameID: frameID)
    }

    /// THE admission decision for one IDR-issuing recovery request.
    /// `clientLastDecoded == nil` ⇔ wire sentinel "nothing decoded yet" (treated as maximally
    /// behind — the connect-time first-IDR-loss case rides the same bypass). Delegates to the
    /// Rust core.
    public func decide(now: Double, clientLastDecoded: UInt32?, smoothedRTTSeconds: Double) -> Verdict {
        switch RustVideoHostFFI.recoveryIdrPolicyDecide(
            handle, now: now, clientLastDecoded: clientLastDecoded, smoothedRTTSeconds: smoothedRTTSeconds,
        ) {
        case UInt8(AISD_RECOVERY_IDR_SUPPRESS_GRANT_PENDING): .suppressGrantPending
        case UInt8(AISD_RECOVERY_IDR_SUPPRESS_STALE): .suppressStale
        case UInt8(AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT): .suppressInFlight
        case UInt8(AISD_RECOVERY_IDR_SUPPRESS_RATE_LIMITED): .suppressRateLimited
        default: .grant
        }
    }

    /// In-flight grace window for the given smoothed RTT: clamp(graceFraction × rtt, floor, ceil).
    /// Delegates to the Rust core.
    public func grace(rtt: Double) -> Double {
        RustVideoHostFFI.recoveryIdrPolicyGrace(handle, rtt: rtt)
    }
}
