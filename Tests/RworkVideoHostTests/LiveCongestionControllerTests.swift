#if os(macOS)
import XCTest
@testable import RworkVideoHost

/// PURE AIMD congestion-control law for WF-2 adaptive bitrate. The ``VideoEncoder`` it drives is
/// HW-gated and never instantiated in a test, so this is the only headlessly-verifiable layer — it
/// covers the decision math (warmup gate, multiplicative decrease, severe-loss halving, hold-down,
/// additive recovery, [floor, ceiling] clamps, never-0, never-above-ceiling) plus the host's
/// actuation churn gate. All inputs are injected ``NetworkEstimate`` snapshots — fully deterministic.
///
/// These tests assume the production default tunables (no `RWORK_ABR_*` set in the test environment),
/// mirroring ``LiveBitratePolicyTests`` (which assumes `RWORK_BPP` unset). They reference the static
/// tunables symbolically so they stay correct even if a default is changed.
final class LiveCongestionControllerTests: XCTestCase {

    // A representative 2× HiDPI ceiling (≈45 Mbps) so the percentages are realistic.
    private let ceiling = 45_000_000

    /// Builds a `NetworkEstimate` with chosen loss / RTT congestion characteristics by folding
    /// crafted reports. Loss is EWMA-damped, so to reach a target loss we fold a steady stream.
    private func estimate(lossSamples: Double = 0, folds: Int = 0,
                          rttCongested: Bool = false) -> NetworkEstimate {
        var est = NetworkEstimate()
        // Seed a clean baseline RTT (minRTT = 50) so the RTT-congestion predicate has a baseline.
        for _ in 0..<max(1, folds) {
            if rttCongested {
                // Drive smoothedRTT well above minRTT*1.25 with a rising jitter gradient.
                est.fold(rttMillis: 50, framesReceived: 1000,
                         unrecovered: UInt32((lossSamples * 1000).rounded()), owdJitterMicros: 100)
                est.fold(rttMillis: 50, framesReceived: 1000,
                         unrecovered: UInt32((lossSamples * 1000).rounded()), owdJitterMicros: 200)
                est.fold(rttMillis: 500, framesReceived: 1000,
                         unrecovered: UInt32((lossSamples * 1000).rounded()), owdJitterMicros: 9000)
            } else {
                est.fold(rttMillis: 50, framesReceived: 1000,
                         unrecovered: UInt32((lossSamples * 1000).rounded()), owdJitterMicros: 100)
            }
        }
        return est
    }

    /// Drive the controller past warmup with neutral (no-action) reports so subsequent reports act.
    private func warmedController(ceiling: Int, floor: Int? = nil) -> LiveCongestionController {
        var ctrl = floor.map { LiveCongestionController(ceiling: ceiling, floor: $0) }
            ?? LiveCongestionController(ceiling: ceiling)
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<LiveCongestionController.warmupTicks { _ = ctrl.onReport(clean) }
        return ctrl
    }

    // MARK: Construction / clamps

    func testStartsAtCeiling() {
        let ctrl = LiveCongestionController(ceiling: ceiling)
        XCTAssertEqual(ctrl.current, ceiling, "open-loop start = pinned at the ceiling (today's behaviour)")
    }

    func testFloorDerivedFromCeilingAndNeverBelowMinimum() {
        // minFrac default 0.25 → floor = 25% of ceiling, but never below the 1 Mbps sanity minimum.
        let big = LiveCongestionController(ceiling: 40_000_000)
        XCTAssertEqual(big.floor, Int(40_000_000 * LiveCongestionController.minFrac))
        let tiny = LiveCongestionController(ceiling: 2_000_000) // 25% = 500k < 1 Mbps → clamps up.
        XCTAssertEqual(tiny.floor, LiveBitratePolicy.minimumBitrate)
        XCTAssertGreaterThan(tiny.floor, 0, "floor is NEVER 0")
    }

    func testExplicitFloorClampedIntoRange() {
        // A floor above the ceiling is clamped DOWN to the ceiling.
        let over = LiveCongestionController(ceiling: 10_000_000, floor: 99_000_000)
        XCTAssertEqual(over.floor, 10_000_000)
        // A floor below the minimum is clamped UP to the minimum (never 0).
        let under = LiveCongestionController(ceiling: 10_000_000, floor: 0)
        XCTAssertEqual(under.floor, LiveBitratePolicy.minimumBitrate)
    }

