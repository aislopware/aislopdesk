// Component 4 (2026-06-11): adaptive pacer depth v2 — late-EVENT driven 1↔2 jitter-depth boost
// + always-on presentation-health telemetry.
//
// Why v2 exists (and why v1 — AISLOPDESK_ADAPTIVE_JITTER — backfired):
// v1 sizes the depth from RFC3550 inter-arrival jitter, which conflates benign sender-cadence
// variance (host idle-skip, VideoSendLane chunked pacing, frame-size-dependent encode time) with
// actual presentation risk — on a jittery-but-fine WAN it pins the depth at 2-4 (+17-50ms standing
// latency) with zero late presents ever observed. And under the display-native 120Hz tick the
// pacer's `underflowRun` oscillates 0↔1 BY DESIGN on a healthy 60fps stream, so v1's
// grow-on-transient-dip ratchets to maxDepth on a clean link. v2 inverts the model: pay latency
// only AFTER observed late presents (events), refund after a clean dwell — and never reuse
// `underflowRun` as a signal.
//
// v3 (2026-06-12, owd-late): v2's PROMOTION source — the content-present-gap classifier — was
// itself structurally wrong: it compares present gaps against the cadence hint, but natural
// sub-cadence content (VS Code idle repaint ~40fps under a 60fps hint) makes every re-show gap
// clear the late boundary. MEASURED live (FPT↔Viettel): late=1 in every 50ms report at ALL flow
// densities → depth pinned at 2 for 99.6% of the session, demote unreachable — arrival GAPS
// conflate "the network delivered late" with "the host didn't produce a frame". v3 splits the
// two jobs:
//  - PROMOTION/DEMOTION now run on NETWORK-late events (`noteNetworkLate`): per-frame one-way-
//    delay spikes past the path baseline (`OwdLateDetector`, fed by the session off the wire
//    send stamps). That is the signal a slack frame actually absorbs, it is measured at ARRIVAL
//    (depth-independent ⇒ no self-sustaining promotion at depth 2), and content cadence can't
//    fake it.
//  - The present-gap machinery below is KEPT as pure telemetry: `notePresent` still classifies
//    (GapClass diagnostics), `noteReshow` still counts khựng episodes (`presentGaps`, the
//    HW-validated 28ms-threshold probe lineage) — but no gap classification feeds the depth
//    action anymore.
//
// PURE + headlessly testable: no Apple imports, all time injected as client-monotonic seconds
// (pattern: LiveCongestionController / AdaptiveFECPolicy). The FramePacer owns one instance under
// its lock.

/// One windowed drain of the pacer's presentation-health counters, carried client→host on the
/// NetworkStats recovery message (Phase-0 telemetry: log-only host-side).
public struct PacerTelemetrySnapshot: Sendable, Equatable {
    /// Windowed: NETWORK-late events (v3 — owd spikes past baseline, ``PacerDepthPolicy/noteNetworkLate(_:)``;
    /// the depth-promotion input). Until 2026-06-12 this carried present-gap lates (v2).
    public var lateFrames: UInt32
    /// Windowed: late-gap EPISODES OPENED (counted at the first re-show past the late threshold).
    /// Deliberately a SUPERSET of ``lateFrames``: a gap that no frame ever resolves (motion stop)
    /// still counts here, so the difference ≈ motion-stop boundaries. Log readers beware.
    public var presentGaps: UInt32
    /// Gauge: the live presentation depth (0 = no pacer attached).
    public var depth: UInt32
    public init(lateFrames: UInt32, presentGaps: UInt32, depth: UInt32) {
        self.lateFrames = lateFrames
        self.presentGaps = presentGaps
        self.depth = depth
    }
}

