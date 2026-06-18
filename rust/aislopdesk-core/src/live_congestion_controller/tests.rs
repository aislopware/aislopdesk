//! Unit tests for the AIMD `LiveCongestionController` control law.

use super::*;

const CEILING: i64 = 45_000_000;

fn estimate(loss_samples: f64, folds: i64, rtt_congested: bool) -> NetworkEstimate {
    let mut est = NetworkEstimate::new();
    let unrecovered = (loss_samples * 1000.0).round() as u32;
    for _ in 0..folds.max(1) {
        est.fold(Some(50), 1000, unrecovered, 100);
        if rtt_congested {
            est.fold(Some(50), 1000, unrecovered, 200);
            est.fold(Some(500), 1000, unrecovered, 9000);
        }
    }
    est
}

fn warmed_controller(ceiling: i64, floor: Option<i64>, gradient: bool) -> LiveCongestionController {
    let mut ctrl = floor.map_or_else(
        || LiveCongestionController::with_gradient_cut(ceiling, gradient),
        |f| LiveCongestionController::with_floor(ceiling, f, gradient),
    );
    let clean = estimate(0.0, 1, false);
    for _ in 0..WARMUP_TICKS {
        let _ = ctrl.on_report(&clean);
    }
    ctrl
}

fn gradient_estimate(
    raw_rtt: Option<i64>,
    overusing: bool,
    baseline_folds: i64,
) -> NetworkEstimate {
    let mut est = NetworkEstimate::new();
    for _ in 0..baseline_folds {
        est.fold(Some(50), 1000, 0, 100);
    }
    est.fold_with_trend(
        raw_rtt,
        1000,
        0,
        100,
        u8::from(overusing),
        if overusing { 80_000 } else { 0 },
    );
    est
}

fn stepped_clean(est: &mut NetworkEstimate, ctrl: &mut LiveCongestionController, count: i64) {
    for _ in 0..count {
        est.fold(Some(50), 1000, 0, 100);
        let _ = ctrl.on_report(est);
    }
}

#[test]
fn starts_at_ceiling() {
    assert_eq!(LiveCongestionController::new(CEILING).current(), CEILING);
}

#[test]
fn floor_derived_from_ceiling_and_never_below_minimum() {
    let big = LiveCongestionController::new(40_000_000);
    assert_eq!(big.floor(), (40_000_000.0 * MIN_FRAC) as i64);
    let tiny = LiveCongestionController::new(2_000_000);
    assert_eq!(tiny.floor(), MINIMUM_BITRATE);
    assert!(tiny.floor() > 0);
}

#[test]
fn explicit_floor_clamped_into_range() {
    let over = LiveCongestionController::with_floor(10_000_000, 99_000_000, false);
    assert_eq!(over.floor(), 10_000_000);
    let under = LiveCongestionController::with_floor(10_000_000, 0, false);
    assert_eq!(under.floor(), MINIMUM_BITRATE);
}

#[test]
fn warmup_is_a_no_op() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let lossy = estimate(0.5, 8, false);
    for _ in 0..(WARMUP_TICKS - 1) {
        assert_eq!(ctrl.on_report(&lossy), CEILING);
    }
    assert_eq!(ctrl.current(), CEILING);
    assert!(ctrl.on_report(&lossy) < CEILING);
}

#[test]
fn decrease_on_loss_above_threshold() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let lossy = estimate(0.05, 8, true);
    let before = ctrl.current();
    let after = ctrl.on_report(&lossy);
    assert_eq!(
        after,
        ctrl.floor().max((before as f64 * DECREASE_FACTOR) as i64)
    );
    assert!(after < before);
}

#[test]
fn severe_loss_halves() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let severe = estimate(0.5, 12, false);
    let before = ctrl.current();
    let after = ctrl.on_report(&severe);
    assert_eq!(
        after,
        ctrl.floor()
            .max((before as f64 * SEVERE_DECREASE_FACTOR) as i64)
    );
    let mut ordinary_ctrl = warmed_controller(CEILING, None, false);
    let ordinary = ordinary_ctrl.on_report(&estimate(0.05, 8, true));
    assert!(after < ordinary);
}