    // MARK: Warmup gating

    func testWarmupIsANoOp() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        let lossy = estimate(lossSamples: 0.5, folds: 4) // 50% loss — would normally halve.
        // The first (warmupTicks - 1) reports must NOT change anything.
        for _ in 0..<(LiveCongestionController.warmupTicks - 1) {
            XCTAssertEqual(ctrl.onReport(lossy), ceiling, "no action during warmup even under heavy loss")
        }
        XCTAssertEqual(ctrl.current, ceiling)
        // The first post-warmup report acts.
        let after = ctrl.onReport(lossy)
        XCTAssertLessThan(after, ceiling, "the first post-warmup report under loss decreases")
    }

    // MARK: Multiplicative decrease

    func testDecreaseOnLossAboveThreshold() {
        var ctrl = warmedController(ceiling: ceiling)
        // Loss steady at ~5% (> 2% threshold, < 10% severe) → ordinary multiplicative decrease.
        let lossy = estimate(lossSamples: 0.05, folds: 8)
        let before = ctrl.current
        let after = ctrl.onReport(lossy)
        XCTAssertEqual(after, max(ctrl.floor, Int(Double(before) * LiveCongestionController.decreaseFactor)),
                       "ordinary congestion → current *= decreaseFactor")
        XCTAssertLessThan(after, before)
    }

    func testSevereLossHalves() {
        var ctrl = warmedController(ceiling: ceiling)
        let severe = estimate(lossSamples: 0.5, folds: 12) // ~50% loss → severe.
        let before = ctrl.current
        let after = ctrl.onReport(severe)
        XCTAssertEqual(after, max(ctrl.floor, Int(Double(before) * LiveCongestionController.severeDecreaseFactor)),
                       "severe loss → current *= severeDecreaseFactor (halve)")
        // Severe drop is steeper than an ordinary drop from the same point.
        var ordinaryCtrl = warmedController(ceiling: ceiling)
        let ordinary = ordinaryCtrl.onReport(estimate(lossSamples: 0.05, folds: 8))
        XCTAssertLessThan(after, ordinary, "severe halving drops further than an ordinary decrease")
    }

    func testDecreaseOnRTTInflationWithRisingGradient() {
        var ctrl = warmedController(ceiling: ceiling)
        // No loss, but RTT inflated past minRTT*1.25 WITH a rising OWD gradient → congestion.
        let rtt = estimate(lossSamples: 0, folds: 4, rttCongested: true)
        XCTAssertTrue(rtt.smoothedRTTMillis > rtt.minRTTMillis * LiveCongestionController.rttInflateFactor)
        XCTAssertTrue(rtt.owdGradientRising)
        let before = ctrl.current
        let after = ctrl.onReport(rtt)
        XCTAssertLessThan(after, before, "RTT inflation + rising gradient is a congestion signal")
    }

    // MARK: Hold-down

    func testHoldDownSuppressesImmediateReIncrease() {
        var ctrl = warmedController(ceiling: ceiling)
        // One loss report drops the rate and arms the hold-down.
        let dropped = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8))
        XCTAssertLessThan(dropped, ceiling)
        // Clean reports DURING the hold-down window must NOT increase the rate.
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<(LiveCongestionController.holdTicks - 1) {
            XCTAssertEqual(ctrl.onReport(clean), dropped, "no increase while the hold-down is active")
        }
    }

    // MARK: Additive recovery

    func testProbeIncreaseOnCleanLinkPastHoldDown() {
        var ctrl = warmedController(ceiling: ceiling)
        let dropped = ctrl.onReport(estimate(lossSamples: 0.05, folds: 8))
        let clean = estimate(lossSamples: 0, folds: 1)
        // Burn through the hold-down window.
        for _ in 0..<LiveCongestionController.holdTicks { _ = ctrl.onReport(clean) }
        // Now clean reports probe UP additively.
        let probed = ctrl.onReport(clean)
        XCTAssertGreaterThan(probed, dropped, "past the hold-down, a clean link climbs additively")
        let step = max(1, ceiling / LiveCongestionController.increaseDivisor)
        XCTAssertLessThanOrEqual(probed - dropped, step * (LiveCongestionController.holdTicks + 1),
                                 "recovery is additive, not a jump back to the ceiling")
    }

    func testRecoveryNeverExceedsCeiling() {
        var ctrl = warmedController(ceiling: ceiling)
        // Drop once, then feed a long clean stream — the rate climbs but clamps AT the ceiling.
        _ = ctrl.onReport(estimate(lossSamples: 0.5, folds: 12))
        let clean = estimate(lossSamples: 0, folds: 1)
        for _ in 0..<10_000 { _ = ctrl.onReport(clean) }
        XCTAssertEqual(ctrl.current, ceiling, "additive recovery clamps at the ceiling, never above")
    }

    // MARK: Transient-spike resilience (WF-2 self-audit — raw-sample decrease, no EWMA cascade)

    /// Drives the controller exactly like the host: ONE persistent ``NetworkEstimate`` folded once per
    /// report (so the EWMA carries across reports), then `onReport`. Warms past warmup with clean folds.
    private func steppedClean(_ est: inout NetworkEstimate, _ ctrl: inout LiveCongestionController, count: Int) {
        for _ in 0..<count {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
    }

    /// REGRESSION (finding 2): a SINGLE transient loss spike followed by perfectly-clean reports must
    /// cause exactly ONE decrease — never a cascade. The controller keys on the RAW per-report loss, so
    /// the spike's slowly-decaying EWMA tail (which lingers above threshold for many reports) does NOT
    /// re-trip the decrease on subsequent clean reports.
    func testSingleTransientSpikeCausesExactlyOneDecrease() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        steppedClean(&est, &ctrl, count: LiveCongestionController.warmupTicks)
        XCTAssertEqual(ctrl.current, ceiling, "warmup leaves the rate at the ceiling")

        // ONE spike report: 100% loss.
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
        let afterSpike = ctrl.onReport(est)
        XCTAssertLessThan(afterSpike, ceiling, "the spike triggers exactly one decrease")
        // The CASCADE TRAP: the EWMA loss is STILL above the threshold right after the spike, so a
        // controller keyed on `lossRate` (not the raw sample) WOULD keep decreasing on clean reports.
        XCTAssertGreaterThan(est.lossRate, LiveCongestionController.lossThreshold,
                             "EWMA loss lingers above threshold after the spike (the trap the fix avoids)")

        // Now PERFECTLY clean reports. The rate must NEVER drop below the single post-spike level
        // (it holds during the hold-down, then climbs) — i.e. NO cascade.
        for _ in 0..<60 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
            XCTAssertGreaterThanOrEqual(ctrl.onReport(est), afterSpike,
                "a clean report after a spike must never decrease below the single post-spike level")
        }
        XCTAssertGreaterThan(ctrl.current, afterSpike, "after the hold-down the clean link recovers upward")
    }

    /// REGRESSION (finding 2, severe): one 100%-loss report then a clean link must not slam to the floor
    /// over the following clean reports — a single severe blip costs one halving, not a march to the floor.
    func testSevereSpikeThenCleanDoesNotMarchToFloor() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        var est = NetworkEstimate()
        steppedClean(&est, &ctrl, count: LiveCongestionController.warmupTicks)
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
        let afterSpike = ctrl.onReport(est)
        XCTAssertEqual(afterSpike, max(ctrl.floor, Int(Double(ceiling) * LiveCongestionController.severeDecreaseFactor)),
                       "severe spike = exactly one halving")
        steppedClean(&est, &ctrl, count: 5)
        XCTAssertGreaterThanOrEqual(ctrl.current, afterSpike, "clean reports never push it below the single halving")
    }

    /// REGRESSION (finding 3): a no-op decrease at the floor must NOT re-arm the hold-down. After the
    /// rate is pinned at the floor by sustained loss, the instant the link clears the controller climbs —
    /// it does not sit at the floor for an extra hold-down window re-armed by no-op decreases.
    func testNoOpDecreaseAtFloorDoesNotExtendHoldDown() {
        var ctrl = warmedController(ceiling: ceiling)
        var est = NetworkEstimate()
        // Sustained severe loss pins the rate at the floor within a few reports; keep going well past.
        for _ in 0..<200 {
            est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 1000, owdJitterMicros: 100)
            _ = ctrl.onReport(est)
        }
        XCTAssertEqual(ctrl.current, ctrl.floor, "sustained severe loss pins the rate at the floor")
        // The hold-down must point at/behind NOW — no-op decreases at the floor did not push it ahead.
        XCTAssertLessThanOrEqual(ctrl.holdUntilTick, ctrl.ticks,
            "no-op decreases at the floor do not extend the hold-down into the future")
        // So the very next clean report is already past the hold-down → recovery climbs immediately.
        est.fold(rttMillis: 50, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100)
        XCTAssertGreaterThan(ctrl.onReport(est), ctrl.floor,
            "recovery starts immediately once loss clears (hold-down was not extended at the floor)")
    }

    // MARK: Floor / never-0

    func testDecreaseNeverBelowFloor() {
        var ctrl = warmedController(ceiling: ceiling)
        let severe = estimate(lossSamples: 0.5, folds: 12)
        for _ in 0..<10_000 { _ = ctrl.onReport(severe) }
        XCTAssertEqual(ctrl.current, ctrl.floor, "sustained severe loss floors at `floor`, never below")
        XCTAssertGreaterThanOrEqual(ctrl.current, LiveBitratePolicy.minimumBitrate)
        XCTAssertGreaterThan(ctrl.current, 0, "the rate is NEVER 0")
    }

    // MARK: Inert when no valid evidence (telemetry-off permutation)

    func testInertWhenNoLossAndNoRTT() {
        var ctrl = LiveCongestionController(ceiling: ceiling)
        // Default estimate: loss 0, minRTT == .infinity (no valid RTT sample), no rising gradient.
        let blind = NetworkEstimate()
        for _ in 0..<1_000 { _ = ctrl.onReport(blind) }
        XCTAssertEqual(ctrl.current, ceiling, "no positive evidence → never decreases; pinned at ceiling")
    }

    func testNeverDecreasesOnAbsenceOfData() {
        // RTT rejected (nil) but loss folded as 0 — the loss-only telemetry permutation.
        var est = NetworkEstimate()
        for _ in 0..<20 { est.fold(rttMillis: nil, framesReceived: 1000, unrecovered: 0, owdJitterMicros: 100) }
        var ctrl = LiveCongestionController(ceiling: ceiling)
        for _ in 0..<1_000 { _ = ctrl.onReport(est) }
        XCTAssertEqual(ctrl.current, ceiling, "loss==0 + no RTT → no decrease ever")
    }

    // MARK: Actuation churn gate (the host's `material` throttle, pure + testable)

    func testChurnGateSuppressesTinyChanges() {
        // A sub-5%-of-ceiling, sub-500kbps move is NOT material.
        XCTAssertFalse(LiveCongestionController.isMaterialChange(previous: 45_000_000, target: 45_100_000, ceiling: ceiling))
        // A move ≥ 5% of ceiling IS material.
        XCTAssertTrue(LiveCongestionController.isMaterialChange(previous: 45_000_000, target: 42_000_000, ceiling: ceiling))
    }

    func testChurnGateAbsoluteFloorForSmallCeiling() {
        // With a small ceiling, 5% is tiny — the absolute 500kbps floor governs instead.
        let small = 4_000_000
        // 5% of 4M = 200k < 500k floor → a 300k move is NOT material (governed by the 500k floor).
        XCTAssertFalse(LiveCongestionController.isMaterialChange(previous: 4_000_000, target: 3_700_000, ceiling: small))
        // A 600k move clears the 500k floor → material.
        XCTAssertTrue(LiveCongestionController.isMaterialChange(previous: 4_000_000, target: 3_400_000, ceiling: small))
    }

    func testAdditiveTicksAccumulateToAMaterialActuation() {
        // The additive step (~3% of ceiling) is sub-material per tick, but a couple of ticks against
        // the LAST ACTUATED rate cross the 5% gate — the reason the host tracks lastActuatedBitrate.
        let step = ceiling / LiveCongestionController.increaseDivisor // ~3.125%
        XCTAssertFalse(LiveCongestionController.isMaterialChange(previous: ceiling - step, target: ceiling, ceiling: ceiling),
                       "one additive tick is below the churn gate")
        XCTAssertTrue(LiveCongestionController.isMaterialChange(previous: ceiling - 2 * step, target: ceiling, ceiling: ceiling),
                      "two accumulated additive ticks cross the churn gate")
    }
}
#endif
