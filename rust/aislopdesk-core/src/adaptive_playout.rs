//! Adaptive playout-delay policy for the client's deadline presentation pacer — sizes the
//! jitter-absorption buffer to the LIVE measured network jitter instead of a fixed constant.
//!
//! The deadline pacer presents frames on a content-rhythm clock with a small playout buffer; a
//! FIXED buffer is wrong across links — a clean LAN (tiny jitter) wastes latency while a jittery
//! WAN underruns and stutters. This policy maps a measured jitter scalar to a target buffer:
//! `clamp(k · jitter + base, [floor, ceil])` — so a clean link floats down to the floor (low
//! latency) and a jittery link inflates for smoothness, bounded by the ceiling so a pathological
//! link can never add unbounded lag. The WebRTC `VCMTiming` / Moonlight model.
//!
//! Pure scalar arithmetic in the SECONDS domain (no rounding until the caller displays ms). The
//! caller resolves the env knobs and passes them in, so the core stays deterministic — mirroring
//! [`crate::live_bitrate_policy`]. The hysteresis (grow-fast / shrink-slow) is a pure step over an
//! externally-held `prev`, so the whole law lives here while the Swift shell holds only the last
//! value.

/// Default coefficient on the measured jitter (slightly `< 1`).
///
/// The RFC3550 EWMA is a mean-deviation that underestimates the peak the buffer must cover, but
/// `+ base` and the smoothing make `0.8` sufficient at the validated link; raise toward `1.0` if a
/// link underruns.
pub const DEFAULT_K: f64 = 0.8;
/// Default constant floor term (seconds) added before the clamp, so a near-zero-jitter cold start
/// still seeds a real buffer (never present-on-arrival).
pub const DEFAULT_BASE_SECONDS: f64 = 0.004;
/// Default minimum playout (seconds). MUST stay `> 0` — a zero buffer exposes raw jitter to the eye.
pub const DEFAULT_FLOOR_SECONDS: f64 = 0.004;
/// Default maximum playout (seconds) — caps the latency a pathological link can add.
pub const DEFAULT_CEIL_SECONDS: f64 = 0.035;

/// The tunable shape of the playout law. All fields are in the seconds domain.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// Coefficient on measured jitter.
    pub k: f64,
    /// Constant term (seconds) added before the clamp.
    pub base_seconds: f64,
    /// Lower clamp bound (seconds).
    pub floor_seconds: f64,
    /// Upper clamp bound (seconds).
    pub ceil_seconds: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            k: DEFAULT_K,
            base_seconds: DEFAULT_BASE_SECONDS,
            floor_seconds: DEFAULT_FLOOR_SECONDS,
            ceil_seconds: DEFAULT_CEIL_SECONDS,
        }
    }
}

impl Config {
    /// Builds a config from millisecond knobs (the FFI / Swift path), clamping each to a sane band
    /// and guaranteeing `ceil >= floor`. A non-finite knob falls back to its default.
    #[must_use]
    pub fn from_ms(k: f64, base_ms: f64, floor_ms: f64, ceil_ms: f64) -> Self {
        let k = if k.is_finite() {
            k.clamp(0.0, 4.0)
        } else {
            DEFAULT_K
        };
        let base_seconds = if base_ms.is_finite() {
            (base_ms / 1000.0).clamp(0.0, 0.05)
        } else {
            DEFAULT_BASE_SECONDS
        };
        let floor_seconds = if floor_ms.is_finite() {
            (floor_ms / 1000.0).clamp(0.001, 0.05)
        } else {
            DEFAULT_FLOOR_SECONDS
        };
        let ceil_raw = if ceil_ms.is_finite() {
            (ceil_ms / 1000.0).clamp(0.001, 0.2)
        } else {
            DEFAULT_CEIL_SECONDS
        };
        Self {
            k,
            base_seconds,
            floor_seconds,
            ceil_seconds: ceil_raw.max(floor_seconds),
        }
    }
}

/// The TARGET playout (seconds) for a measured `jitter_seconds`.
///
/// `clamp(k·jitter + base, [floor, ceil])`. A non-finite or negative jitter falls back to the
/// floor (defensive: a bad sample must never inflate the buffer).
#[must_use]
pub fn target_seconds(jitter_seconds: f64, config: &Config) -> f64 {
    if !jitter_seconds.is_finite() || jitter_seconds < 0.0 {
        return config.floor_seconds;
    }
    (config.k * jitter_seconds + config.base_seconds)
        .clamp(config.floor_seconds, config.ceil_seconds)
}