#[test]
fn decrease_on_sustained_rtt_inflation() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let rtt = estimate(0.0, 4, true);
    assert!(rtt.smoothed_rtt_millis() > rtt.min_rtt_millis() * RTT_INFLATE_FACTOR);
    assert!(rtt.smoothed_rtt_millis() > rtt.min_rtt_millis() + RTT_SLACK_MILLIS);
    let before = ctrl.current();
    for _ in 0..(RTT_STREAK_TICKS - 1) {
        assert_eq!(ctrl.on_report(&rtt), before);
    }
    assert!(ctrl.on_report(&rtt) < before);
}

#[test]
fn clean_lan_jitter_never_decreases() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    est.fold(Some(5), 1000, 0, 10_000);
    let rtts = [7, 12, 9, 15, 6, 11, 5, 16, 8, 13];
    let jitters: [u32; 6] = [9_000, 14_000, 11_000, 13_500, 10_000, 12_500];
    for i in 0..200usize {
        est.fold(
            Some(rtts[i % rtts.len()]),
            1000,
            0,
            jitters[i % jitters.len()],
        );
        assert_eq!(ctrl.on_report(&est), CEILING);
    }
}

#[test]
fn sustained_rtt_inflation_backs_off_once_per_window_not_per_report() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(5), 1000, 0, 100);
    let mut decrease_ticks: Vec<i64> = Vec::new();
    for i in 0..(HOLD_TICKS + 10) {
        est.fold(Some(80), 1000, 0, 100);
        let before = ctrl.current();
        let raw = (est.min_rtt_millis() + RTT_SLACK_MILLIS) / est.smoothed_rtt_millis();
        let factor = RTT_DECREASE_CAP_FACTOR.min(RTT_DECREASE_FLOOR_FACTOR.max(raw));
        let after = ctrl.on_report(&est);
        if after < before {
            decrease_ticks.push(i);
            assert_eq!(after, ctrl.floor().max((before as f64 * factor) as i64));
        }
    }
    assert!(decrease_ticks.len() >= 2);
    for pair in decrease_ticks.windows(2) {
        assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
    }
}

#[test]
fn rtt_decrease_clamp_bounds() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(5), 1000, 0, 100);
    let mut first: Option<(i64, i64, f64)> = None;
    for _ in 0..10 {
        est.fold(Some(300), 1000, 0, 100);
        let before = ctrl.current();
        let raw = (est.min_rtt_millis() + RTT_SLACK_MILLIS) / est.smoothed_rtt_millis();
        let after = ctrl.on_report(&est);
        if after < before {
            first = Some((before, after, raw));
            break;
        }
    }
    let (before, after, factor) = first.expect("must decrease");
    assert!(factor < RTT_DECREASE_FLOOR_FACTOR);
    assert_eq!(after, (before as f64 * RTT_DECREASE_FLOOR_FACTOR) as i64);

    let mut gentle = warmed_controller(CEILING, None, false);
    let mut est2 = NetworkEstimate::new();
    est2.fold(Some(10), 1000, 0, 100);
    let mut saw = false;
    for _ in 0..40 {
        est2.fold(Some(31), 1000, 0, 100);
        let before = gentle.current();
        let raw = (est2.min_rtt_millis() + effective_slack_millis(est2.min_rtt_millis()))
            / est2.smoothed_rtt_millis();
        let after = gentle.on_report(&est2);
        if after < before {
            saw = true;
            assert!(raw > RTT_DECREASE_CAP_FACTOR);
            assert_eq!(after, (before as f64 * RTT_DECREASE_CAP_FACTOR) as i64);
            break;
        }
    }
    assert!(saw);
}

