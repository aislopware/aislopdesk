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
///  - The RTT path needs an ABSOLUTE slack (`rttSlackMillis`) on top of the multiplicative
///    `rttInflateFactor`: on a low-latency LAN (minRTT ≈ 5ms) the ×1.25 threshold is ~6ms — pure
///    scheduling noise (smoothedRTT wobbles 7–12ms) trips it permanently. Real queue build-up shows
///    up as tens of ms of ABSOLUTE inflation; +15ms slack makes sub-slack wobble invisible while a
///    long-baseline WAN path (minRTT 50ms+) is still governed by the multiplicative factor.
///  - The RTT signal must be SUSTAINED (`rttStreakTicks` consecutive inflated reports, ~150ms)
///    before it may decrease — a one-report blip never acts. The per-report `owdGradientRising`
///    flag is deliberately NOT consulted: it compares only two adjacent jitter samples, so on a
///    steady link it flaps ~50/50 (measured live 2026-06-10) — a coin flip, not a signal.
///  - RTT-triggered decreases are PROPORTIONAL to the measured queue (DELAY-TARGETING, 2026-06-11):
///    `factor = (minRTT + slack) / smoothedRTT` clamped to `[rttDecreaseFloorFactor,
///    rttDecreaseCapFactor]` — a large standing queue cuts hard in one step, the post-congestion EWMA
///    decay tail trims at most −5%, so the 2026-06-09 "×0.85 every 50ms to the floor" cascade is
///    structurally impossible and the RTT path may re-decrease on the SHORT `rttHoldTicks` spacing
///    (with a fresh streak each time) instead of the full increase hold-down. Loss-triggered
///    decreases stay IMMEDIATE and fixed-factor — raw-sample keyed, react-fast is correct there.
///  - A queue-corroborated decrease remembers the landed-on rate as the KNEE (ssthresh, `kneeBps`):
///    additive increase at/above it runs ÷`kneeCautionDivisor` so recovery hovers under the rate that
///    built the queue instead of re-bashing it every second (the felt 25↔40Mbps pumping). The knee
///    expires after `kneeTTLTicks` without re-confirmation — path conditions drift.
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
    /// LOSS-TOLERANCE #4 (2026-06-10): loss below ``catastrophicLossThreshold`` decreases ONLY when
    /// CORROBORATED by RTT inflation (both gates of the RTT predicate on the same report). Measured
    /// on the real inter-ISP path (iperf3, 1200B datagrams): loss is ~0.6–1.1% at 5, 12 AND 30Mbps —
    /// rate-INDEPENDENT weather, with multi-second 3–9% burst episodes at FLAT RTT (jitter 0.3ms).
    /// Backing the rate off cannot reduce that loss; it only degrades quality and (pre-#1) paced the
    /// recovery IDR at the collapsed rate. Loss WITH RTT inflation = a building queue = real
    /// congestion → the classic AIMD response stays. `RWORK_ABR_LOSS_NEEDS_RTT=0` reverts.
    public static let lossNeedsRTTCorroboration = ProcessInfo.processInfo.environment["RWORK_ABR_LOSS_NEEDS_RTT"] != "0"
    /// EWMA loss-rate above THIS halves even at flat RTT: a queue-less policer / true link collapse
    /// drops without inflating RTT, and at a SUSTAINED ≥25% the stream is unusable regardless of
    /// cause — backing off is the only safe move. Keyed on the EWMA ``NetworkEstimate/lossRate``
    /// (NOT the raw sample) deliberately: the ~50ms report window holds only ~3 frames, so ONE
    /// dropped frame reads as a 33% raw sample — weather, not collapse. The EWMA (alpha 0.125)
    /// needs ~6 consecutive ≥50%-loss reports (~300ms of true collapse) to cross 0.25, while a
    /// single spike moves it ≤12.5%. Gated on the hold-down so the decaying EWMA tail after the
    /// collapse ends cannot cascade halvings to the floor. `RWORK_ABR_CATASTROPHIC`.
    public static let catastrophicLossThreshold: Double = envDouble("RWORK_ABR_CATASTROPHIC", 0.25, min: 0, max: 1)
    /// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%). `RWORK_ABR_DEC`.
    public static let decreaseFactor: Double = envDouble("RWORK_ABR_DEC", 0.85, min: 0.05, max: 0.999)
    /// Multiplicative decrease factor on SEVERE loss (0.5 = halve). `RWORK_ABR_SEVERE_DEC`.
    public static let severeDecreaseFactor: Double = envDouble("RWORK_ABR_SEVERE_DEC", 0.5, min: 0.05, max: 0.999)
    /// Additive-increase step = `ceiling / increaseDivisor` per clean tick (32 ⇒ ~3% of ceiling). `RWORK_ABR_INC_DIV`.
    public static let increaseDivisor: Int = envInt("RWORK_ABR_INC_DIV", 32, min: 1, max: 100_000)
    /// Reports to suppress any increase after a decrease — the anti-thrash hold-down (~20 × 50ms ≈ 1s). `RWORK_ABR_HOLD`.
    public static let holdTicks: Int = envInt("RWORK_ABR_HOLD", 20, min: 0, max: 100_000)
    /// `smoothedRTT > minRTT × rttInflateFactor` (AND past the absolute slack) signals queue build-up. `RWORK_ABR_RTT`.
    public static let rttInflateFactor: Double = envDouble("RWORK_ABR_RTT", 1.25, min: 1.0, max: 100)
    /// ABSOLUTE smoothed-RTT inflation over the baseline (ms) ALSO required before the RTT path may
    /// signal congestion — keeps LAN scheduling wobble (a few ms on a ~5ms baseline) sub-threshold. `RWORK_ABR_SLACK`.
    public static let rttSlackMillis: Double = envDouble("RWORK_ABR_SLACK", 15.0, min: 0, max: 10_000)
    /// CONSECUTIVE inflated reports required before the RTT path decreases (~N × 50ms). `RWORK_ABR_RTT_N`.
    public static let rttStreakTicks: Int = envInt("RWORK_ABR_RTT_N", 3, min: 1, max: 100_000)
    /// Reports between RTT-path decreases (~8 × 50ms ≈ 400ms). DELAY-TARGETING (2026-06-11): the full
    /// `holdTicks` (~1s) between RTT decreases was the right anti-cascade guard for a FIXED ×0.85 step,
    /// but it also meant a REAL persistent queue (scroll demand > path capacity, measured live: RTT
    /// p90 80ms during scroll vs 11ms idle on the FPT↔Viettel path) drained at one small step per
    /// second — multi-second 50–100ms latency episodes. The decrease is now PROPORTIONAL to the
    /// measured queue (see ``onReport``), so the EWMA-tail cascade this hold guarded against is
    /// self-limiting (a draining queue yields factors → ``rttDecreaseCapFactor``); a shorter
    /// re-decrease spacing lets the controller actually chase a real queue. The streak also resets on
    /// every decrease, so each re-decrease needs a FRESH `rttStreakTicks` run of inflated reports.
    /// `RWORK_ABR_RTT_HOLD`.
    public static let rttHoldTicks: Int = envInt("RWORK_ABR_RTT_HOLD", 8, min: 0, max: 100_000)
    /// Hardest single proportional RTT decrease (0.6 = at most −40% in one step). `RWORK_ABR_RTT_DEC_MIN`.
    public static let rttDecreaseFloorFactor: Double = envDouble("RWORK_ABR_RTT_DEC_MIN", 0.6, min: 0.05, max: 0.999)
    /// Gentlest proportional RTT decrease — barely-over-threshold inflation still trims a little
    /// (0.95 = −5%), and the post-congestion EWMA decay tail can never re-cut deeply. `RWORK_ABR_RTT_DEC_MAX`.
    public static let rttDecreaseCapFactor: Double = envDouble("RWORK_ABR_RTT_DEC_MAX", 0.95, min: 0.05, max: 0.999)
    /// Additive-increase divisor applied ON TOP of ``increaseDivisor`` at/above the remembered knee
    /// (ssthresh): climbing back INTO the rate that just built a queue should be slow (probe), while
    /// recovery below it stays fast. 8 ⇒ ~0.4% of ceiling per tick above the knee. `RWORK_ABR_KNEE_DIV`.
    public static let kneeCautionDivisor: Int = envInt("RWORK_ABR_KNEE_DIV", 8, min: 1, max: 100_000)
    /// Reports the knee memory survives without a fresh queue-corroborated decrease (~1200 × 50ms ≈
    /// 60s). Path conditions drift; a stale knee must not cap the climb forever. `RWORK_ABR_KNEE_TTL`.
    public static let kneeTTLTicks: Int = envInt("RWORK_ABR_KNEE_TTL", 1200, min: 1, max: 1_000_000)
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
    /// Consecutive reports whose smoothed RTT cleared BOTH inflation gates (factor + slack). The RTT
    /// path may decrease only once this reaches ``rttStreakTicks`` — one noisy report never acts.
    /// Reset on EVERY decrease, so each re-decrease needs a fresh sustained run.
    public private(set) var rttInflatedStreak = 0
    /// No RTT-path decrease is permitted until `ticks` reaches this (set on every decrease) — the
    /// short re-decrease spacing (see ``rttHoldTicks``), distinct from the long increase hold-down.
    public private(set) var rttHoldUntilTick = 0
    /// The previous report's smoothed RTT — the one-report delay TREND. An RTT-path decrease
    /// additionally requires the smoothed RTT to be NOT IMPROVING (within 1ms) vs the last report:
    /// a queue that is already DRAINING (rate is under capacity, the level is just the backlog
    /// flushing out) must not keep triggering cuts — that was the measured undershoot-to-the-floor
    /// while a ~900ms warmup backlog drained. A standing or growing queue reads flat/rising and
    /// keeps cutting. (This is the sound version of the abandoned per-report `owdGradientRising`
    /// coin-flip: smoothed-EWMA vs smoothed-EWMA, not jitter-sample vs jitter-sample.)
    public private(set) var prevSmoothedRTTMillis = 0.0
    /// The remembered "knee" (ssthresh): the rate the controller landed on after the most recent
    /// queue-corroborated decrease. Additive increase at/above this rate uses the cautious step
    /// (÷``kneeCautionDivisor``) — the controller hovers under the rate that built a queue instead of
    /// re-bashing the ceiling every recovery (the measured 25↔40Mbps pumping). `nil` = no knee known.
    public private(set) var kneeBps: Int?
    /// Tick at which the knee memory expires (refreshed by every queue-corroborated decrease).
    public private(set) var kneeExpiresAtTick = 0
    /// ESCALATING CAUTION (2026-06-11, 4G probe-cycle damping): how many queue-corroborated decreases
    /// have CONFIRMED this knee while it was still alive. The first live 4G session showed the
    /// cautious-but-constant climb above the knee still re-bashed the ~4-5Mbps capacity every
    /// 30-60s — a felt RTT bump per cycle. Each re-confirmation ("we hit the wall at the same place
    /// again") DOUBLES the above-knee caution (÷8 → ÷16 → ÷32 → ÷64, capped), so on a
    /// stable-capacity path the oscillation amplitude decays toward a hover; a genuinely shifted
    /// path lets the knee expire (TTL) which resets confirmations and restores the base climb.
    public private(set) var kneeConfirmations = 0

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
        // Capture the trend input for the NEXT report whatever branch runs (including warmup).
        defer { prevSmoothedRTTMillis = e.smoothedRTTMillis }
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
        // RTT path (see STABILITY MITIGATIONS): BOTH inflation gates (multiplicative factor AND
        // absolute slack), SUSTAINED for `rttStreakTicks` consecutive reports, AND past the
        // hold-down (the EWMA-decay anti-cascade cooldown — max one RTT decrease per `holdTicks`).
        // `owdGradientRising` is deliberately ignored: adjacent-sample jitter comparison is a coin
        // flip on a steady link, not congestion evidence.
        let rttInflated = e.minRTTMillis.isFinite
            && e.smoothedRTTMillis > e.minRTTMillis * Self.rttInflateFactor
            && e.smoothedRTTMillis > e.minRTTMillis + Self.rttSlackMillis
        rttInflatedStreak = rttInflated ? rttInflatedStreak + 1 : 0
        let rttCongested = rttInflated
            && rttInflatedStreak >= Self.rttStreakTicks
            && ticks >= rttHoldUntilTick
            && e.smoothedRTTMillis + 1.0 >= prevSmoothedRTTMillis   // not improving — see prevSmoothedRTTMillis

        // Knee TTL: a knee that hasn't been re-confirmed by a queue-corroborated decrease within
        // `kneeTTLTicks` is stale path knowledge — forget it (and its confirmation count) so the
        // climb is uncapped again.
        if kneeBps != nil, ticks >= kneeExpiresAtTick { kneeBps = nil; kneeConfirmations = 0 }

        // LOSS-TOLERANCE #4: sub-catastrophic loss acts only when CORROBORATED by RTT inflation on
        // the same report (queue evidence). Weather loss — the measured rate-independent ~1%/3–9%
        // bursts at FLAT RTT — is handled by FEC/LTR/kfDup, not by giving up bitrate.
        let lossEvidence = !Self.lossNeedsRTTCorroboration || rttInflated
        if e.lossRate > Self.catastrophicLossThreshold,
           e.lastLossSample > Self.severeLossThreshold,
           ticks >= holdUntilTick {
            // SUSTAINED catastrophic loss (EWMA over the gate AND the CURRENT raw sample still
            // severe — the collapse is happening now, not the decaying tail of one that ended):
            // halve regardless of RTT (queue-less policer / true collapse), at most once per
            // hold-down window.
            decrease(to: max(floor, Int(Double(current) * Self.severeDecreaseFactor)), queueCorroborated: rttInflated)
        } else if e.lastLossSample > Self.severeLossThreshold, lossEvidence {
            // Severe CORROBORATED loss: halve immediately.
            decrease(to: max(floor, Int(Double(current) * Self.severeDecreaseFactor)), queueCorroborated: rttInflated)
        } else if rttCongested || (e.lastLossSample > Self.lossThreshold && lossEvidence) {
            // Ordinary congestion. DELAY-TARGETING (2026-06-11): the RTT path sizes the decrease to
            // the MEASURED queue instead of a fixed ×0.85 — `factor = (minRTT + slack) / smoothedRTT`,
            // clamped to [rttDecreaseFloorFactor, rttDecreaseCapFactor]. A 70ms standing queue over a
            // 10ms baseline cuts hard in ONE step (clamped −40%) instead of bleeding 50–100ms latency
            // through four ×0.85-per-second steps; barely-over-threshold inflation (and the EWMA
            // decay tail after the queue drains) trims at most −5% per step. The loss path keeps the
            // classic ×0.85. When both fire, take the stronger evidence (lower target).
            var target = Int.max
            if rttCongested {
                let drained = e.minRTTMillis + Self.rttSlackMillis
                let factor = min(Self.rttDecreaseCapFactor,
                                 max(Self.rttDecreaseFloorFactor, drained / e.smoothedRTTMillis))
                target = min(target, Int(Double(current) * factor))
            }
            if e.lastLossSample > Self.lossThreshold && lossEvidence {
                target = min(target, Int(Double(current) * Self.decreaseFactor))
            }
            decrease(to: max(floor, target), queueCorroborated: rttInflated)
        } else if ticks >= holdUntilTick && !rttInflated {
            // Clean link past the hold-down: probe up additively toward the ceiling. `!rttInflated`
            // keeps the probe from climbing INTO a building queue while the streak/hold-down is
            // still suppressing the decrease (minRTT re-baselines upward ~1%/fold, so a genuinely
            // shifted path baseline un-sticks this on its own). At/above the remembered knee the
            // step is divided by `kneeCautionDivisor`: the controller hovers under the rate that
            // built a queue instead of re-bashing it every recovery (25↔40Mbps pumping = the felt
            // sawtooth).
            let cautious = kneeBps.map { current >= $0 } ?? false
            let step = cautious ? max(1, increaseStep / cautionDivisor()) : increaseStep
            current = min(ceiling, current + step)
        }
        return current
    }

    /// Applies a computed decrease target and arms the anti-thrash hold-downs — but ONLY re-arms them
    /// when the target actually LOWERS `current`. At the floor the decrease is a no-op
    /// (`next == current`), so without this guard a sustained congestion signal pinned at the floor
    /// would keep extending the hold-down every report, pushing the additive-recovery start far past
    /// the actual congestion and inflating dead time at the floor.
    ///
    /// `queueCorroborated` (the report showed RTT inflation) additionally records the landed-on rate
    /// as the knee (ssthresh) — see ``kneeBps``. A catastrophic halve at FLAT RTT is rate-independent
    /// weather/policer evidence, not path-capacity knowledge, so it deliberately sets no knee.
    private mutating func decrease(to next: Int, queueCorroborated: Bool) {
        if next < current {
            let preCut = current
            current = next
            holdUntilTick = ticks + Self.holdTicks
            rttHoldUntilTick = ticks + Self.rttHoldTicks
            rttInflatedStreak = 0
            if queueCorroborated {
                // ESCALATING CAUTION — refined 2026-06-11 after the first deploy MISFIRED on 4G:
                // a confirmation must mean "we CLIMBED back up and hit the same wall again", so it
                // requires the pre-cut rate to have risen at least one full additive step ABOVE the
                // remembered knee. Without that gate, the connect-phase cut CASCADE (11.4M → 3M in
                // ~6 consecutive cuts of ONE congestion episode, no climbing in between — increases
                // are hold-down-blocked) racked conf to max in 4s and pinned the whole session at
                // the 3M floor (soft image) while RTT was identical to the un-escalated build.
                // A cascade cut below/at the knee now just deepens the knee, KEEPING the count.
                if let knee = kneeBps {
                    if preCut >= knee + increaseStep {
                        kneeConfirmations = min(kneeConfirmations + 1, 4)
                    }
                } else {
                    kneeConfirmations = 1
                }
                kneeBps = current
                kneeExpiresAtTick = ticks + Self.kneeTTLTicks
            }
        }
    }

    /// The effective above-knee additive-increase divisor: the base ``kneeCautionDivisor`` doubled
    /// per knee re-confirmation beyond the first (8 → 16 → 32 → 64, capped at 4 confirmations).
    private func cautionDivisor() -> Int {
        Self.kneeCautionDivisor << max(0, min(kneeConfirmations - 1, 3))
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
