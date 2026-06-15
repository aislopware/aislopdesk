//! `pacer_depth_policy`: opaque handle (client adaptive pacer-depth v3). Driven on the
//! `FramePacer` (NSLock-serialized): `note_arrival` per decoded submit, `note_present`/`note_reshow`
//! per vsync, `note_network_late` per owd spike, `drain_counters` per netstats report. The 19-field
//! Config crosses as a flat repr(C) struct by value (env resolved Swift-side); `GapClass` crosses as
//! a u8; the drained counters as a flat pair. The internal rings stay Rust-side (never marshaled).
//! One owner (`FramePacer`). Same "Rust owns the state" boundary as the deduper.

use aislopdesk_core::pacer_depth_policy::{
    Config as PacerDepthConfig, GapClass as PacerGapClass, PacerDepthPolicy,
};

/// [`PacerGapClass::First`] discriminant — the first present (no predecessor gap).
pub const AISD_PACER_GAP_FIRST: u8 = 0;
/// [`PacerGapClass::Normal`] discriminant — an ordinary in-flow gap.
pub const AISD_PACER_GAP_NORMAL: u8 = 1;
/// [`PacerGapClass::Late`] discriminant — a gap past the late boundary (dense, sharp gradient).
pub const AISD_PACER_GAP_LATE: u8 = 2;
/// [`PacerGapClass::Idle`] discriminant — a gap past the idle cap (host idle-skip / motion stop).
pub const AISD_PACER_GAP_IDLE: u8 = 3;

/// The 19 [`PacerDepthConfig`] tunables, flattened for the C ABI (env resolved Swift-side; crosses
/// by value). Field-for-field with the core `Config`; integers are `usize`/`i64`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPacerDepthConfig {
    /// late iff gap > max(`absolute_late_floor_seconds`, this × expected interval).
    pub late_gap_factor: f64,
    /// The HW-validated KHỰNG threshold floor (seconds).
    pub absolute_late_floor_seconds: f64,
    /// A gap above this is IDLE (host idle-skip / motion stop), never late.
    pub idle_gap_seconds: f64,
    /// Late additionally requires gap ≥ this × the previous in-flow present gap.
    pub gap_gradient_factor: f64,
    /// Dense flow = ≥ this many arrivals within `dense_window_seconds` before the gap opened.
    pub dense_min_arrivals: usize,
    /// The dense-flow lookback window (seconds).
    pub dense_window_seconds: f64,
    /// Extra late-boundary margin, as a fraction of the expected interval.
    pub late_slack_fraction: f64,
    /// Promote on this many late events within `promote_window_seconds`.
    pub promote_late_count: usize,
    /// The promote pairing window (seconds).
    pub promote_window_seconds: f64,
    /// Demote after this long with at most `demote_tolerance_lates` late events in the window…
    pub demote_clean_seconds: f64,
    /// …but never sooner than this after a promotion (anti-flap).
    pub min_hold_seconds: f64,
    /// Demote tolerance: late events allowed inside the trailing dwell (0 = strict).
    pub demote_tolerance_lates: usize,
    /// Promote decisions are ignored for this long after the first arrival (cold-start guard).
    pub promote_warmup_seconds: f64,
    /// The boosted depth (1 ↔ 2 only).
    pub boost_depth: i64,
    /// Expected-interval = median of the last N in-flow inter-arrival gaps.
    pub interval_ring_size: usize,
    /// Minimum ring samples before the estimator is used.
    pub min_samples_for_estimate: usize,
    /// The expected interval before the estimator warms (seconds).
    pub default_interval_seconds: f64,
    /// Expected-interval floor (seconds).
    pub min_interval_seconds: f64,
    /// Expected-interval ceiling (seconds).
    pub max_interval_seconds: f64,
}

impl AisdPacerDepthConfig {
    /// Rebuilds the core [`PacerDepthConfig`] (by field name, so the flat order can't silently skew).
    const fn to_core(self) -> PacerDepthConfig {
        PacerDepthConfig {
            late_gap_factor: self.late_gap_factor,
            absolute_late_floor_seconds: self.absolute_late_floor_seconds,
            idle_gap_seconds: self.idle_gap_seconds,
            gap_gradient_factor: self.gap_gradient_factor,
            dense_min_arrivals: self.dense_min_arrivals,
            dense_window_seconds: self.dense_window_seconds,
            late_slack_fraction: self.late_slack_fraction,
            promote_late_count: self.promote_late_count,
            promote_window_seconds: self.promote_window_seconds,
            demote_clean_seconds: self.demote_clean_seconds,
            min_hold_seconds: self.min_hold_seconds,
            demote_tolerance_lates: self.demote_tolerance_lates,
            promote_warmup_seconds: self.promote_warmup_seconds,
            boost_depth: self.boost_depth,
            interval_ring_size: self.interval_ring_size,
            min_samples_for_estimate: self.min_samples_for_estimate,
            default_interval_seconds: self.default_interval_seconds,
            min_interval_seconds: self.min_interval_seconds,
            max_interval_seconds: self.max_interval_seconds,
        }
    }
}

