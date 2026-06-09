import Foundation

/// PURE AIMD congestion controller for the live HEVC stream (WF-2 adaptive bitrate, 2026-06-09).
///
/// WHY: WF-1 landed the network-feedback channel — the host folds the client's periodic
/// ``NetworkStatsReport`` into a clock-skew-free ``NetworkEstimate`` (RTT / loss / OWD-gradient). That
/// estimate was MAINTAIN+LOG only. This controller is the consumer: given the latest estimate it
/// decides a new live target bitrate, which the host actuates via ``VideoEncoder/setLiveBitrate(_:)``
/// (AverageBitRate + DataRateLimits together). The encoder never exceeds the ``LiveBitratePolicy``
/// ceiling and never drops below a sane floor.
///
/// SHAPE: Additive-Increase / Multiplicative-Decrease (AIMD) — the standard anti-oscillation control
/// law. On congestion (loss over threshold, or RTT inflated above the path baseline WITH a rising OWD
/// gradient) the target DROPS multiplicatively (fast back-off); on a clean link past a hold-down
/// window it CLIMBS additively (slow probe toward the ceiling). Severe loss halves immediately.
///
/// PURE + DETERMINISTIC: no wall-clock, no I/O, no reference capture. "Time" is the count of folded
/// reports (`ticks`) — the client sends ~one report per 50ms, so `warmupTicks`/`holdTicks` are
/// report-counts, not seconds. The ceiling/floor are injected at construction (re-seeded per encoder
/// build so a resize re-anchors to the new resolution's ceiling). Mirrors ``LiveBitratePolicy`` /
/// ``NetworkEstimate`` / ``StaticIDRDecider``: the policy is unit-testable in isolation; the
/// HW-gated ``VideoEncoder`` it drives is never instantiated in a test.
///
/// STABILITY MITIGATIONS (baked in so AIMD cannot thrash on a transient spike):
///  - Loss decisions key on the RAW per-report sample (``NetworkEstimate/lastLossSample``), NOT the
///    EWMA-damped ``NetworkEstimate/lossRate`` — so a single transient spike costs exactly ONE
///    decrease, never a cascade of decreases on the EWMA's slowly-decaying tail (a clean report reads
///    raw loss 0 ⇒ no decrease). The EWMA `lossRate` is retained for logging/telemetry trend only.
///  - A controller-LOCAL warmup (`warmupTicks`, ~500ms) suppresses ALL action at cold start, so a
///    `loss == 0` open-loop start can never trigger a spurious drop.
///  - A `lossThreshold` gate (not "any loss") + a hold-down (`holdTicks`, ~1s) — RE-ARMED only when a
///    decrease actually lowers the rate (a no-op decrease at the floor does not extend it) — suppress
///    immediate re-increase thrash without inflating dead time at the floor.
///  - Recovery is deliberately slow (additive `ceiling / increaseDivisor` per tick).
///
/// SAFE WHEN TELEMETRY OFF: with `loss == 0` and no valid RTT (`minRTTMillis == .infinity`) the
/// congestion predicate is always false, so the controller can only additively increase — but it
/// starts AT the ceiling and is clamped there ⇒ a no-op. It NEVER decreases on absence-of-data; only
/// on positive evidence. Inert and byte-identical in every telemetry-off permutation.
///
/// All tunables are env-overridable (`RWORK_ABR_*`) for HW A/B without a rebuild.
public struct LiveCongestionController: Sendable, Equatable {
    // MARK: Tunables (env-overridable RWORK_ABR_*)

