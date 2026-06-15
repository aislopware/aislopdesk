//! The `LiveCongestionController` control-law `impl` — initialisers, accessors, and the canonical
//! AIMD `decide`/`decide_inner` fold over a [`NetworkEstimate`].

use super::{
    CATASTROPHIC_LOSS_THRESHOLD, CUT_HOLD_TICKS, CutReason, DECREASE_FACTOR, Decision,
    GRADIENT_CUT_ENABLED_DEFAULT, GRADIENT_DECREASE_FACTOR, HOLD_TICKS, INCREASE_DIVISOR,
    KNEE_CAUTION_DIVISOR, KNEE_TTL_TICKS, LOSS_NEEDS_RTT_CORROBORATION, LOSS_THRESHOLD,
    LiveCongestionController, MATERIAL_FLOOR_BPS, MATERIAL_FRACTION, MIN_FRAC, MINIMUM_BITRATE,
    NetworkEstimate, RTT_DECREASE_CAP_FACTOR, RTT_DECREASE_FLOOR_FACTOR, RTT_INFLATE_FACTOR,
    RTT_STREAK_TICKS, SEVERE_DECREASE_FACTOR, SEVERE_LOSS_THRESHOLD, WARMUP_TICKS,
    effective_slack_millis,
};

impl LiveCongestionController {
    /// Primary initialiser. `floor` is clamped to `[MINIMUM_BITRATE, ceiling]`; `current` starts at
    /// `ceiling`.
    #[must_use]
    pub fn with_floor(ceiling: i64, floor: i64, gradient_cut_enabled: bool) -> Self {
        let c = ceiling.max(1);
        Self {
            ceiling: c,
            floor: MINIMUM_BITRATE.max(floor.min(c)),
            gradient_cut_enabled,
            current: c,
            ticks: 0,
            hold_until_tick: 0,
            rtt_inflated_streak: 0,
            cut_hold_until_tick: 0,
            prev_smoothed_rtt_millis: 0.0,
            knee_bps: None,
            knee_expires_at_tick: 0,
        }
    }

    /// Derives the floor from `ceiling × MIN_FRAC` with the given gradient-cut flag.
    #[must_use]
    pub fn with_gradient_cut(ceiling: i64, gradient_cut_enabled: bool) -> Self {
        let floor = (ceiling.max(1) as f64 * MIN_FRAC) as i64;
        Self::with_floor(ceiling, floor, gradient_cut_enabled)
    }

    /// Production wiring: derives the floor from `ceiling × MIN_FRAC`, gradient cut off by default.
    #[must_use]
    pub fn new(ceiling: i64) -> Self {
        Self::with_gradient_cut(ceiling, GRADIENT_CUT_ENABLED_DEFAULT)
    }

    /// The hard upper bound the controller can never exceed.
    #[must_use]
    pub const fn ceiling(&self) -> i64 {
        self.ceiling
    }
    /// The lowest the controller may drive the live rate (≥ [`MINIMUM_BITRATE`], ≤ `ceiling`).
    #[must_use]
    pub const fn floor(&self) -> i64 {
        self.floor
    }
    /// Whether the delay-gradient early-cut path is armed.
    #[must_use]
    pub const fn gradient_cut_enabled(&self) -> bool {
        self.gradient_cut_enabled
    }
    /// Current target bitrate (bps).
    #[must_use]
    pub const fn current(&self) -> i64 {
        self.current
    }
    /// Folded-report count — the controller's clock.
    #[must_use]
    pub const fn ticks(&self) -> i64 {
        self.ticks
    }
    /// Tick until which no increase is permitted (set on every decrease).
    #[must_use]
    pub const fn hold_until_tick(&self) -> i64 {
        self.hold_until_tick
    }
    /// The remembered knee (ssthresh), if any.
    #[must_use]
    pub const fn knee_bps(&self) -> Option<i64> {
        self.knee_bps
    }

    /// Additive-increase step in bps (≥ 1 so a tiny ceiling still makes progress).
    fn increase_step(&self) -> i64 {
        (self.ceiling / INCREASE_DIVISOR).max(1)
    }

    /// Folds one network estimate and returns the (possibly unchanged) new target bitrate.
    pub fn on_report(&mut self, e: &NetworkEstimate) -> i64 {
        self.decide(e).target
    }

    /// Folds one network estimate and returns the new target bitrate PLUS the attributed reason.
    pub fn decide(&mut self, e: &NetworkEstimate) -> Decision {
        self.ticks += 1;
        let decision = self.decide_inner(e);
        // The Swift shell's `defer { prevSmoothedRTTMillis = e.smoothedRTTMillis }` matches this: captured for
        // the NEXT report whatever branch ran (including warmup).
        self.prev_smoothed_rtt_millis = e.smoothed_rtt_millis();
        decision
    }