/// One hysteretic step toward the target (grow-fast, shrink-slow).
///
/// GROW immediately to a larger target (re-inflate the instant jitter rises) but SHRINK by at most
/// `shrink_step_seconds` per call (so a transient spike decays back to the floor over several
/// recompute ticks instead of pinning the buffer high — the rule that prevents a latency ratchet).
/// `prev_seconds` is the current playout (externally held); a non-finite `prev` re-seeds at the floor.
#[must_use]
pub fn step_seconds(
    jitter_seconds: f64,
    prev_seconds: f64,
    shrink_step_seconds: f64,
    config: &Config,
) -> f64 {
    let target = target_seconds(jitter_seconds, config);
    let prev = if prev_seconds.is_finite() {
        prev_seconds.clamp(config.floor_seconds, config.ceil_seconds)
    } else {
        config.floor_seconds
    };
    if target >= prev {
        target // grow fast (also covers the cold start seeded at the floor)
    } else {
        let step = if shrink_step_seconds.is_finite() {
            shrink_step_seconds.max(0.0)
        } else {
            0.0
        };
        (prev - step).max(target) // shrink slow
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn clean_lan_floats_to_floor() {
        // ~2ms jitter → 0.8*2 + 4 = 5.6ms, above the 4ms floor.
        assert!(approx(target_seconds(0.002, &Config::default()), 0.0056));
    }

    #[test]
    fn validated_link_matches_hand_tuned_band() {
        // ~12ms jitter (the live rig p50) → 0.8*12 + 4 = 13.6ms — in the known-smooth 10-14ms band.
        assert!(approx(target_seconds(0.012, &Config::default()), 0.0136));
        // p90 ~14ms → 15.2ms, still safely above the live-confirmed-stutter 6ms.
        assert!(approx(target_seconds(0.014, &Config::default()), 0.0152));
    }

    #[test]
    fn pathological_wan_clamps_at_ceil() {
        // 40ms jitter → 0.8*40 + 4 = 36ms → clamped to the 35ms ceiling.
        assert!(approx(target_seconds(0.040, &Config::default()), 0.035));
        assert!(approx(target_seconds(1.0, &Config::default()), 0.035));
    }

    #[test]
    fn non_finite_or_negative_jitter_falls_back_to_floor() {
        let c = Config::default();
        assert!(approx(target_seconds(f64::NAN, &c), c.floor_seconds));
        assert!(approx(target_seconds(f64::INFINITY, &c), c.floor_seconds));
        assert!(approx(target_seconds(-0.01, &c), c.floor_seconds));
    }

    #[test]
    fn grows_fast_shrinks_slow() {
        let c = Config::default();
        let shrink = 0.002; // 2ms per tick
                            // Cold start at floor, jitter jumps to 30ms target (0.8*30+4=28ms): grow immediately.
        let grown = step_seconds(0.030, c.floor_seconds, shrink, &c);
        assert!(approx(grown, 0.028));
        // Link goes clean (2ms → 5.6ms target): shrink by at most 2ms, NOT straight to target.
        let s1 = step_seconds(0.002, grown, shrink, &c);
        assert!(approx(s1, 0.026)); // 28 - 2
        let s2 = step_seconds(0.002, s1, shrink, &c);
        assert!(approx(s2, 0.024)); // 26 - 2
                                    // ... and eventually settles AT the target, never below.
        let mut v = s2;
        for _ in 0..100 {
            v = step_seconds(0.002, v, shrink, &c);
        }
        assert!(approx(v, 0.0056));
    }

    #[test]
    fn shrink_never_overshoots_target() {
        let c = Config::default();
        // prev just 1ms above target, shrink step 2ms → land exactly on target, not below.
        let target = target_seconds(0.010, &c); // 0.8*10+4 = 12ms
        let v = step_seconds(0.010, target + 0.001, 0.002, &c);
        assert!(approx(v, target));
    }

    #[test]
    fn from_ms_clamps_and_keeps_ceil_above_floor() {
        // ceil below floor is lifted to floor.
        let c = Config::from_ms(0.8, 4.0, 20.0, 5.0);
        assert!(approx(c.floor_seconds, 0.020));
        assert!(approx(c.ceil_seconds, 0.020));
        // out-of-band k saturates; non-finite falls back to default.
        assert!(approx(Config::from_ms(99.0, 4.0, 4.0, 35.0).k, 4.0));
        assert!(approx(
            Config::from_ms(f64::NAN, 4.0, 4.0, 35.0).k,
            DEFAULT_K
        ));
    }
}