/// One drained window of the pacer's presentation-health counters, flattened for the C ABI.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdPacerCounters {
    /// Windowed NETWORK-late events (the depth-promotion input).
    pub late_frames: u32,
    /// Windowed late-gap EPISODES opened.
    pub present_gaps: u32,
}

const fn pacer_gap_class_to_c(g: PacerGapClass) -> u8 {
    match g {
        PacerGapClass::First => AISD_PACER_GAP_FIRST,
        PacerGapClass::Normal => AISD_PACER_GAP_NORMAL,
        PacerGapClass::Late => AISD_PACER_GAP_LATE,
        PacerGapClass::Idle => AISD_PACER_GAP_IDLE,
    }
}

/// Opaque client adaptive pacer-depth policy.
///
/// Create with [`aisd_pacer_depth_policy_new`] (resolved `Config` + adapt flag), drive it with the
/// `_note_*` / `_drain_counters` / `_set_interval_hint` calls, read `_depth`, destroy with
/// [`aisd_pacer_depth_policy_free`]. One per pacer; not thread-safe (the caller's lock serializes).
pub struct AisdPacerDepthPolicy {
    inner: PacerDepthPolicy,
}

/// Creates a pacer-depth policy from the resolved config + `adapt_enabled` (read `!= 0`). Destroy it
/// with [`aisd_pacer_depth_policy_free`]. Wraps [`PacerDepthPolicy::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_pacer_depth_policy_new(
    config: AisdPacerDepthConfig,
    adapt_enabled: u8,
) -> *mut AisdPacerDepthPolicy {
    Box::into_raw(Box::new(AisdPacerDepthPolicy {
        inner: PacerDepthPolicy::new(config.to_core(), adapt_enabled != 0),
    }))
}

/// Destroys a policy created by [`aisd_pacer_depth_policy_new`]. No-op on null.
///
/// # Safety
/// `policy` must be a pointer from [`aisd_pacer_depth_policy_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_free(policy: *mut AisdPacerDepthPolicy) {
    unsafe {
        if !policy.is_null() {
            drop(Box::from_raw(policy));
        }
    }
}

/// The recommended presentation depth (1 or `boost_depth`). Returns `1` for a null handle (the
/// conservative no-slack default). Wraps [`PacerDepthPolicy::depth`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_depth(policy: *const AisdPacerDepthPolicy) -> i64 {
    unsafe { policy.as_ref().map_or(1, |p| p.inner.depth()) }
}

/// The expected content interval (seconds), or `0.0` for a null handle. Wraps
/// [`PacerDepthPolicy::expected_interval_seconds`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_expected_interval_seconds(
    policy: *const AisdPacerDepthPolicy,
) -> f64 {
    unsafe {
        policy
            .as_ref()
            .map_or(0.0, |p| p.inner.expected_interval_seconds())
    }
}

/// The late boundary (seconds), or `0.0` for a null handle. Wraps
/// [`PacerDepthPolicy::late_threshold_seconds`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_late_threshold_seconds(
    policy: *const AisdPacerDepthPolicy,
) -> f64 {
    unsafe {
        policy
            .as_ref()
            .map_or(0.0, |p| p.inner.late_threshold_seconds())
    }
}

/// Folds one decoded-frame submit at `now`. No-op on null. Wraps
/// [`PacerDepthPolicy::note_arrival`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_note_arrival(
    policy: *mut AisdPacerDepthPolicy,
    now: f64,
) {
    unsafe {
        if let Some(p) = policy.as_mut() {
            p.inner.note_arrival(now);
        }
    }
}

/// Folds one content present at `now` and returns its gap class as an `AISD_PACER_GAP_*`
/// discriminant. Returns First (`0`) for a null handle. Wraps [`PacerDepthPolicy::note_present`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_note_present(
    policy: *mut AisdPacerDepthPolicy,
    now: f64,
) -> u8 {
    unsafe {
        policy.as_mut().map_or(AISD_PACER_GAP_FIRST, |p| {
            pacer_gap_class_to_c(p.inner.note_present(now))
        })
    }
}

/// Folds one NETWORK-late event at `now`. No-op on null. Wraps
/// [`PacerDepthPolicy::note_network_late`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_note_network_late(
    policy: *mut AisdPacerDepthPolicy,
    now: f64,
) {
    unsafe {
        if let Some(p) = policy.as_mut() {
            p.inner.note_network_late(now);
        }
    }
}

/// Folds one empty re-show at `now`. No-op on null. Wraps [`PacerDepthPolicy::note_reshow`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_note_reshow(
    policy: *mut AisdPacerDepthPolicy,
    now: f64,
) {
    unsafe {
        if let Some(p) = policy.as_mut() {
            p.inner.note_reshow(now);
        }
    }
}

