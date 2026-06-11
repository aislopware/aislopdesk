import XCTest
@testable import AislopdeskVideoClient

/// Component 4 (adaptive pacer depth v2): PURE virtual-clock tests of ``PacerDepthPolicy`` — the
/// late/idle/dense gap classifier + the late-event promote / clean-dwell demote depth policy.
/// No Apple frameworks touched; all time is injected seconds.
final class PacerDepthPolicyTests: XCTestCase {

    /// Drive `n` clean in-flow slots at `fps`: arrival + present at the same instant
    /// (the depth-1 present-on-arrival model), with 120 Hz re-show ticks in between.
    private func driveClean(_ dp: inout PacerDepthPolicy, from t: Double, frames: Int, fps: Double = 60,
                            reshows: Bool = true) -> Double {
        var t = t
        var lastPresent = t
        for _ in 0..<frames {
            t += 1.0 / fps
            if reshows {
                var tick = lastPresent + 1.0 / 120.0
                while tick < t { dp.noteReshow(tick); tick += 1.0 / 120.0 }
            }
            dp.noteArrival(t)
            dp.notePresent(t)
            lastPresent = t
        }
        return t
    }

    /// One skipped 60fps content slot: a 33.3ms arrival+present gap (the dominant hitch shape).
    private func skipOneSlot(_ dp: inout PacerDepthPolicy, from t: Double) -> (t: Double, cls: PacerDepthPolicy.GapClass) {
        let t2 = t + 2.0 / 60.0
        dp.noteArrival(t2)
        return (t2, dp.notePresent(t2))
    }

    // MARK: Clean-link guarantees

    func testCleanSteady60fpsNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        _ = driveClean(&dp, from: 0, frames: 600)   // 10s
        let win = dp.drainCounters()
        XCTAssertEqual(win.lateFrames, 0)
        XCTAssertEqual(win.presentGaps, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    /// Locks the 28ms absolute floor against depth-2 self-sustaining promotion: at depth 2 with a
    /// 120Hz tick, presents can alternate 8.3/25ms around tick quantization while arrivals stay
    /// 60fps. The 25ms leg passes the gradient (25 ≥ 1.45×8.3) — ONLY the floor keeps it sub-late.
    func testTickQuantizationAlternationNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var arrival = 0.0, present = 0.0
        for i in 0..<240 {
            arrival += 1.0 / 60.0
            dp.noteArrival(arrival)
            present += (i % 2 == 0) ? 1.0 / 120.0 : 0.025
            XCTAssertNotEqual(dp.notePresent(present), .late, "tick-alternation gap must stay sub-late")
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    // MARK: Late classification + promotion

    func testSingleLateGapCountsButNoPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        let r = skipOneSlot(&dp, from: t)
        t = r.t
        XCTAssertEqual(r.cls, .late, "33ms dense-flow gap with a 2.0× gradient step is late")
        _ = driveClean(&dp, from: t, frames: 60)
        XCTAssertEqual(dp.drainCounters().lateFrames, 1)
        XCTAssertEqual(dp.depth, 1, "one late never promotes")
    }

    func testTwoLatesWithinWindowPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        (t, _) = { let r = skipOneSlot(&dp, from: t); return (r.t, r.cls) }()
        t = driveClean(&dp, from: t, frames: 34)            // ~570ms of clean flow
        let r2 = skipOneSlot(&dp, from: t)
        XCTAssertEqual(r2.cls, .late)
        XCTAssertEqual(dp.depth, 2, "2nd late within the 1s window promotes")
    }