#[test]
fn knee_cautious_climb_above_fast_below() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let _ = ctrl.on_report(&estimate(0.05, 8, true));
    let knee = ctrl.current();
    assert_eq!(ctrl.knee_bps(), Some(knee));

    let mut est = NetworkEstimate::new();
    est.fold(Some(50), 1000, 0, 100);
    for _ in 0..(HOLD_TICKS + 10) {
        est.fold(Some(50), 1000, 1000, 100);
        let _ = ctrl.on_report(&est);
    }
    assert!(ctrl.current() < knee);
    assert_eq!(ctrl.knee_bps(), Some(knee));

    let full_step = (CEILING / INCREASE_DIVISOR).max(1);
    let cautious_step = (full_step / KNEE_CAUTION_DIVISOR).max(1);
    let mut saw_full = false;
    let mut saw_cautious = false;
    for _ in 0..2_000 {
        est.fold(Some(50), 1000, 0, 100);
        let before = ctrl.current();
        let after = ctrl.on_report(&est);
        if after <= before {
            continue;
        }
        if before < knee {
            assert_eq!(after - before, full_step);
            saw_full = true;
        } else {
            assert_eq!(after - before, cautious_step);
            saw_cautious = true;
        }
        if saw_cautious && after >= knee + 2 * cautious_step {
            break;
        }
    }
    assert!(saw_full);
    assert!(saw_cautious);
}

#[test]
fn draining_queue_never_re_cuts() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(5), 1000, 0, 100);
    let mut after_first_cut: Option<i64> = None;
    for _ in 0..10 {
        est.fold(Some(300), 1000, 0, 100);
        let before = ctrl.current();
        if ctrl.on_report(&est) < before {
            after_first_cut = Some(ctrl.current());
            break;
        }
    }
    let cut = after_first_cut.expect("a rising queue must cut");
    let mut rtt = 100;
    for _ in 0..40 {
        rtt = (rtt - 12).max(6);
        est.fold(Some(rtt), 1000, 0, 100);
        let _ = ctrl.on_report(&est);
        assert!(ctrl.current() >= cut);
    }
}

#[test]
fn knee_expires_after_ttl() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let _ = ctrl.on_report(&estimate(0.05, 8, true));
    assert!(ctrl.knee_bps().is_some());
    let clean = estimate(0.0, 1, false);
    for _ in 0..=KNEE_TTL_TICKS {
        let _ = ctrl.on_report(&clean);
    }
    assert_eq!(ctrl.knee_bps(), None);
}

#[test]
fn high_baseline_wobble_does_not_cut() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(40), 1000, 0, 100);
    for _ in 0..100 {
        est.fold(Some(60), 1000, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), CEILING);
}

#[test]
fn high_baseline_real_queue_still_cuts() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(40), 1000, 0, 100);
    let mut cut = false;
    for _ in 0..20 {
        est.fold(Some(120), 1000, 0, 100);
        let before = ctrl.current();
        if ctrl.on_report(&est) < before {
            cut = true;
            break;
        }
    }
    assert!(cut);
}

#[test]
fn effective_slack_unchanged_on_lan_baseline() {
    assert_eq!(effective_slack_millis(10.0), 15.0);
    assert_eq!(effective_slack_millis(5.0), 15.0);
    assert_eq!(effective_slack_millis(40.0), 30.0);
    assert_eq!(effective_slack_millis(f64::INFINITY), 15.0);
}

#[test]
fn absolute_slack_guards_tiny_baseline() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    est.fold(Some(3), 1000, 0, 100);
    for _ in 0..200 {
        est.fold(Some(12), 1000, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), CEILING);
}

#[test]
fn hold_down_suppresses_immediate_re_increase() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let dropped = ctrl.on_report(&estimate(0.05, 8, true));
    assert!(dropped < CEILING);
    let clean = estimate(0.0, 1, false);
    for _ in 0..(HOLD_TICKS - 1) {
        assert_eq!(ctrl.on_report(&clean), dropped);
    }
}

#[test]
fn probe_increase_on_clean_link_past_hold_down() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let dropped = ctrl.on_report(&estimate(0.05, 8, true));
    let clean = estimate(0.0, 1, false);
    for _ in 0..HOLD_TICKS {
        let _ = ctrl.on_report(&clean);
    }
    let probed = ctrl.on_report(&clean);
    assert!(probed > dropped);
    let step = (CEILING / INCREASE_DIVISOR).max(1);
    assert!(probed - dropped <= step * (HOLD_TICKS + 1));
}