    #[allow(clippy::too_many_lines)] // the canonical control law
    fn decide_inner(&mut self, e: &NetworkEstimate) -> Decision {
        if self.ticks < WARMUP_TICKS {
            return Decision {
                target: self.current,
                reason: CutReason::Warmup,
            };
        }

        let slack = effective_slack_millis(e.min_rtt_millis());
        let rtt_inflated = e.min_rtt_millis().is_finite()
            && e.smoothed_rtt_millis() > e.min_rtt_millis() * RTT_INFLATE_FACTOR
            && e.smoothed_rtt_millis() > e.min_rtt_millis() + slack;
        self.rtt_inflated_streak = if rtt_inflated {
            self.rtt_inflated_streak + 1
        } else {
            0
        };
        let rtt_congested = rtt_inflated
            && self.rtt_inflated_streak >= RTT_STREAK_TICKS
            && self.ticks >= self.cut_hold_until_tick
            && e.smoothed_rtt_millis() + 1.0 >= self.prev_smoothed_rtt_millis;

        // Knee TTL: forget a knee not re-confirmed within `KNEE_TTL_TICKS`.
        if self.knee_bps.is_some() && self.ticks >= self.knee_expires_at_tick {
            self.knee_bps = None;
        }

        let loss_evidence = !LOSS_NEEDS_RTT_CORROBORATION || rtt_inflated;
        let loss_congested = e.last_loss_sample() > LOSS_THRESHOLD
            && loss_evidence
            && self.ticks >= self.cut_hold_until_tick;
        let raw_rtt_inflated = match e.last_rtt_sample_millis() {
            Some(raw) if e.min_rtt_millis().is_finite() => {
                raw > e.min_rtt_millis() * RTT_INFLATE_FACTOR && raw > e.min_rtt_millis() + slack
            }
            _ => false,
        };
        let gradient_congested = self.gradient_cut_enabled
            && e.owd_trend_overusing()
            && raw_rtt_inflated
            && self.ticks >= self.cut_hold_until_tick;

        if e.loss_rate() > CATASTROPHIC_LOSS_THRESHOLD
            && e.last_loss_sample() > SEVERE_LOSS_THRESHOLD
            && self.ticks >= self.hold_until_tick
        {
            let target = self
                .floor
                .max((self.current as f64 * SEVERE_DECREASE_FACTOR) as i64);
            self.decrease(target, rtt_inflated);
            return Decision {
                target: self.current,
                reason: CutReason::Catastrophic,
            };
        } else if rtt_congested || loss_congested || gradient_congested {
            let mut target = i64::MAX;
            let mut reason = CutReason::Hold; // overwritten — at least one branch fired
            if rtt_congested {
                let drained = e.min_rtt_millis() + slack;
                let factor = RTT_DECREASE_CAP_FACTOR
                    .min(RTT_DECREASE_FLOOR_FACTOR.max(drained / e.smoothed_rtt_millis()));
                let cut = (self.current as f64 * factor) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::RttStreak;
                }
            }
            if loss_congested {
                let cut = (self.current as f64 * DECREASE_FACTOR) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::LossCorroborated;
                }
            }
            if gradient_congested {
                let cut = (self.current as f64 * GRADIENT_DECREASE_FACTOR) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::Gradient;
                }
            }
            self.decrease(self.floor.max(target), rtt_inflated);
            return Decision {
                target: self.current,
                reason,
            };
        } else if self.ticks >= self.hold_until_tick
            && !rtt_inflated
            && !(self.gradient_cut_enabled && e.owd_trend_overusing())
        {
            let cautious = self.knee_bps.is_some_and(|knee| self.current >= knee);
            let step = if cautious {
                (self.increase_step() / KNEE_CAUTION_DIVISOR).max(1)
            } else {
                self.increase_step()
            };
            self.current = self.ceiling.min(self.current + step);
            return Decision {
                target: self.current,
                reason: if cautious {
                    CutReason::Knee
                } else {
                    CutReason::Probe
                },
            };
        }
        let drain_gated = rtt_inflated
            && self.rtt_inflated_streak >= RTT_STREAK_TICKS
            && self.ticks >= self.cut_hold_until_tick
            && e.smoothed_rtt_millis() + 1.0 < self.prev_smoothed_rtt_millis;
        Decision {
            target: self.current,
            reason: if drain_gated {
                CutReason::Drain
            } else {
                CutReason::Hold
            },
        }
    }

    /// Applies a decrease and arms the hold-downs — but ONLY when the target actually LOWERS
    /// `current` (a no-op at the floor must not keep extending the hold-down). A queue-corroborated
    /// decrease additionally records the landed-on rate as the knee.
    const fn decrease(&mut self, next: i64, queue_corroborated: bool) {
        if next < self.current {
            self.current = next;
            self.hold_until_tick = self.ticks + HOLD_TICKS;
            self.cut_hold_until_tick = self.ticks + CUT_HOLD_TICKS;
            self.rtt_inflated_streak = 0;
            if queue_corroborated {
                self.knee_bps = Some(self.current);
                self.knee_expires_at_tick = self.ticks + KNEE_TTL_TICKS;
            }
        }
    }

    /// Whether a target change is large enough to be worth a re-actuation (≥ `MATERIAL_FRACTION`
    /// of the ceiling OR ≥ `MATERIAL_FLOOR_BPS`).
    #[must_use]
    pub fn is_material_change(previous: i64, target: i64, ceiling: i64) -> bool {
        (target - previous).abs()
            >= MATERIAL_FLOOR_BPS.max((ceiling.max(1) as f64 * MATERIAL_FRACTION) as i64)
    }
}
