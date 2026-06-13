//! Clock-skew-free network estimate — a port of Swift `NetworkEstimate`.
//!
//! The host folds the client's periodic `NetworkStatsReport` into EWMA-smoothed RTT, a windowed
//! min-RTT baseline, an EWMA loss rate plus the raw per-report loss sample, an OWD-jitter rising
//! flag, and the client trendline's overuse verdict. [`LiveCongestionController`](crate::live_congestion_controller)
//! consumes this estimate. Pure value type — every input is injected; the RTT computation is
//! wrap-safe over the `u32` host clock.

use crate::seq::distance_wrapped;

/// EWMA weight on a fresh RTT sample (0.125 → 7/8 history, RFC6298-style).
pub const RTT_ALPHA: f64 = 0.125;
/// EWMA weight on a fresh loss sample.
pub const LOSS_ALPHA: f64 = 0.125;
/// Slow re-baseline factor for `min_rtt_millis` so a transient low sample doesn't pin it forever.
pub const MIN_RTT_DECAY: f64 = 0.01;
/// RTT samples above this (ms) are implausible — dropped rather than poisoning the EWMA.
pub const MAX_PLAUSIBLE_RTT_MILLIS: i64 = 60_000;

/// A folded snapshot of recent path conditions. `Copy` value type; [`PartialEq`] (f64 fields).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetworkEstimate {
    smoothed_rtt_millis: f64,
    min_rtt_millis: f64,
    loss_rate: f64,
    last_loss_sample: f64,
    owd_gradient_rising: bool,
    owd_trend_overusing: bool,
    owd_trend_modified: f64,
    last_rtt_sample_millis: Option<f64>,
    last_owd_jitter_micros: u32,
    sample_count: u64,
}

impl Default for NetworkEstimate {
    fn default() -> Self {
        Self::new()
    }
}