#[test]
fn idle_utilization_gates_ramp_decay_and_hold() {
    // The utilization fix has THREE regimes (the host passes recent offered throughput):
    //   loaded (offered ≥ 0.5×current) → RAMP;  deeply idle (offered < 0.25×current) → DECAY toward
    //   offered;  in between → HOLD. No signal / non-finite ⇒ legacy RAMP. This is the "scroll-up-at-
    //   top then scroll-down-hard → blur+lag" fix: idle shrinks the target so the burst stays bounded.
    let clean = estimate(0.0, 1, false);
    let floored = || warmed_controller(CEILING, Some(3_000_000), false); // floor 3M, current at ceiling

    // (a) DEEPLY idle: offered ~2% of current ⇒ DECAY toward offered (target FALLS, well above floor).
    let mut idle = floored();
    let before = idle.current();
    let d = idle.decide_with_utilization(&clean, Some(before as f64 * 0.02));
    assert!(d.target < before, "deep idle must decay the target down");
    assert!(d.target >= idle.floor(), "decay never goes below floor");
    assert_eq!(d.reason, CutReason::AppLimited);

    // (b) MODERATELY idle: offered ~40% of current (between the two fractions) ⇒ HOLD — neither ramp
    // (0.40 < 0.50) nor decay (0.40 > 0.25). Protects a brief flick-pause from over-decaying.
    let mut mid = floored();
    let before_m = mid.current();
    // At ceiling a ramp is a no-op, so drop below ceiling first via a congestion cut + hold-down so a
    // ramp WOULD be observable — then prove 0.40 utilization neither ramps nor decays.
    let _ = mid.on_report(&estimate(0.05, 8, true));
    for _ in 0..HOLD_TICKS {
        let _ = mid.on_report(&clean);
    }
    let mid_before = mid.current();
    let d_m = mid.decide_with_utilization(&clean, Some(mid_before as f64 * 0.40));
    assert_eq!(
        d_m.target, mid_before,
        "moderate idle holds (no ramp, no decay)"
    );
    assert_eq!(d_m.reason, CutReason::Hold);
    let _ = before_m;

    // (c) LOADED: offered ~90% of current ⇒ RAMP up. Poise below the ceiling first.
    let mut loaded = warmed_controller(CEILING, None, false);
    let _ = loaded.on_report(&estimate(0.05, 8, true));
    for _ in 0..HOLD_TICKS {
        let _ = loaded.on_report(&clean);
    }
    let before_l = loaded.current();
    let d_l = loaded.decide_with_utilization(&clean, Some(before_l as f64 * 0.9));
    assert!(d_l.target > before_l, "real load must ramp up");
    assert!(
        matches!(d_l.reason, CutReason::Probe | CutReason::Knee),
        "real load ramps (Probe or cautious Knee), got {:?}",
        d_l.reason
    );

    // (d) NO signal / non-finite ⇒ legacy RAMP (every pre-fix caller / golden path unchanged).
    let mut legacy = warmed_controller(CEILING, None, false);
    let _ = legacy.on_report(&estimate(0.05, 8, true));
    for _ in 0..HOLD_TICKS {
        let _ = legacy.on_report(&clean);
    }
    let before_n = legacy.current();
    assert!(
        legacy.decide(&clean).target > before_n,
        "no signal ⇒ legacy probe"
    );

    let mut nan_sig = warmed_controller(CEILING, None, false);
    let _ = nan_sig.on_report(&estimate(0.05, 8, true));
    for _ in 0..HOLD_TICKS {
        let _ = nan_sig.on_report(&clean);
    }
    let before_x = nan_sig.current();
    assert!(
        nan_sig
            .decide_with_utilization(&clean, Some(f64::NAN))
            .target
            > before_x,
        "non-finite offered ⇒ permit probe"
    );
}

#[test]
fn recovery_never_exceeds_ceiling() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let _ = ctrl.on_report(&estimate(0.5, 12, false));
    let clean = estimate(0.0, 1, false);
    for _ in 0..10_000 {
        let _ = ctrl.on_report(&clean);
    }
    assert_eq!(ctrl.current(), CEILING);
}