    /// Reports to fold before ANY action — the cold-start guard (~10 × 50ms ≈ 500ms). `RWORK_ABR_WARMUP`.
    public static let warmupTicks: Int = envInt("RWORK_ABR_WARMUP", 10, min: 0, max: 100_000)
    /// EWMA loss-rate above which the link is "congested" → multiplicative decrease. `RWORK_ABR_LOSS`.
    public static let lossThreshold: Double = envDouble("RWORK_ABR_LOSS", 0.02, min: 0, max: 1)
    /// EWMA loss-rate above which the link is "severely congested" → halve immediately. `RWORK_ABR_SEVERE`.
    public static let severeLossThreshold: Double = envDouble("RWORK_ABR_SEVERE", 0.10, min: 0, max: 1)
    /// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%). `RWORK_ABR_DEC`.
    public static let decreaseFactor: Double = envDouble("RWORK_ABR_DEC", 0.85, min: 0.05, max: 0.999)
    /// Multiplicative decrease factor on SEVERE loss (0.5 = halve). `RWORK_ABR_SEVERE_DEC`.
    public static let severeDecreaseFactor: Double = envDouble("RWORK_ABR_SEVERE_DEC", 0.5, min: 0.05, max: 0.999)
    /// Additive-increase step = `ceiling / increaseDivisor` per clean tick (32 ⇒ ~3% of ceiling). `RWORK_ABR_INC_DIV`.
    public static let increaseDivisor: Int = envInt("RWORK_ABR_INC_DIV", 32, min: 1, max: 100_000)
    /// Reports to suppress any increase after a decrease — the anti-thrash hold-down (~20 × 50ms ≈ 1s). `RWORK_ABR_HOLD`.
    public static let holdTicks: Int = envInt("RWORK_ABR_HOLD", 20, min: 0, max: 100_000)
    /// `smoothedRTT > minRTT × rttInflateFactor` (WITH a rising OWD gradient) signals queue build-up. `RWORK_ABR_RTT`.
    public static let rttInflateFactor: Double = envDouble("RWORK_ABR_RTT", 1.25, min: 1.0, max: 100)
    /// Floor as a fraction of the ceiling (also clamped to ``LiveBitratePolicy/minimumBitrate``). `RWORK_ABR_MINFRAC`.
    public static let minFrac: Double = envDouble("RWORK_ABR_MINFRAC", 0.25, min: 0.01, max: 1.0)
    /// Actuation churn gate (fraction of ceiling): the host skips a re-actuation smaller than this. `RWORK_ABR_MATERIAL`.
    public static let materialFraction: Double = envDouble("RWORK_ABR_MATERIAL", 0.05, min: 0.0, max: 1.0)
    /// Actuation churn gate (absolute bps floor): the host skips a re-actuation smaller than this. `RWORK_ABR_MATERIAL_FLOOR`.
    public static let materialFloorBps: Int = envInt("RWORK_ABR_MATERIAL_FLOOR", 500_000, min: 0, max: 1_000_000_000)

    // MARK: State (all value-type ⇒ auto Equatable / Sendable)

    /// The ``LiveBitratePolicy/targetBitrate(pixelWidth:pixelHeight:fps:floor:)`` result for THIS
    /// encoder build — the hard upper bound the controller can never exceed.
    public let ceiling: Int
    /// The lowest the controller may drive the live rate. Always ≥ ``LiveBitratePolicy/minimumBitrate``
    /// (≥ 1 Mbps) ⇒ NEVER 0, and ≤ `ceiling`.
    public let floor: Int
    /// Current target bitrate (bps). Seeded to `ceiling` (open-loop start = today's behaviour).
    public private(set) var current: Int
    /// Folded-report count — the controller's "clock" (see type doc).
    public private(set) var ticks = 0
    /// No increase is permitted until `ticks` reaches this (set on every decrease).
    public private(set) var holdUntilTick = 0

    /// Additive-increase step in bps (≥ 1 so a tiny ceiling still makes progress).
    private var increaseStep: Int { max(1, ceiling / Self.increaseDivisor) }

    // MARK: Init

    /// Primary initialiser. `floor` is clamped to `[minimumBitrate, ceiling]` so the controller can
    /// never drive the rate to 0 nor below a usable minimum. `current` starts AT `ceiling`.
    public init(ceiling: Int, floor: Int) {
        let c = max(1, ceiling)
        self.ceiling = c
        self.floor = max(LiveBitratePolicy.minimumBitrate, min(floor, c))
        self.current = c
    }