impl NetworkEstimate {
    /// A fresh estimate: smoothed RTT 0, min RTT `+∞`, no samples folded.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            smoothed_rtt_millis: 0.0,
            min_rtt_millis: f64::INFINITY,
            loss_rate: 0.0,
            last_loss_sample: 0.0,
            owd_gradient_rising: false,
            owd_trend_overusing: false,
            owd_trend_modified: 0.0,
            last_rtt_sample_millis: None,
            last_owd_jitter_micros: 0,
            sample_count: 0,
        }
    }

    /// EWMA-smoothed RTT (ms). 0 until the first valid sample folds.
    #[must_use]
    pub const fn smoothed_rtt_millis(&self) -> f64 {
        self.smoothed_rtt_millis
    }

    /// Windowed minimum RTT (ms) — the path's no-queue baseline. `+∞` until the first sample.
    #[must_use]
    pub const fn min_rtt_millis(&self) -> f64 {
        self.min_rtt_millis
    }

    /// EWMA loss rate in `[0, 1]` (retained for telemetry trend; the controller keys on the raw
    /// [`last_loss_sample`](Self::last_loss_sample) except for the catastrophic gate).
    #[must_use]
    pub const fn loss_rate(&self) -> f64 {
        self.loss_rate
    }

    /// Raw per-report loss fraction from the MOST RECENT fold, in `[0, 1]`.
    #[must_use]
    pub const fn last_loss_sample(&self) -> f64 {
        self.last_loss_sample
    }

    /// Whether the most recent OWD-jitter sample rose vs the previous (a congestion-onset hint).
    #[must_use]
    pub const fn owd_gradient_rising(&self) -> bool {
        self.owd_gradient_rising
    }

    /// Whether the client trendline detector read OVERUSING on the most recent report.
    #[must_use]
    pub const fn owd_trend_overusing(&self) -> bool {
        self.owd_trend_overusing
    }

    /// The detector's modified trend (ms-of-delay per ms) from the most recent report — diagnostics.
    #[must_use]
    pub const fn owd_trend_modified(&self) -> f64 {
        self.owd_trend_modified
    }

    /// The raw (un-smoothed) RTT sample of the MOST RECENT fold — the gradient cut's fresh level
    /// corroboration. `None` when that report's sample was rejected.
    #[must_use]
    pub const fn last_rtt_sample_millis(&self) -> Option<f64> {
        self.last_rtt_sample_millis
    }

    /// Wrap-safe host-clock RTT (ms), or `None` to REJECT the sample. Rejects when telemetry is off
    /// (`latest_host_send_ts == 0`), the stamp is in the future, the hold exceeds the elapsed, or
    /// the result is implausibly large.
    #[must_use]
    pub fn compute_rtt_millis(
        host_now_ms: u32,
        latest_host_send_ts: u32,
        client_hold_ms: u32,
    ) -> Option<i64> {
        if latest_host_send_ts == 0 {
            return None;
        }
        // Wrap-aware delta (same trick as `distance_wrapped`): a counter that wrapped between the
        // stamp and now still yields the correct small positive elapsed.
        let elapsed = i64::from(distance_wrapped(host_now_ms, latest_host_send_ts));
        if elapsed < 0 {
            return None;
        }
        let rtt = elapsed - i64::from(client_hold_ms);
        if !(0..=MAX_PLAUSIBLE_RTT_MILLIS).contains(&rtt) {
            return None;
        }
        Some(rtt)
    }

    /// Folds one report (no trend evidence — `owd_trend_state = 0`).
    pub fn fold(
        &mut self,
        rtt_millis: Option<i64>,
        frames_received: u32,
        unrecovered: u32,
        owd_jitter_micros: u32,
    ) {
        self.fold_with_trend(
            rtt_millis,
            frames_received,
            unrecovered,
            owd_jitter_micros,
            0,
            0,
        );
    }

    /// Folds one report. `rtt_millis == None` (rejected) skips the RTT/min-RTT update but still
    /// folds loss + jitter. `owd_trend_state == 1` marks OVERUSING; `owd_trend_modified_milli` is
    /// the detector's modified trend in milli-units.
    pub fn fold_with_trend(
        &mut self,
        rtt_millis: Option<i64>,
        frames_received: u32,
        unrecovered: u32,
        owd_jitter_micros: u32,
        owd_trend_state: u8,
        owd_trend_modified_milli: i32,
    ) {
        self.last_rtt_sample_millis = rtt_millis.map(|r| r as f64);
        self.owd_trend_overusing = owd_trend_state == 1;
        self.owd_trend_modified = f64::from(owd_trend_modified_milli) / 1000.0;
        if let Some(rtt) = rtt_millis {
            let sample = rtt as f64;
            self.smoothed_rtt_millis = if self.smoothed_rtt_millis == 0.0 {
                sample
            } else {
                self.smoothed_rtt_millis * (1.0 - RTT_ALPHA) + sample * RTT_ALPHA
            };
            if sample < self.min_rtt_millis {
                self.min_rtt_millis = sample;
            } else if self.min_rtt_millis.is_finite() {
                // Slow re-baseline so a one-off low doesn't pin the baseline below the real RTT.
                self.min_rtt_millis += (sample - self.min_rtt_millis) * MIN_RTT_DECAY;
            }
        }
        // Loss rate: guard divide-by-zero (a report with 0 frames received contributes a 0 sample).
        let loss_sample = if frames_received > 0 {
            f64::from(unrecovered) / f64::from(frames_received)
        } else {
            0.0
        };
        self.last_loss_sample = loss_sample;
        self.loss_rate = self.loss_rate * (1.0 - LOSS_ALPHA) + loss_sample * LOSS_ALPHA;
        // OWD gradient: only meaningful after a short warmup (the first sample has no predecessor).
        if self.sample_count >= 2 {
            self.owd_gradient_rising = owd_jitter_micros > self.last_owd_jitter_micros;
        }
        self.last_owd_jitter_micros = owd_jitter_micros;
        self.sample_count += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compute_rtt_rejects_telemetry_off_and_implausible() {
        // latest_host_send_ts == 0 → telemetry off.
        assert_eq!(NetworkEstimate::compute_rtt_millis(100, 0, 0), None);
        // stamp in the future (now before send) → negative elapsed.
        assert_eq!(NetworkEstimate::compute_rtt_millis(100, 200, 0), None);
        // hold exceeds elapsed → negative rtt.
        assert_eq!(NetworkEstimate::compute_rtt_millis(150, 100, 60), None);
        // implausibly large.
        assert_eq!(NetworkEstimate::compute_rtt_millis(100_000, 1, 0), None);
        // a normal sample: elapsed 50, hold 10 → rtt 40.
        assert_eq!(NetworkEstimate::compute_rtt_millis(150, 100, 10), Some(40));
    }

    #[test]
    fn compute_rtt_is_wrap_safe() {
        // host clock wrapped: now = 5, send = u32::MAX - 4 → elapsed 10, hold 0 → rtt 10.
        assert_eq!(
            NetworkEstimate::compute_rtt_millis(5, u32::MAX - 4, 0),
            Some(10)
        );
    }

    #[test]
    fn first_rtt_seeds_and_min_baseline() {
        let mut e = NetworkEstimate::new();
        assert_eq!(e.smoothed_rtt_millis(), 0.0);
        assert!(e.min_rtt_millis().is_infinite());
        e.fold(Some(50), 1000, 0, 100);
        assert_eq!(e.smoothed_rtt_millis(), 50.0); // first sample seeds exactly
        assert_eq!(e.min_rtt_millis(), 50.0);
        assert_eq!(e.last_rtt_sample_millis(), Some(50.0));
    }

    #[test]
    fn rtt_ewma_and_min_rebaseline() {
        let mut e = NetworkEstimate::new();
        e.fold(Some(50), 1000, 0, 100);
        e.fold(Some(100), 1000, 0, 100);
        // 50*0.875 + 100*0.125 = 56.25.
        assert!((e.smoothed_rtt_millis() - 56.25).abs() < 1e-9);
        // min re-baselines up slowly: 50 + (100-50)*0.01 = 50.5.
        assert!((e.min_rtt_millis() - 50.5).abs() < 1e-9);
    }

    #[test]
    fn loss_raw_vs_ewma() {
        let mut e = NetworkEstimate::new();
        e.fold(Some(50), 1000, 1000, 100); // 100% raw loss
        assert_eq!(e.last_loss_sample(), 1.0);
        assert!((e.loss_rate() - 0.125).abs() < 1e-9); // EWMA only to 12.5%
        e.fold(Some(50), 1000, 0, 100); // clean
        assert_eq!(e.last_loss_sample(), 0.0); // raw resets immediately
        assert!(e.loss_rate() > 0.0); // EWMA tail lingers
    }

    #[test]
    fn rejected_rtt_skips_rtt_but_folds_loss() {
        let mut e = NetworkEstimate::new();
        e.fold(None, 1000, 0, 100);
        assert_eq!(e.smoothed_rtt_millis(), 0.0);
        assert!(e.min_rtt_millis().is_infinite());
        assert_eq!(e.last_rtt_sample_millis(), None);
        assert_eq!(e.last_loss_sample(), 0.0);
    }

    #[test]
    fn trend_fields_fold() {
        let mut e = NetworkEstimate::new();
        e.fold_with_trend(Some(50), 1000, 0, 100, 1, 80_000);
        assert!(e.owd_trend_overusing());
        assert!((e.owd_trend_modified() - 80.0).abs() < 1e-9);
    }
}