#[test]
fn single_transient_spike_at_flat_rtt_never_decreases() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    stepped_clean(&mut est, &mut ctrl, WARMUP_TICKS);
    assert_eq!(ctrl.current(), CEILING);
    est.fold(Some(50), 1000, 1000, 100);
    assert_eq!(ctrl.on_report(&est), CEILING);
    assert!(est.loss_rate() > LOSS_THRESHOLD);
    for _ in 0..60 {
        est.fold(Some(50), 1000, 0, 100);
        assert_eq!(ctrl.on_report(&est), CEILING);
    }
}

#[test]
fn sustained_collapse_halves_once_per_hold_down() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    stepped_clean(&mut est, &mut ctrl, WARMUP_TICKS);
    let mut first_halve: Option<i64> = None;
    for i in 0..HOLD_TICKS {
        est.fold(Some(50), 1000, 1000, 100);
        let _ = ctrl.on_report(&est);
        if first_halve.is_none() && ctrl.current() < CEILING {
            first_halve = Some(i);
        }
    }
    assert!(first_halve.is_some());
    assert_eq!(
        ctrl.current(),
        ctrl.floor()
            .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
    );
    stepped_clean(&mut est, &mut ctrl, 3);
    assert!(
        ctrl.current()
            >= ctrl
                .floor()
                .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
    );
}

#[test]
fn no_op_decrease_at_floor_does_not_extend_hold_down() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    for _ in 0..200 {
        est.fold(Some(50), 1000, 1000, 100);
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), ctrl.floor());
    assert!(ctrl.hold_until_tick() <= ctrl.ticks());
    for _ in 0..11 {
        est.fold(Some(50), 1000, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    est.fold(Some(50), 1000, 0, 100);
    assert!(ctrl.on_report(&est) > ctrl.floor());
}

#[test]
fn weather_loss_flat_rtt_never_decreases() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let mut est = NetworkEstimate::new();
    est.fold(Some(50), 1000, 0, 100);
    let loss_per_mille: [u32; 8] = [30, 90, 42, 60, 86, 33, 77, 51];
    for i in 0..200usize {
        est.fold(
            Some(50),
            1000,
            loss_per_mille[i % loss_per_mille.len()],
            300,
        );
        assert_eq!(ctrl.on_report(&est), CEILING);
    }
}

#[test]
fn loss_with_rtt_inflation_decreases_immediately() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let congested = estimate(0.05, 4, true);
    let before = ctrl.current();
    assert!(ctrl.on_report(&congested) < before);
}

#[test]
fn catastrophic_loss_halves_even_at_flat_rtt() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let catastrophic = estimate(0.30, 16, false);
    assert!(catastrophic.loss_rate() > CATASTROPHIC_LOSS_THRESHOLD);
    let after = ctrl.on_report(&catastrophic);
    assert_eq!(
        after,
        ctrl.floor()
            .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
    );
}

#[test]
fn weather_burst_spanning_reports_cuts_once_per_window() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    for _ in 0..(WARMUP_TICKS + 5) {
        est.fold(Some(6), 3, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), CEILING);
    let before = ctrl.current();
    for i in 0..6u32 {
        est.fold(Some(80), 2 + i % 2, 1, 500);
        let _ = ctrl.on_report(&est);
    }
    let one_cut = ctrl.floor().max((before as f64 * DECREASE_FACTOR) as i64);
    assert_eq!(ctrl.current(), one_cut);
    assert!(ctrl.current() > ctrl.floor());
}

#[test]
fn severe_raw_sample_no_longer_fast_halves() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    for _ in 0..(WARMUP_TICKS + 5) {
        est.fold(Some(6), 3, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    for _ in 0..2 {
        est.fold(Some(80), 3, 0, 500);
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), CEILING);
    est.fold(Some(80), 2, 1, 500);
    assert!(est.loss_rate() < CATASTROPHIC_LOSS_THRESHOLD);
    let after = ctrl.on_report(&est);
    assert_eq!(
        after,
        ctrl.floor().max((CEILING as f64 * DECREASE_FACTOR) as i64)
    );
}