/// Drains (and resets) the windowed counters. Returns `{0, 0}` for a null handle. Wraps
/// [`PacerDepthPolicy::drain_counters`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_drain_counters(
    policy: *mut AisdPacerDepthPolicy,
) -> AisdPacerCounters {
    unsafe {
        policy.as_mut().map_or(
            AisdPacerCounters {
                late_frames: 0,
                present_gaps: 0,
            },
            |p| {
                let (late_frames, present_gaps) = p.inner.drain_counters();
                AisdPacerCounters {
                    late_frames,
                    present_gaps,
                }
            },
        )
    }
}

/// Sets (or clears) the FPS-governor interval hint. `has_hint == 0` clears it; otherwise the hint is
/// `seconds`. No-op on null. Wraps [`PacerDepthPolicy::set_interval_hint`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_pacer_depth_policy_set_interval_hint(
    policy: *mut AisdPacerDepthPolicy,
    seconds: f64,
    has_hint: u8,
) {
    unsafe {
        if let Some(p) = policy.as_mut() {
            p.inner
                .set_interval_hint(if has_hint != 0 { Some(seconds) } else { None });
        }
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    fn pacer_default_config() -> AisdPacerDepthConfig {
        let c = PacerDepthConfig::default();
        AisdPacerDepthConfig {
            late_gap_factor: c.late_gap_factor,
            absolute_late_floor_seconds: c.absolute_late_floor_seconds,
            idle_gap_seconds: c.idle_gap_seconds,
            gap_gradient_factor: c.gap_gradient_factor,
            dense_min_arrivals: c.dense_min_arrivals,
            dense_window_seconds: c.dense_window_seconds,
            late_slack_fraction: c.late_slack_fraction,
            promote_late_count: c.promote_late_count,
            promote_window_seconds: c.promote_window_seconds,
            demote_clean_seconds: c.demote_clean_seconds,
            min_hold_seconds: c.min_hold_seconds,
            demote_tolerance_lates: c.demote_tolerance_lates,
            promote_warmup_seconds: c.promote_warmup_seconds,
            boost_depth: c.boost_depth,
            interval_ring_size: c.interval_ring_size,
            min_samples_for_estimate: c.min_samples_for_estimate,
            default_interval_seconds: c.default_interval_seconds,
            min_interval_seconds: c.min_interval_seconds,
            max_interval_seconds: c.max_interval_seconds,
        }
    }

    #[test]
    fn pacer_depth_policy_handle_promotes_and_drains() {
        unsafe {
            let p = aisd_pacer_depth_policy_new(pacer_default_config(), 1);
            assert!(!p.is_null());
            // Default depth is 1, config round-trips through to_core. Before the estimator warms,
            // expected interval = default 1/60s, so late boundary =
            // max(0.028, 1.6×1/60) + 0.25×1/60 = 0.028 + 0.25/60.
            assert_eq!(aisd_pacer_depth_policy_depth(p), 1);
            let expected_late = 0.028 + 0.25 / 60.0;
            assert!(
                (aisd_pacer_depth_policy_late_threshold_seconds(p) - expected_late).abs() < 1e-6
            );
            // Warm past the promote-warmup window (2.0s), then two network-late events within the
            // 1.0s promote window promote to boost depth 2.
            aisd_pacer_depth_policy_note_arrival(p, 0.0);
            aisd_pacer_depth_policy_note_network_late(p, 3.0);
            assert_eq!(aisd_pacer_depth_policy_depth(p), 1); // one late never promotes
            aisd_pacer_depth_policy_note_network_late(p, 3.2);
            assert_eq!(aisd_pacer_depth_policy_depth(p), 2); // 2nd within the window promotes
            // The counters drained reflect the two late events (1 episode each).
            let counters = aisd_pacer_depth_policy_drain_counters(p);
            assert_eq!(counters.late_frames, 2);
            // A second drain is empty.
            let again = aisd_pacer_depth_policy_drain_counters(p);
            assert_eq!(again.late_frames, 0);
            assert_eq!(again.present_gaps, 0);
            // The interval hint overrides the estimator.
            aisd_pacer_depth_policy_set_interval_hint(p, 1.0 / 30.0, 1);
            assert!(
                (aisd_pacer_depth_policy_expected_interval_seconds(p) - 1.0 / 30.0).abs() < 1e-9
            );
            aisd_pacer_depth_policy_set_interval_hint(p, 0.0, 0); // clear

            // note_present classifies; the first present is First.
            assert_eq!(
                aisd_pacer_depth_policy_note_present(p, 10.0),
                AISD_PACER_GAP_FIRST
            );

            aisd_pacer_depth_policy_free(p);
            aisd_pacer_depth_policy_free(core::ptr::null_mut()); // no-op
            // Null handle: depth 1, First, empty counters.
            assert_eq!(aisd_pacer_depth_policy_depth(core::ptr::null()), 1);
            assert_eq!(
                aisd_pacer_depth_policy_note_present(core::ptr::null_mut(), 0.0),
                AISD_PACER_GAP_FIRST
            );
            let null_counters = aisd_pacer_depth_policy_drain_counters(core::ptr::null_mut());
            assert_eq!(null_counters.late_frames, 0);
            assert_eq!(null_counters.present_gaps, 0);
        }
    }
}