    /// Convenience: derive the floor from `ceiling × minFrac` (the production wiring), keeping the
    /// floor-derivation policy in one place.
    public init(ceiling: Int) {
        self.init(ceiling: ceiling, floor: Int(Double(max(1, ceiling)) * Self.minFrac))
    }

    // MARK: Control law

    /// Folds one network estimate and returns the (possibly unchanged) new target bitrate.
    ///
    /// Decision order: warmup → severe-loss halve → ordinary-congestion multiplicative decrease →
    /// (past hold-down) additive increase. The result is ALWAYS within `[floor, ceiling]`.
    @discardableResult
    public mutating func onReport(_ e: NetworkEstimate) -> Int {
        ticks += 1
        // Cold-start guard: fold (advance `ticks`) but take no action, so an open-loop start with
        // `loss == 0` cannot trigger a spurious drop and the estimate's own gradient can warm up.
        guard ticks >= Self.warmupTicks else { return current }

        // Positive-evidence congestion ONLY (never decrease on absence-of-data): loss over the gate,
        // OR a finite RTT baseline inflated past it WITH a rising OWD gradient (queue build-up).
        //
        // LOSS uses the RAW per-report sample (`lastLossSample`), NOT the EWMA-damped `lossRate`: the
        // EWMA's whole point is to lag, but here that lag is harmful — a single transient spike keeps
        // the damped value above the threshold for MANY subsequent reports, and since the decrease
        // branches fire on EVERY report over the threshold (the hold-down gates only the INCREASE),
        // one blip would cascade into a multi-step drop on otherwise perfectly-clean reports. Keying
        // on the raw sample means a clean report (raw loss 0) never decreases, so a spike costs exactly
        // ONE decrease + the hold-down — react-fast, recover-slow AIMD without the EWMA-tail cascade.
        let rttCongested = e.minRTTMillis.isFinite
            && e.smoothedRTTMillis > e.minRTTMillis * Self.rttInflateFactor
            && e.owdGradientRising

        if e.lastLossSample > Self.severeLossThreshold {
            // Severe loss: halve immediately.
            decrease(to: max(floor, Int(Double(current) * Self.severeDecreaseFactor)))
        } else if e.lastLossSample > Self.lossThreshold || rttCongested {
            // Ordinary congestion: multiplicative decrease.
            decrease(to: max(floor, Int(Double(current) * Self.decreaseFactor)))
        } else if ticks >= holdUntilTick {
            // Clean link past the hold-down: probe up additively toward the ceiling.
            current = min(ceiling, current + increaseStep)
        }
        return current
    }

    /// Applies a computed multiplicative-decrease target and arms the anti-thrash hold-down — but ONLY
    /// re-arms the hold-down when the target actually LOWERS `current`. At the floor the decrease is a
    /// no-op (`next == current`), so without this guard a sustained congestion signal pinned at the
    /// floor would keep extending the hold-down every report, pushing the additive-recovery start far
    /// past the actual congestion and inflating dead time at the floor.
    private mutating func decrease(to next: Int) {
        if next < current {
            current = next
            holdUntilTick = ticks + Self.holdTicks
        }
    }

    // MARK: Actuation churn gate (pure — used by the host, unit-tested here)

    /// Whether a target change is large enough to be worth a VTSessionSetProperty round-trip. The host
    /// throttles actuation to MATERIAL moves (≥ `materialFraction` of the ceiling OR ≥ `materialFloorBps`)
    /// so a single ~3%-of-ceiling additive tick does not actuate every 50ms; consecutive additive ticks
    /// accumulate against the last ACTUATED rate and cross the gate after a couple of reports.
    public static func isMaterialChange(previous: Int, target: Int, ceiling: Int) -> Bool {
        abs(target - previous) >= max(materialFloorBps, Int(Double(max(1, ceiling)) * materialFraction))
    }

    // MARK: Env parsing helpers

    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo, v <= hi else { return fallback }
        return v
    }

    private static func envDouble(_ key: String, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Double(s), v >= lo, v <= hi else { return fallback }
        return v
    }
}