#[test]
fn persistent_corroborated_loss_cuts_spaced_by_window() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let mut est = NetworkEstimate::new();
    for _ in 0..(WARMUP_TICKS + 5) {
        est.fold(Some(6), 3, 0, 100);
        let _ = ctrl.on_report(&est);
    }
    let mut cut_ticks: Vec<i64> = Vec::new();
    for i in 0..40 {
        est.fold(Some(80), 20, 1, 500);
        let before = ctrl.current();
        let _ = ctrl.on_report(&est);
        if ctrl.current() < before {
            cut_ticks.push(i);
        }
    }
    assert!(cut_ticks.len() >= 2);
    for pair in cut_ticks.windows(2) {
        assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
    }
}

#[test]
fn decrease_never_below_floor() {
    let mut ctrl = warmed_controller(CEILING, None, false);
    let severe = estimate(0.5, 12, false);
    for _ in 0..10_000 {
        let _ = ctrl.on_report(&severe);
    }
    assert_eq!(ctrl.current(), ctrl.floor());
    assert!(ctrl.current() >= MINIMUM_BITRATE);
    assert!(ctrl.current() > 0);
}

#[test]
fn inert_when_no_loss_and_no_rtt() {
    let mut ctrl = LiveCongestionController::new(CEILING);
    let blind = NetworkEstimate::new();
    for _ in 0..1_000 {
        let _ = ctrl.on_report(&blind);
    }
    assert_eq!(ctrl.current(), CEILING);
}

#[test]
fn never_decreases_on_absence_of_data() {
    let mut est = NetworkEstimate::new();
    for _ in 0..20 {
        est.fold(None, 1000, 0, 100);
    }
    let mut ctrl = LiveCongestionController::new(CEILING);
    for _ in 0..1_000 {
        let _ = ctrl.on_report(&est);
    }
    assert_eq!(ctrl.current(), CEILING);
}

#[test]
fn churn_gate_suppresses_tiny_changes() {
    assert!(!LiveCongestionController::is_material_change(
        45_000_000, 45_100_000, CEILING
    ));
    assert!(LiveCongestionController::is_material_change(
        45_000_000, 42_000_000, CEILING
    ));
}

#[test]
fn churn_gate_absolute_floor_for_small_ceiling() {
    let small = 4_000_000;
    assert!(!LiveCongestionController::is_material_change(
        4_000_000, 3_700_000, small
    ));
    assert!(LiveCongestionController::is_material_change(
        4_000_000, 3_400_000, small
    ));
}

#[test]
fn additive_ticks_accumulate_to_a_material_actuation() {
    let step = CEILING / INCREASE_DIVISOR;
    assert!(!LiveCongestionController::is_material_change(
        CEILING - step,
        CEILING,
        CEILING
    ));
    assert!(LiveCongestionController::is_material_change(
        CEILING - 2 * step,
        CEILING,
        CEILING
    ));
}

#[test]
fn gradient_flag_defaults_off() {
    // Documents the shipped default (a guard against an accidental flip), hence the const assert.
    #[allow(clippy::assertions_on_constants)]
    {
        assert!(!GRADIENT_CUT_ENABLED_DEFAULT);
    }
    assert!(!LiveCongestionController::new(CEILING).gradient_cut_enabled());
    assert!(LiveCongestionController::with_gradient_cut(CEILING, true).gradient_cut_enabled());
}

#[test]
fn gradient_overuse_cuts_after_one_report() {
    let mut ctrl = warmed_controller(CEILING, None, true);
    let est = gradient_estimate(Some(200), true, 8);
    let slack = effective_slack_millis(est.min_rtt_millis());
    assert!(est.smoothed_rtt_millis() <= est.min_rtt_millis() + slack);
    let before = ctrl.current();
    let after = ctrl.on_report(&est);
    assert_eq!(
        after,
        ctrl.floor()
            .max((before as f64 * GRADIENT_DECREASE_FACTOR) as i64)
    );
    assert!(after < before);
}