/// Late/idle/dense gap classifier (telemetry) + promote/demote depth policy (driven by
/// NETWORK-late events — v3, see the file header).
///
/// Promote: ≥ `promoteLateCount` network-late EVENTS (``noteNetworkLate(_:)``) within
/// `promoteWindowSeconds` ⇒ depth 1 → `boostDepth` (2 — NEVER higher; v1's unbounded ratchet was
/// the latency failure).
/// Demote: `demoteCleanSeconds` with ≤ `demoteToleranceLates` network-late events (and ≥
/// `minHoldSeconds` since promotion) ⇒ back to 1. Counters always run (telemetry); only the
/// depth action is gated by `adaptEnabled`.
/// The depth/telemetry ALGORITHM (promote-on-network-late + demote-on-clean-dwell + gap
/// classification + the windowed counters) lives in the Rust core
/// (`aislopdesk_core::pacer_depth_policy`, the SINGLE SOURCE OF TRUTH shared with Android over the C
/// ABI); this class is a thin owner of the opaque core handle, reached via ``RustVideoClientFFI``.
/// It is a `final class` (not the former value struct) so it can own the handle and free it in
/// `deinit`. `@unchecked Sendable` is sound because the single owner (``FramePacer``) serializes
/// every call under its `lock` (and the tests run on one thread), so no two threads race the handle.
/// ``Config`` stays a pure Swift value type — env resolution (`AISLOPDESK_DEPTH_*`) stays Swift-side
/// and the resolved scalars cross to the core (as a flat struct) at init.
public final class PacerDepthPolicy: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// late iff gap > max(`absoluteLateFloorSeconds`, `lateGapFactor` × expectedInterval).
        /// 1.6 sits above 1-interval + 120Hz-tick quantization + present-on-arrival wobble
        /// (~1.3-1.5×) and below a fully missed content slot (2.0×).
        public var lateGapFactor: Double = 1.6
        /// The HW-validated KHỰNG threshold (FramePacer.dbgNoteHold) — also immunizes the depth-2
        /// tick-alternation case (8.3/25ms present gaps) against self-sustaining promotion.
        public var absoluteLateFloorSeconds: Double = 0.028
        /// A gap above this is IDLE (host idle-skip / motion stop), never late. Recovery stalls on
        /// the target path land ~20-150ms; misclassification fails safe (under-count ⇒ no promote).
        public var idleGapSeconds: Double = 0.25
        /// Late additionally requires gap ≥ this × the previous in-flow present gap (suppresses
        /// gradual cadence drift; one skipped 60fps slot is a 2.0× step and passes).
        public var gapGradientFactor: Double = 1.45
        /// Dense flow = ≥ this many arrivals within `denseWindowSeconds` before the gap opened
        /// (≈ sustained ≥23fps motion). Excludes typing/sparse content from ever counting late.
        public var denseMinArrivals: Int = 8
        public var denseWindowSeconds: Double = 0.35
        /// LATE SLACK (2026-06-11 telemetry round, fix 2a): extra margin ON TOP of the late
        /// boundary, as a fraction of the expected interval. MEASURED live (169s, FPT↔Viettel):
        /// a steady late=1 trickle at ALL flow densities (537 reports at dense 60fps) — routine
        /// vsync/arrival jitter landing a hair past the bare boundary — kept the depth pinned at 2
        /// for 99.6% of the session. 0.25 × interval (≈4.2ms @60fps) absorbs that jitter while a
        /// genuinely skipped slot (2.0× interval) still clears the boundary by a wide margin.
        /// `AISLOPDESK_DEPTH_LATE_SLACK_PCT` (0...100).
        public var lateSlackFraction: Double = 0.25
        /// Promote on this many late events within `promoteWindowSeconds`.
        public var promoteLateCount: Int = 2
        public var promoteWindowSeconds: Double = 1.0
        /// Demote after this long with at most `demoteToleranceLates` late events in the window…
        public var demoteCleanSeconds: Double = 2.5
        /// …but never sooner than this after a promotion (anti-flap).
        public var minHoldSeconds: Double = 1.0
        /// DEMOTE TOLERANCE (fix 2b): the dwell no longer demands a PERFECTLY clean window — up to
        /// this many late events inside the trailing `demoteCleanSeconds` still demote (a lone
        /// genuine late must not re-arm the whole dwell; the measured 1-late-per-second trickle is
        /// primarily killed by the slack above, this is the backstop). 0 = the old strict dwell.
        /// `AISLOPDESK_DEPTH_DEMOTE_TOLERANCE` (0...3 — the late ring holds 4).
        public var demoteToleranceLates: Int = 1
        /// PROMOTE WARMUP (fix 2c): promote decisions are IGNORED for this long after stream start
        /// (first arrival) — the LiveCongestionController `warmupTicks` cold-start pattern.
        /// MEASURED: the session's only promotion landed at hostTs=855ms, during connection
        /// bring-up, off cold-start transients — and then never demoted. Counters still run
        /// (telemetry unconditional); only the promote ACTION is gated.
        /// `AISLOPDESK_DEPTH_WARMUP_MS` (0...30000).
        public var promoteWarmupSeconds: Double = 2.0
        /// The boosted depth. 1↔2 only; NEVER higher (one frame of slack covers the dominant
        /// one-slot-late hitch; deeper is pure standing latency).
        public var boostDepth: Int = 2
        /// expected-interval = median of the last N in-flow inter-ARRIVAL gaps (median, not
        /// min/mean: at depth 2 presents/arrivals can alternate 8.3/25ms around tick quantization —
        /// the median stays ≈ the true content interval; min would collapse and over-detect).
        public var intervalRingSize: Int = 15
        public var minSamplesForEstimate: Int = 5
        public var defaultIntervalSeconds: Double = 1.0 / 60
        public var minIntervalSeconds: Double = 1.0 / 240
        public var maxIntervalSeconds: Double = 1.0 / 10
        public init() {}

        /// Env-tunable construction (`AISLOPDESK_DEPTH_*`), each clamped to a sane band; absent /
        /// unparseable values keep the default. Pure — unit-testable headlessly.
        public static func fromEnvironment(_ env: [String: String]) -> Self {
            var c = Self()
            if let v = env["AISLOPDESK_DEPTH_PROMOTE_LATES"].flatMap(Int.init) {
                // lateTimes ring holds 4 — a count above that could never be satisfied.
                c.promoteLateCount = min(4, max(1, v))
            }
            if let v = env["AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS"].flatMap(Double.init), v.isFinite {
                c.promoteWindowSeconds = min(10.0, max(0.1, v / 1000.0))
            }
            if let v = env["AISLOPDESK_DEPTH_DEMOTE_MS"].flatMap(Double.init), v.isFinite {
                c.demoteCleanSeconds = min(30.0, max(0.5, v / 1000.0))
            }
            if let v = env["AISLOPDESK_DEPTH_MINHOLD_MS"].flatMap(Double.init), v.isFinite {
                c.minHoldSeconds = min(10.0, max(0.0, v / 1000.0))
            }
            if let v = env["AISLOPDESK_DEPTH_LATE_FACTOR"].flatMap(Double.init), v.isFinite {
                c.lateGapFactor = min(4.0, max(1.1, v))
            }
            if let v = env["AISLOPDESK_DEPTH_IDLE_MS"].flatMap(Double.init), v.isFinite {
                // Raise if a host-side recovery cooldown pushes worst-case recovery past ~200ms.
                c.idleGapSeconds = min(2.0, max(0.1, v / 1000.0))
            }
            if let v = env["AISLOPDESK_DEPTH_LATE_SLACK_PCT"].flatMap(Double.init), v.isFinite {
                c.lateSlackFraction = min(100.0, max(0.0, v)) / 100.0
            }
            if let v = env["AISLOPDESK_DEPTH_DEMOTE_TOLERANCE"].flatMap(Int.init) {
                c.demoteToleranceLates = min(3, max(0, v)) // lateTimes ring holds 4
            }
            if let v = env["AISLOPDESK_DEPTH_WARMUP_MS"].flatMap(Double.init), v.isFinite {
                c.promoteWarmupSeconds = min(30.0, max(0.0, v / 1000.0))
            }
            return c
        }
    }

    /// Classification of one content-present gap (returned by ``notePresent(_:)`` for tests/diagnostics).
    public enum GapClass: Sendable, Equatable {
        case first
        case normal
        case late
        case idle
    }

    private let handle: OpaquePointer

    public init(config: Config = Config(), adaptEnabled: Bool) {
        handle = RustVideoClientFFI.pacerDepthPolicyNew(config: config, adaptEnabled: adaptEnabled)
    }

    deinit {
        RustVideoClientFFI.pacerDepthPolicyFree(handle)
    }

    /// The recommended presentation depth: 1 or `boostDepth`. Always 1 while `adaptEnabled` is
    /// false (counters still run — telemetry is unconditional). Read from the Rust core.
    public var depth: Int { RustVideoClientFFI.pacerDepthPolicyDepth(handle) }

    /// The expected content interval: the hint (if set), else the median of the in-flow
    /// inter-arrival ring (once warmed), else the default — clamped to a sane band. Delegates to the
    /// Rust core.
    public var expectedIntervalSeconds: Double {
        RustVideoClientFFI.pacerDepthPolicyExpectedIntervalSeconds(handle)
    }

    /// The late boundary: `max(absFloor, factor × expectedInterval) + slackFraction × expectedInterval`.
    /// The slack term (fix 2a) sits ON TOP of the base boundary so ±routine-jitter arrivals — gaps
    /// a few ms past the bare boundary at dense flow — stop classifying late (see
    /// ``Config/lateSlackFraction``). Delegates to the Rust core.
    public var lateThresholdSeconds: Double {
        RustVideoClientFFI.pacerDepthPolicyLateThresholdSeconds(handle)
    }

    /// Fold one decoded-frame SUBMIT (client-monotonic seconds). Also evaluates demote so a
    /// post-idle resume demotes BEFORE the pacer re-primes (avoids one extra held frame at resume).
    /// Delegates to the Rust core.
    public func noteArrival(_ now: Double) {
        RustVideoClientFFI.pacerDepthPolicyNoteArrival(handle, now: now)
    }

    /// Fold one CONTENT present and classify its gap. Late requires ALL of: gap past the late
    /// boundary, dense flow when the gap opened, and a sharp (≥ gradient-factor) step up from the
    /// previous in-flow gap. Delegates to the Rust core.
    @discardableResult
    public func notePresent(_ now: Double) -> GapClass {
        RustVideoClientFFI.pacerDepthPolicyNotePresent(handle, now: now)
    }

    /// Fold one NETWORK-late event (v3 — the session's `OwdLateDetector` flagged a one-way-delay
    /// spike past the path baseline): THE promotion input, and the demote dwell's content. Counted
    /// into the windowed `lateFrames` telemetry too (the wire's late= field now reports the
    /// promotion-relevant signal). Delegates to the Rust core.
    public func noteNetworkLate(_ now: Double) {
        RustVideoClientFFI.pacerDepthPolicyNoteNetworkLate(handle, now: now)
    }

    /// Fold one empty-queue re-show tick. Counts a late-gap EPISODE (once) the moment the open gap
    /// crosses the late boundary — so the hitch is counted AS IT HAPPENS even if no frame ever
    /// resolves it (motion stop). Promotion never uses this counter, so stop boundaries can't promote.
    /// Delegates to the Rust core.
    public func noteReshow(_ now: Double) {
        RustVideoClientFFI.pacerDepthPolicyNoteReshow(handle, now: now)
    }

    /// Read + reset the windowed counters (one drain per NetworkStats report). Delegates to the
    /// Rust core.
    public func drainCounters() -> (lateFrames: UInt32, presentGaps: UInt32) {
        RustVideoClientFFI.pacerDepthPolicyDrainCounters(handle)
    }

    /// FPS-governor seam: a host `streamCadence` message pins the expected interval (instant
    /// late-boundary rebase, no ~8-arrival estimator transient). `nil` / non-finite / non-positive
    /// returns to the estimator (the core applies the finiteness/positivity guard). Delegates to the
    /// Rust core.
    public func setIntervalHint(_ seconds: Double?) {
        RustVideoClientFFI.pacerDepthPolicySetIntervalHint(handle, seconds: seconds)
    }
}