    func testTwoLatesOutsideWindowNoPromote() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        (t, _) = { let r = skipOneSlot(&dp, from: t); return (r.t, r.cls) }()
        t = driveClean(&dp, from: t, frames: 72)            // 1.2s of clean flow
        let r2 = skipOneSlot(&dp, from: t)
        XCTAssertEqual(r2.cls, .late)
        XCTAssertEqual(dp.depth, 1, "lates 1.2s apart never pair inside the 1s window")
    }

    func testBurstPromotesWithinBudget() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 180)       // 3s clean
        let onset = t
        var promotedAt: Double?
        // 5% deterministic drop at 60fps: every 20th slot never arrives → 33ms gaps every 333ms.
        for i in 0..<600 {
            t += 1.0 / 60.0
            guard i % 20 != 0 else { continue }
            dp.noteArrival(t)
            dp.notePresent(t)
            if dp.depth == 2 && promotedAt == nil { promotedAt = t }
        }
        guard let promotedAt else { return XCTFail("never promoted under a 5% burst") }
        XCTAssertLessThanOrEqual(promotedAt - onset, 1.5, "promotion must land ≤1.5s after onset")
    }

    func testBurstHoldsDepthThroughout() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 120)
        // 10s of lates spaced 350-650ms apart (intra-burst quiet patches are sub-second): once
        // promoted, the 2.5s clean dwell can never elapse mid-burst.
        var promoted = false
        var held = true
        for k in 0..<20 {
            t = driveClean(&dp, from: t, frames: k % 2 == 0 ? 20 : 38)   // ~333ms / ~633ms
            let r = skipOneSlot(&dp, from: t)
            t = r.t
            if dp.depth == 2 { promoted = true }
            if promoted && dp.depth != 2 { held = false }
        }
        XCTAssertTrue(promoted)
        XCTAssertTrue(held, "no mid-burst demote while lates keep arriving")
        XCTAssertEqual(dp.depth, 2)
    }

    func testDemoteAfterCleanDwellRespectsMinHold() {
        // Default config: lastLate == promotedAt, so the 2.5s clean dwell dominates the 1s hold.
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        (t, _) = { let r = skipOneSlot(&dp, from: t); return (r.t, r.cls) }()
        t = driveClean(&dp, from: t, frames: 30)
        let r2 = skipOneSlot(&dp, from: t)
        t = r2.t
        XCTAssertEqual(dp.depth, 2)
        let lastLate = t
        var demotedAt: Double?
        for _ in 0..<300 {                                   // 5s clean
            t += 1.0 / 60.0
            dp.noteArrival(t)
            dp.notePresent(t)
            if dp.depth == 1 && demotedAt == nil { demotedAt = t }
        }
        guard let demotedAt else { return XCTFail("never demoted on a clean link") }
        XCTAssertGreaterThanOrEqual(demotedAt - lastLate, 2.5)
        XCTAssertLessThanOrEqual(demotedAt - lastLate, 2.5 + 2.0 / 60.0, "demote fires on the first evaluation past the dwell")

        // MIN-HOLD arm: a config whose dwell (0.5s) is SHORTER than the hold (1.5s) — the demote
        // must wait for the hold even though the dwell elapsed.
        var cfg = PacerDepthPolicy.Config()
        cfg.demoteCleanSeconds = 0.5
        cfg.minHoldSeconds = 1.5
        var dph = PacerDepthPolicy(config: cfg, adaptEnabled: true)
        var th = driveClean(&dph, from: 0, frames: 60)
        (th, _) = { let r = skipOneSlot(&dph, from: th); return (r.t, r.cls) }()
        th = driveClean(&dph, from: th, frames: 30)
        let rh = skipOneSlot(&dph, from: th)
        th = rh.t
        XCTAssertEqual(dph.depth, 2)
        let promotedAt = th
        var demotedAtH: Double?
        for _ in 0..<240 {
            th += 1.0 / 60.0
            dph.noteArrival(th)
            dph.notePresent(th)
            if dph.depth == 1 && demotedAtH == nil { demotedAtH = th }
        }
        guard let demotedAtH else { return XCTFail("min-hold arm never demoted") }
        XCTAssertGreaterThanOrEqual(demotedAtH - promotedAt, 1.5, "min-hold must dominate a shorter dwell")
        XCTAssertLessThanOrEqual(demotedAtH - promotedAt, 1.5 + 2.0 / 60.0)
    }

    // MARK: False-positive immunity

    func testIdleGapsClassifyIdleNotLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        for _ in 0..<10 {                                    // ≥250ms gaps = host idle-skip
            t += 0.300
            dp.noteArrival(t)
            XCTAssertEqual(dp.notePresent(t), .idle)
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    func testTypingSparseNeverLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = 0.0
        for i in 0..<40 {                                    // 150-220ms keystroke cadence
            t += 0.150 + Double(i % 8) * 0.010
            dp.noteArrival(t)
            XCTAssertNotEqual(dp.notePresent(t), .late, "sparse flow fails the dense gate")
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        XCTAssertEqual(dp.depth, 1)
    }

    /// 60→30fps downshift, no loss: the crossover emits AT MOST ONE transient late (the first
    /// 33ms gap is indistinguishable from a dropped slot without the cadence hint) and NEVER
    /// promotes — the gradient guard kills the following gaps and the median estimator converges
    /// within ~8 arrivals. The hint arm (`testIntervalHintOverridesEstimator`) is the zero-late path.
    func testFpsDownshiftNoFalseLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 120)
        var lates = 0
        for _ in 0..<150 {
            t += 1.0 / 30.0
            dp.noteArrival(t)
            if dp.notePresent(t) == .late { lates += 1 }
            XCTAssertEqual(dp.depth, 1, "a cadence change must never promote")
        }
        XCTAssertLessThanOrEqual(lates, 1, "at most the single crossover transient")
    }

    func testIntervalHintOverridesEstimator() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 120)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 60.0, accuracy: 0.002)
        dp.setIntervalHint(1.0 / 30.0)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 30.0, accuracy: 1e-9, "hint overrides the estimator instantly")
        XCTAssertEqual(dp.lateThresholdSeconds, 1.6 / 30.0, accuracy: 1e-9)
        // The downshift now emits ZERO lates — not even the crossover transient.
        for _ in 0..<150 {
            t += 1.0 / 30.0
            dp.noteArrival(t)
            XCTAssertNotEqual(dp.notePresent(t), .late)
        }
        XCTAssertEqual(dp.drainCounters().lateFrames, 0)
        // Clearing the hint returns to the estimator (now converged to ~33ms).
        dp.setIntervalHint(nil)
        XCTAssertEqual(dp.expectedIntervalSeconds, 1.0 / 30.0, accuracy: 0.004)
    }

    // MARK: Re-show gap episodes

    func testReshowEpisodeCountsOnceAndResolves() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        // Re-show ticks walk the open gap past the 28ms boundary: ONE episode however many ticks.
        dp.noteReshow(t + 0.025)                             // under the boundary: nothing
        XCTAssertEqual(dp.drainCounters().presentGaps, 0)
        dp.noteReshow(t + 0.033)                             // crosses: episode opens
        dp.noteReshow(t + 0.042)                             // latched: no recount
        dp.noteReshow(t + 0.050)
        // The resolving present ends the gap: late +1, episode closed.
        dp.noteArrival(t + 0.058)
        XCTAssertEqual(dp.notePresent(t + 0.058), .late)
        let win = dp.drainCounters()
        XCTAssertEqual(win.presentGaps, 1, "an episode is counted exactly once")
        XCTAssertEqual(win.lateFrames, 1)
        // A NEW gap after the close can open a fresh episode.
        dp.noteReshow(t + 0.058 + 0.040)
        XCTAssertEqual(dp.drainCounters().presentGaps, 1)
    }

    func testMotionStopCountsGapEpisodeButNoLate() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        let t = driveClean(&dp, from: 0, frames: 60)
        // Motion stops: re-shows walk out past the boundary (episode), but NO frame ever resolves
        // the gap — the next present is past the idle cap and classifies idle, never late.
        var tick = t + 1.0 / 120.0
        while tick < t + 0.400 { dp.noteReshow(tick); tick += 1.0 / 120.0 }
        dp.noteArrival(t + 0.400)
        XCTAssertEqual(dp.notePresent(t + 0.400), .idle)
        let win = dp.drainCounters()
        XCTAssertEqual(win.presentGaps, 1, "the stop boundary is one gap episode (superset semantics)")
        XCTAssertEqual(win.lateFrames, 0, "a stop boundary can never count late (nor promote)")
        XCTAssertEqual(dp.depth, 1)
    }

    // MARK: Counters + gating

    func testDrainCountersResets() {
        var dp = PacerDepthPolicy(adaptEnabled: true)
        var t = driveClean(&dp, from: 0, frames: 60)
        (t, _) = { let r = skipOneSlot(&dp, from: t); return (r.t, r.cls) }()
        let first = dp.drainCounters()
        XCTAssertEqual(first.lateFrames, 1)
        let second = dp.drainCounters()
        XCTAssertEqual(second.lateFrames, 0, "drain resets the window")
        XCTAssertEqual(second.presentGaps, 0)
    }

    func testAdaptDisabledCountsButNeverPromotes() {
        var dp = PacerDepthPolicy(adaptEnabled: false)
        var t = driveClean(&dp, from: 0, frames: 60)
        (t, _) = { let r = skipOneSlot(&dp, from: t); return (r.t, r.cls) }()
        t = driveClean(&dp, from: t, frames: 30)
        _ = skipOneSlot(&dp, from: t)
        XCTAssertEqual(dp.depth, 1, "telemetry-only mode never moves the depth")
        XCTAssertEqual(dp.drainCounters().lateFrames, 2, "counters still flow")
    }

    // MARK: Env config

    func testConfigFromEnvironmentClampsAndDefaults() {
        let defaults = PacerDepthPolicy.Config.fromEnvironment([:])
        XCTAssertEqual(defaults, PacerDepthPolicy.Config())

        let custom = PacerDepthPolicy.Config.fromEnvironment([
            "AISLOPDESK_DEPTH_PROMOTE_LATES": "3",
            "AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS": "500",
            "AISLOPDESK_DEPTH_DEMOTE_MS": "4000",
            "AISLOPDESK_DEPTH_MINHOLD_MS": "2000",
            "AISLOPDESK_DEPTH_LATE_FACTOR": "2.0",
            "AISLOPDESK_DEPTH_IDLE_MS": "350",
        ])
        XCTAssertEqual(custom.promoteLateCount, 3)
        XCTAssertEqual(custom.promoteWindowSeconds, 0.5, accuracy: 1e-9)
        XCTAssertEqual(custom.demoteCleanSeconds, 4.0, accuracy: 1e-9)
        XCTAssertEqual(custom.minHoldSeconds, 2.0, accuracy: 1e-9)
        XCTAssertEqual(custom.lateGapFactor, 2.0, accuracy: 1e-9)
        XCTAssertEqual(custom.idleGapSeconds, 0.35, accuracy: 1e-9)

        let clamped = PacerDepthPolicy.Config.fromEnvironment([
            "AISLOPDESK_DEPTH_PROMOTE_LATES": "99",          // lateTimes ring holds 4
            "AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS": "0",
            "AISLOPDESK_DEPTH_DEMOTE_MS": "999999",
            "AISLOPDESK_DEPTH_LATE_FACTOR": "0.1",
            "AISLOPDESK_DEPTH_IDLE_MS": "garbage",
        ])
        XCTAssertEqual(clamped.promoteLateCount, 4)
        XCTAssertEqual(clamped.promoteWindowSeconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(clamped.demoteCleanSeconds, 30.0, accuracy: 1e-9)
        XCTAssertEqual(clamped.lateGapFactor, 1.1, accuracy: 1e-9)
        XCTAssertEqual(clamped.idleGapSeconds, PacerDepthPolicy.Config().idleGapSeconds, "garbage keeps the default")
    }
}