#[test]
fn gradient_cut_requires_raw_rtt_corroboration() {
    let mut flat_raw = warmed_controller(CEILING, None, true);
    assert_eq!(
        flat_raw.on_report(&gradient_estimate(Some(50), true, 8)),
        CEILING
    );
    let mut rejected_raw = warmed_controller(CEILING, None, true);
    assert_eq!(
        rejected_raw.on_report(&gradient_estimate(None, true, 8)),
        CEILING
    );
}

#[test]
fn gradient_cut_respects_cut_hold_spacing() {
    let mut ctrl = warmed_controller(CEILING, None, true);
    let mut est = NetworkEstimate::new();
    for _ in 0..8 {
        est.fold(Some(50), 1000, 0, 100);
    }
    est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
    assert!(ctrl.on_report(&est) < CEILING);
    let mut cut_ticks: Vec<i64> = Vec::new();
    let mut last = ctrl.current();
    for i in 1..=(CUT_HOLD_TICKS * 2) {
        est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
        let after = ctrl.on_report(&est);
        if after < last {
            cut_ticks.push(i);
        }
        last = after;
    }
    assert!(!cut_ticks.is_empty());
    assert!(cut_ticks[0] >= CUT_HOLD_TICKS);
    for pair in cut_ticks.windows(2) {
        assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
    }
}

#[test]
fn gradient_disabled_is_byte_identical_to_today() {
    let mut with_trend = LiveCongestionController::new(CEILING);
    let mut no_trend = LiveCongestionController::new(CEILING);
    let mut est_a = NetworkEstimate::new();
    let mut est_b = NetworkEstimate::new();
    for i in 0..60 {
        let rtt = if i % 5 == 0 { 200 } else { 50 };
        let lost: u32 = if i % 7 == 0 { 30 } else { 0 };
        est_a.fold_with_trend(Some(rtt), 1000, lost, 100, 1, 99_000);
        est_b.fold(Some(rtt), 1000, lost, 100);
        assert_eq!(with_trend.on_report(&est_a), no_trend.on_report(&est_b));
    }
    assert_eq!(with_trend, no_trend);
}

#[test]
fn gradient_overuse_suppresses_additive_increase() {
    let mut ctrl = warmed_controller(CEILING, None, true);
    let cut = ctrl.on_report(&gradient_estimate(Some(200), true, 8));
    assert!(cut < CEILING);
    let mut est = NetworkEstimate::new();
    for _ in 0..8 {
        est.fold(Some(50), 1000, 0, 100);
    }
    for _ in 0..(HOLD_TICKS + 10) {
        est.fold_with_trend(Some(50), 1000, 0, 100, 1, 80_000);
        assert_eq!(ctrl.on_report(&est), cut);
    }
    est.fold(Some(50), 1000, 0, 100);
    assert!(ctrl.on_report(&est) > cut);
}

#[test]
fn gradient_cut_sets_no_knee() {
    let mut ctrl = warmed_controller(CEILING, None, true);
    let _ = ctrl.on_report(&gradient_estimate(Some(200), true, 8));
    assert!(ctrl.current() < CEILING);
    assert_eq!(ctrl.knee_bps(), None);
}

#[test]
fn gradient_then_sustained_queue_proportional_cut_next_window() {
    let mut ctrl = warmed_controller(CEILING, None, true);
    let mut est = NetworkEstimate::new();
    for _ in 0..8 {
        est.fold(Some(50), 1000, 0, 100);
    }
    est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
    let after_gradient = ctrl.on_report(&est);
    assert_eq!(
        after_gradient,
        (CEILING as f64 * GRADIENT_DECREASE_FACTOR) as i64
    );
    assert_eq!(ctrl.knee_bps(), None);
    let mut cut_tick: Option<i64> = None;
    for i in 1..=(CUT_HOLD_TICKS + 2) {
        est.fold_with_trend(Some(250), 1000, 0, 100, 1, 80_000);
        let before = ctrl.current();
        if ctrl.on_report(&est) < before {
            cut_tick = Some(i);
            break;
        }
    }
    assert_eq!(cut_tick, Some(CUT_HOLD_TICKS));
    assert!(ctrl.knee_bps().is_some());
}
