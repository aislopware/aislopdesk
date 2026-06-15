//! AIMD congestion controller for the live HEVC stream — the canonical `LiveCongestionController`
//! (WF-2 adaptive bitrate; the Swift shell mirrors it).
//!
//! Additive-Increase / Multiplicative-Decrease over the folded [`NetworkEstimate`]: on congestion
//! (raw loss over threshold WITH RTT corroboration, or sustained RTT inflation, or an enabled
//! delay-gradient onset) the target DROPS multiplicatively; on a clean link past the hold-down it
//! CLIMBS additively. Sustained catastrophic loss halves. Pure + deterministic — "time" is the
//! count of folded reports (`ticks`).
//!
//! Key stability properties: loss keys on the RAW
//! per-report sample (no EWMA-tail cascade); RTT needs both a multiplicative factor AND an absolute
//! (baseline-proportional) slack, sustained for a streak, and a not-improving trend; ONE
//! multiplicative cut per `cut_hold_ticks` window (loss included); RTT cuts are PROPORTIONAL to the
//! measured queue; a queue-corroborated cut remembers the knee (ssthresh) and climbs cautiously
//! above it.
//!
//! Tunables: the Swift shell resolves these from `AISLOPDESK_ABR_*` env vars at startup; this core
//! uses the compile-time defaults below (identical to the shell's values when no env override is set;
//! the configuration these tests and golden vectors exercise).

use crate::live_bitrate_policy::MINIMUM_BITRATE;
use crate::network_estimate::NetworkEstimate;

mod controller;
#[cfg(test)]
mod tests;

/// Reports to fold before ANY action — the cold-start guard.
pub const WARMUP_TICKS: i64 = 10;
/// Raw per-report loss above which the link is "congested" → multiplicative decrease.
pub const LOSS_THRESHOLD: f64 = 0.02;
/// Raw per-report loss above which a catastrophic report's CURRENT sample still counts as severe.
pub const SEVERE_LOSS_THRESHOLD: f64 = 0.10;
/// Whether sub-catastrophic loss decreases only when RTT-corroborated (Swift default: true).
pub const LOSS_NEEDS_RTT_CORROBORATION: bool = true;
/// EWMA loss-rate above which the controller halves even at flat RTT (true collapse / policer).
pub const CATASTROPHIC_LOSS_THRESHOLD: f64 = 0.25;
/// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%).
pub const DECREASE_FACTOR: f64 = 0.85;
/// Multiplicative decrease factor on catastrophic loss (0.5 = halve).
pub const SEVERE_DECREASE_FACTOR: f64 = 0.5;
/// Additive-increase step = `ceiling / increase_divisor` per clean tick.
pub const INCREASE_DIVISOR: i64 = 32;
/// Reports to suppress any increase after a decrease — the anti-thrash hold-down.
pub const HOLD_TICKS: i64 = 20;
/// `smoothed_rtt > min_rtt × rtt_inflate_factor` (AND past the slack) signals queue build-up.
pub const RTT_INFLATE_FACTOR: f64 = 1.25;
/// Absolute smoothed-RTT inflation over the baseline (ms) ALSO required before the RTT path acts.
pub const RTT_SLACK_MILLIS: f64 = 15.0;
/// Baseline-proportional slack: the effective slack is `max(rtt_slack_millis, fraction × min_rtt)`.
pub const RTT_SLACK_FRACTION: f64 = 0.75;
/// Consecutive inflated reports required before the RTT path decreases.
pub const RTT_STREAK_TICKS: i64 = 3;
/// Reports between ANY multiplicative decreases — RTT-path AND loss-path.
pub const CUT_HOLD_TICKS: i64 = 8;
/// Hardest single proportional RTT decrease (0.6 = at most −40% in one step).
pub const RTT_DECREASE_FLOOR_FACTOR: f64 = 0.6;
/// Gentlest proportional RTT decrease (0.95 = −5%).
pub const RTT_DECREASE_CAP_FACTOR: f64 = 0.95;
/// Additive divisor applied ON TOP of `increase_divisor` at/above the remembered knee.
pub const KNEE_CAUTION_DIVISOR: i64 = 8;
/// Reports the knee memory survives without a fresh queue-corroborated decrease.
pub const KNEE_TTL_TICKS: i64 = 1200;
/// Floor as a fraction of the ceiling (also clamped to [`MINIMUM_BITRATE`]).
pub const MIN_FRAC: f64 = 0.25;
/// Actuation churn gate (fraction of ceiling).
pub const MATERIAL_FRACTION: f64 = 0.05;
/// Actuation churn gate (absolute bps floor).
pub const MATERIAL_FLOOR_BPS: i64 = 500_000;
/// Whether the delay-gradient early-cut path is armed by default (Swift default: false).
pub const GRADIENT_CUT_ENABLED_DEFAULT: bool = false;
/// Multiplicative factor for a gradient-authorized cut.
pub const GRADIENT_DECREASE_FACTOR: f64 = 0.85;

/// The effective absolute-slack gate for a given path baseline.
#[must_use]
pub fn effective_slack_millis(min_rtt_millis: f64) -> f64 {
    if min_rtt_millis.is_finite() {
        RTT_SLACK_MILLIS.max(RTT_SLACK_FRACTION * min_rtt_millis)
    } else {
        RTT_SLACK_MILLIS
    }
}

/// Why the controller moved (or held) this tick — observability only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CutReason {
    /// Cold-start guard — no action possible.
    Warmup,
    /// No branch fired (sub-threshold / hold-down) — target unchanged.
    Hold,
    /// Fully-armed RTT cut held because the smoothed RTT is improving (the queue is draining).
    Drain,
    /// Additive increase (the normal probe step toward the ceiling).
    Probe,
    /// Additive increase at/above the remembered knee — the cautious step.
    Knee,
    /// Proportional RTT (delay-targeting) cut — sustained smoothed-RTT inflation streak.
    RttStreak,
    /// Loss-corroborated cut — raw loss over the threshold WITH RTT-inflation evidence.
    LossCorroborated,
    /// Delay-gradient early cut — client trendline OVERUSING + raw-RTT corroboration.
    Gradient,
    /// EWMA-keyed catastrophic halve (sustained ≥ catastrophic loss).
    Catastrophic,
}

/// One control-law tick's outcome: the new target plus why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Decision {
    /// The new target bitrate (bps), within `[floor, ceiling]`.
    pub target: i64,
    /// The branch that set the final target.
    pub reason: CutReason,
}

/// Pure AIMD congestion controller. `Copy` value type; [`PartialEq`] (f64 fields).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveCongestionController {
    ceiling: i64,
    floor: i64,
    gradient_cut_enabled: bool,
    current: i64,
    ticks: i64,
    hold_until_tick: i64,
    rtt_inflated_streak: i64,
    cut_hold_until_tick: i64,
    prev_smoothed_rtt_millis: f64,
    knee_bps: Option<i64>,
    knee_expires_at_tick: i64,
}
