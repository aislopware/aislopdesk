//! Link-adaptive constant-QP controller (own rate control, 2026-06-18).
//!
//! `VideoToolbox`'s `AverageBitRate` VBR banks unused budget while the screen is idle, then SLAMS the
//! QP on the frames after a post-idle burst (the "idle → hard-scroll → blur" clawback). Pinning a
//! CONSTANT QP per frame removes that clawback — but a fixed QP can't adapt when the link degrades.
//! This is the missing adaptation: a small integer AIMD that drives the constant QP from the link's
//! own congestion verdict.
//!
//! ## The law (AIMD on QP — note QP is inverse quality, so the senses flip)
//!
//! - **Congested** (the host's loss/RTT verdict): RAISE Q by [`up_step`](QpConfig::up_step) toward
//!   [`q_coarse`](QpConfig::q_coarse) — coarser → smaller frames → fits the degraded link. Fast, like
//!   AIMD's multiplicative *decrease* of quality.
//! - **Clean**: every [`down_interval`](QpConfig::down_interval) clean reports, lower Q by 1 toward
//!   [`q_sharp`](QpConfig::q_sharp) — sharper, additively/slowly. Like AIMD's additive *increase*.
//!
//! So a clean link settles at the sharpest allowed QP and a congesting link coarsens promptly, then
//! eases back sharp — without VT's per-frame VBR clawback. Pure + integer: deterministic, no float
//! divergence, unit-testable to the value. The Swift shell mirrors it (`QPController.swift`).

/// The tunable shape of the QP AIMD. `q_sharp <= q_coarse`; both clamped to the HEVC range `1..=51`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QpConfig {
    /// Sharpest (lowest) QP the controller will settle to on a clean link.
    pub q_sharp: i32,
    /// Coarsest (highest) QP it will rise to under sustained congestion.
    pub q_coarse: i32,
    /// QP increase per congested report (coarsen fast).
    pub up_step: i32,
    /// Clean reports required to sharpen by one QP (ease back slowly).
    pub down_interval: i32,
}

impl QpConfig {
    /// Clamps every field to a sane range so a hostile env value can never invert or escape the QP
    /// range: QPs into `1..=51` with `q_sharp <= q_coarse`, `up_step >= 1`, `down_interval >= 1`.
    #[must_use]
    pub fn sanitized(q_sharp: i32, q_coarse: i32, up_step: i32, down_interval: i32) -> Self {
        let sharp = q_sharp.clamp(1, 51);
        let coarse = q_coarse.clamp(sharp, 51);
        Self {
            q_sharp: sharp,
            q_coarse: coarse,
            up_step: up_step.max(1),
            down_interval: down_interval.max(1),
        }
    }
}

/// The integer AIMD-on-QP state.
///
/// Drive it once per network report with [`decide`](QpController::decide); read the current QP with
/// [`current`](QpController::current). One per session; not thread-safe (the caller's actor serialises
/// it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QpController {
    config: QpConfig,
    q: i32,
    clean_streak: i32,
}

impl QpController {
    /// Creates a controller seeded at `seed_q` (clamped into `[q_sharp, q_coarse]`).
    #[must_use]
    pub fn new(config: QpConfig, seed_q: i32) -> Self {
        Self {
            config,
            q: seed_q.clamp(config.q_sharp, config.q_coarse),
            clean_streak: 0,
        }
    }

    /// The current constant QP to apply to the encoder.
    #[must_use]
    pub const fn current(&self) -> i32 {
        self.q
    }

    /// Folds one report's congestion verdict and returns the (possibly unchanged) new QP.
    ///
    /// `congested` is the host's verdict for this report (e.g. the ABR controller cut for loss/RTT).
    /// Congested → coarsen fast toward `q_coarse`; clean → sharpen one step per `down_interval` clean
    /// reports toward `q_sharp`.
    pub fn decide(&mut self, congested: bool) -> i32 {
        if congested {
            self.q = (self.q + self.config.up_step).min(self.config.q_coarse);
            self.clean_streak = 0;
        } else {
            self.clean_streak += 1;
            if self.clean_streak >= self.config.down_interval {
                self.q = (self.q - 1).max(self.config.q_sharp);
                self.clean_streak = 0;
            }
        }
        self.q
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> QpConfig {
        QpConfig::sanitized(26, 40, 3, 4)
    }

    #[test]
    fn seed_is_clamped_into_range() {
        assert_eq!(QpController::new(cfg(), 10).current(), 26); // below sharp → sharp
        assert_eq!(QpController::new(cfg(), 99).current(), 40); // above coarse → coarse
        assert_eq!(QpController::new(cfg(), 30).current(), 30);
    }

    #[test]
    fn congestion_coarsens_fast_and_clamps_to_coarse() {
        let mut c = QpController::new(cfg(), 26);
        assert_eq!(c.decide(true), 29); // +3
        assert_eq!(c.decide(true), 32);
        assert_eq!(c.decide(true), 35);
        assert_eq!(c.decide(true), 38);
        assert_eq!(c.decide(true), 40); // +3 → 41 clamped to q_coarse 40
        assert_eq!(c.decide(true), 40); // stays clamped
    }

    #[test]
    fn clean_sharpens_one_step_per_interval_and_clamps_to_sharp() {
        let mut c = QpController::new(cfg(), 40);
        // down_interval = 4: three clean reports do NOT yet sharpen.
        assert_eq!(c.decide(false), 40);
        assert_eq!(c.decide(false), 40);
        assert_eq!(c.decide(false), 40);
        assert_eq!(c.decide(false), 39); // 4th clean → −1
        for _ in 0..3 {
            assert_eq!(c.decide(false), 39);
        }
        assert_eq!(c.decide(false), 38); // next interval → −1
        // Drive it all the way down: it clamps at q_sharp 26 and never goes below.
        for _ in 0..200 {
            let _ = c.decide(false);
        }
        assert_eq!(c.current(), 26);
    }

    #[test]
    fn aimd_asymmetry_one_congested_outweighs_several_clean() {
        // The defining AIMD shape: a single congested report coarsens more than several clean reports
        // sharpen, so the controller reacts fast to congestion and recovers cautiously.
        let mut c = QpController::new(cfg(), 26);
        let _ = c.decide(true); // 26 → 29 (one congested = +3)
        assert_eq!(c.current(), 29);
        for _ in 0..3 {
            let _ = c.decide(false); // 3 clean < down_interval(4) → no change yet
        }
        assert_eq!(
            c.current(),
            29,
            "3 clean reports recover nothing; congestion dominates"
        );
    }

    #[test]
    fn congestion_resets_the_clean_streak() {
        let mut c = QpController::new(cfg(), 30);
        let _ = c.decide(false); // streak 1
        let _ = c.decide(false); // streak 2
        let _ = c.decide(true); // coarsen + streak reset → 33
        assert_eq!(c.current(), 33);
        // The two earlier clean reports were forgotten: need a fresh full interval to sharpen.
        let _ = c.decide(false);
        let _ = c.decide(false);
        let _ = c.decide(false);
        assert_eq!(c.current(), 33, "clean streak restarted after congestion");
        assert_eq!(c.decide(false), 32, "4th clean since the reset sharpens");
    }

    #[test]
    fn sanitized_clamps_hostile_config() {
        let c = QpConfig::sanitized(99, 5, 0, 0);
        assert_eq!(c.q_sharp, 51); // 99 clamped to 51
        assert_eq!(c.q_coarse, 51); // coarse clamped up to sharp
        assert_eq!(c.up_step, 1); // 0 → 1
        assert_eq!(c.down_interval, 1); // 0 → 1
    }
}
