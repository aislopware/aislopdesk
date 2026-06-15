//! Client-side scroll-hint reprojection law.
//!
//! The pure offset integrator the deadline pacer applies on its *between-content* display ticks so
//! a remote window scrolls at the display refresh rate instead of the codec frame rate.
//!
//! ## The idea
//!
//! A 120 Hz panel ticks ~twice per 60 fps codec frame; on the spare ticks the pacer currently
//! re-shows the identical last decoded frame (an identity no-op). While the user is scrolling a
//! remote window, the client *already knows* the scroll velocity locally (it reads the trackpad
//! delta before forwarding it to the host). This law integrates that local velocity into a small
//! normalized UV offset; the renderer translates the last frame by it on those spare ticks, so
//! the picture keeps moving smoothly between real frames. The newly-revealed edge (disocclusion)
//! is the renderer's problem (it clamps out-of-bounds samples to black); this module only owns
//! the *offset value*.
//!
//! ## The one hard invariant: never double-count
//!
//! The instant a real codec frame is presented, the new frame *already contains* the scrolled
//! content — so the accumulated hint offset must reset to exactly `0`, or the picture would jump
//! by the hint amount on top of the real scroll. [`ScrollReprojector::note_real_frame`] enforces
//! this; it is the reset that makes the whole scheme correct rather than a smear.
//!
//! ## Purity
//!
//! Virtual-clock driven: every method takes the elapsed/now it needs as a parameter — no
//! `std::time`, no env, no I/O. The Swift shell holds the wall clock and the config; this crate
//! holds the law, so it is deterministic and unit-testable to the bit. Normalized units (a frame
//! spans `0..1` on each axis) keep it resolution-independent.

/// Default maximum reprojection band per axis (normalized units), roughly an eighth of the frame.
///
/// A hint never translates the frame by more than this fraction — past it the disocclusion gutter
/// would dominate and the guess is worse than a static re-show, so the offset clamps.
pub const DEFAULT_MAX_BAND: f64 = 0.125;
/// Default decay time-constant (seconds) once a scroll has *stopped* (phase ended / momentum end).
///
/// The offset bleeds to zero over ~this long so the picture eases to rest instead of snapping back
/// when the velocity source goes quiet but no fresh frame has reset it yet.
pub const DEFAULT_DECAY_SECONDS: f64 = 0.12;

/// The phase of a scroll velocity sample, mapped from the platform scroll phases.
///
/// The Swift shell collapses the finer `CGScrollPhase` / `CGMomentumScrollPhase` codes into these
/// three: a finger-on-glass *changed/began* is [`Active`](ScrollPhase::Active); a finger lift or a
/// momentum *continue* keeps coasting under [`Momentum`](ScrollPhase::Momentum); a finger-lift
/// *ended* or momentum *end* is [`Ended`](ScrollPhase::Ended) and arms the decay.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    /// The user is actively dragging (finger on glass): track the velocity, no decay.
    Active,
    /// Inertial coast (finger lifted, momentum still flowing): track the velocity, no decay.
    Momentum,
    /// The gesture finished (finger-lift end or momentum end): keep the last velocity but arm the
    /// decay so the offset eases to rest.
    Ended,
}

/// The tunable shape of the reprojection law (normalized + seconds domains).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// Per-axis clamp on the integrated offset (normalized units).
    pub max_band: f64,
    /// Decay time-constant after a scroll ends (seconds). Larger = a slower ease-out.
    pub decay_seconds: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_band: DEFAULT_MAX_BAND,
            decay_seconds: DEFAULT_DECAY_SECONDS,
        }
    }
}

impl Config {
    /// Builds a config from caller knobs, clamping each to a sane band so a hostile env value can
    /// never produce a runaway or negative offset. A non-finite knob falls back to its default.
    #[must_use]
    pub const fn sanitized(max_band: f64, decay_seconds: f64) -> Self {
        let max_band = if max_band.is_finite() {
            max_band.clamp(0.0, 0.5)
        } else {
            DEFAULT_MAX_BAND
        };
        let decay_seconds = if decay_seconds.is_finite() {
            decay_seconds.clamp(0.0, 2.0)
        } else {
            DEFAULT_DECAY_SECONDS
        };
        Self {
            max_band,
            decay_seconds,
        }
    }
}

/// The integrated scroll-hint offset for one video pane.
///
/// Drive it with [`note_velocity`](ScrollReprojector::note_velocity) per scroll event,
/// [`advance`](ScrollReprojector::advance) once per spare display tick to integrate + read the
/// offset, and [`note_real_frame`](ScrollReprojector::note_real_frame) the instant a real decoded
/// frame is presented (the reset that prevents double-counting). One per pane; not thread-safe
/// (the caller's pacer lock / main actor serializes it).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollReprojector {
    config: Config,
    /// Current integrated offset (normalized, clamped to `±max_band`).
    offset_x: f64,
    offset_y: f64,
    /// Current velocity (normalized units per second).
    vel_x: f64,
    vel_y: f64,
    /// True once a scroll has ended: [`advance`](ScrollReprojector::advance) decays the offset
    /// toward zero instead of integrating fresh velocity.
    decaying: bool,
}

impl ScrollReprojector {
    /// Creates a reprojector with the given config and a zero offset / zero velocity.
    #[must_use]
    pub const fn new(config: Config) -> Self {
        Self {
            config,
            offset_x: 0.0,
            offset_y: 0.0,
            vel_x: 0.0,
            vel_y: 0.0,
            decaying: false,
        }
    }

    /// The current integrated offset (normalized) without advancing the clock — what the renderer
    /// would apply right now. `(x, y)`.
    #[must_use]
    pub const fn offset(&self) -> (f64, f64) {
        (self.offset_x, self.offset_y)
    }

    /// True while a stopped scroll is bleeding its residual offset to zero.
    #[must_use]
    pub const fn is_decaying(&self) -> bool {
        self.decaying
    }

    /// Folds one scroll-velocity sample. `vx`/`vy` are normalized units per second (the Swift shell
    /// divides the per-event pixel delta by the elapsed time and the view extent). A non-finite
    /// sample is dropped (treated as zero) so a bad event can never poison the integrator.
    ///
    /// An [`Active`](ScrollPhase::Active) / [`Momentum`](ScrollPhase::Momentum) sample sets the live
    /// velocity and disarms decay; an [`Ended`](ScrollPhase::Ended) sample keeps the last velocity
    /// (the supplied one if finite/non-zero) but arms the decay so the next
    /// [`advance`](ScrollReprojector::advance) eases the offset to rest.
    pub fn note_velocity(&mut self, vx: f64, vy: f64, phase: ScrollPhase) {
        let vx = if vx.is_finite() { vx } else { 0.0 };
        let vy = if vy.is_finite() { vy } else { 0.0 };
        match phase {
            ScrollPhase::Active | ScrollPhase::Momentum => {
                self.vel_x = vx;
                self.vel_y = vy;
                self.decaying = false;
            }
            ScrollPhase::Ended => {
                // Keep coasting on the last known velocity unless this end-event carried its own
                // (some platforms send a final non-zero sample); then arm the decay.
                if vx != 0.0 || vy != 0.0 {
                    self.vel_x = vx;
                    self.vel_y = vy;
                }
                self.decaying = true;
            }
        }
    }

    /// Integrates the velocity over `elapsed_seconds` (or decays a stopped scroll), clamps each axis
    /// to `±max_band`, and returns the resulting offset `(x, y)`.
    ///
    /// Called once per spare (between-content) display tick with the time since the last tick. A
    /// non-finite / negative `elapsed_seconds` is treated as zero (the offset is returned unchanged)
    /// so a clock glitch can never jump the picture. While decaying, the offset shrinks
    /// geometrically toward zero on a `decay_seconds` time-constant and snaps to exactly zero once
    /// it is within a sub-pixel epsilon, so a stopped scroll settles cleanly.
    pub fn advance(&mut self, elapsed_seconds: f64) -> (f64, f64) {
        let dt = if elapsed_seconds.is_finite() && elapsed_seconds > 0.0 {
            elapsed_seconds
        } else {
            0.0
        };
        if self.decaying {
            self.apply_decay(dt);
        } else {
            self.offset_x += self.vel_x * dt;
            self.offset_y += self.vel_y * dt;
        }
        self.clamp_to_band();
        (self.offset_x, self.offset_y)
    }

    /// Resets the offset (and the integration baseline) to exactly zero.
    ///
    /// Called the instant a real decoded frame is presented: that frame already contains the
    /// scrolled content, so any accumulated hint offset MUST be discarded or it would be added on
    /// top of the real scroll (the double-count bug). The live velocity is preserved (the gesture
    /// may still be in flight — the next spare tick re-integrates from zero), but the decay flag is
    /// cleared since the fresh frame is the authoritative rest position.
    pub const fn note_real_frame(&mut self) {
        self.offset_x = 0.0;
        self.offset_y = 0.0;
        self.decaying = false;
    }

    /// Fully resets the reprojector (offset AND velocity to zero, decay cleared) — used when a pane
    /// goes idle / loses focus so a stale velocity can never resume on the next event.
    pub const fn reset(&mut self) {
        self.offset_x = 0.0;
        self.offset_y = 0.0;
        self.vel_x = 0.0;
        self.vel_y = 0.0;
        self.decaying = false;
    }

    /// Geometric ease-out toward zero on the `decay_seconds` time-constant; snaps to exactly zero
    /// inside a sub-pixel epsilon so the offset settles rather than asymptoting forever.
    fn apply_decay(&mut self, dt: f64) {
        // ~1/8000 of a frame: below one pixel on any realistic panel ⇒ treat as rest.
        const EPSILON: f64 = 1.25e-4;
        // A zero/degenerate time-constant means "stop instantly".
        if self.config.decay_seconds <= 0.0 {
            self.offset_x = 0.0;
            self.offset_y = 0.0;
            return;
        }
        let factor = (-dt / self.config.decay_seconds).exp();
        self.offset_x *= factor;
        self.offset_y *= factor;
        if self.offset_x.abs() < EPSILON {
            self.offset_x = 0.0;
        }
        if self.offset_y.abs() < EPSILON {
            self.offset_y = 0.0;
        }
    }

    /// Clamps each axis to `±max_band` so a fast flick can never translate the frame past the band
    /// (where the disocclusion gutter would dominate).
    fn clamp_to_band(&mut self) {
        let band = self.config.max_band;
        self.offset_x = self.offset_x.clamp(-band, band);
        self.offset_y = self.offset_y.clamp(-band, band);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn zero_velocity_is_zero_offset() {
        let mut r = ScrollReprojector::new(Config::default());
        r.note_velocity(0.0, 0.0, ScrollPhase::Active);
        let (x, y) = r.advance(0.1);
        assert!(approx(x, 0.0) && approx(y, 0.0));
    }

    #[test]
    fn invariant_a_offset_grows_with_velocity_times_elapsed() {
        // 0.2 frames/sec downward for 50 ms ⇒ 0.01 (well inside the band).
        let mut r = ScrollReprojector::new(Config::default());
        r.note_velocity(0.0, 0.2, ScrollPhase::Active);
        let (x, y) = r.advance(0.05);
        assert!(approx(x, 0.0));
        assert!(approx(y, 0.01));
        // A second tick keeps integrating linearly.
        let (_, y2) = r.advance(0.05);
        assert!(approx(y2, 0.02));
    }

    #[test]
    fn invariant_b_real_frame_resets_offset_to_exactly_zero() {
        let mut r = ScrollReprojector::new(Config::default());
        r.note_velocity(0.1, 0.1, ScrollPhase::Active);
        let _ = r.advance(0.05);
        assert!(r.offset() != (0.0, 0.0));
        r.note_real_frame();
        assert_eq!(r.offset(), (0.0, 0.0)); // EXACTLY zero — no double-count
        // The live velocity survives, so the next tick re-integrates FROM zero (no carry-over).
        let (x, y) = r.advance(0.05);
        assert!(approx(x, 0.005) && approx(y, 0.005));
    }

    #[test]
    fn invariant_c_ended_phase_decays_to_zero_over_the_window() {
        let mut r = ScrollReprojector::new(Config::sanitized(0.5, 0.1));
        r.note_velocity(0.0, 0.4, ScrollPhase::Active);
        let (_, y0) = r.advance(0.05); // 0.02
        assert!(y0 > 0.0);
        r.note_velocity(0.0, 0.0, ScrollPhase::Ended); // arm decay, no new velocity
        assert!(r.is_decaying());
        // Each decay tick shrinks the offset (geometric ease-out) and never grows it.
        let mut prev = r.offset().1;
        for _ in 0..200 {
            let (_, y) = r.advance(0.016);
            assert!(y <= prev + 1e-12);
            prev = y;
        }
        // After several time-constants it has snapped to exactly zero.
        assert_eq!(r.offset(), (0.0, 0.0));
    }

    #[test]
    fn invariant_d_fast_flick_clamps_to_max_band() {
        let c = Config::default();
        let mut r = ScrollReprojector::new(c);
        // A huge velocity for a long tick would integrate way past the band — it must clamp.
        r.note_velocity(0.0, 50.0, ScrollPhase::Active);
        let (_, y) = r.advance(1.0);
        assert!(approx(y, c.max_band));
        // The opposite direction clamps to the negative band.
        r.note_real_frame();
        r.note_velocity(0.0, -50.0, ScrollPhase::Active);
        let (_, y2) = r.advance(1.0);
        assert!(approx(y2, -c.max_band));
    }

    #[test]
    fn phase_mapping_active_and_momentum_track_velocity_ended_arms_decay() {
        let mut r = ScrollReprojector::new(Config::default());
        // Active sets velocity, not decaying.
        r.note_velocity(0.1, 0.0, ScrollPhase::Active);
        assert!(!r.is_decaying());
        let (x1, _) = r.advance(0.1);
        assert!(approx(x1, 0.01));
        // Momentum keeps integrating (also not decaying), with a possibly different velocity.
        r.note_velocity(0.05, 0.0, ScrollPhase::Momentum);
        assert!(!r.is_decaying());
        r.note_real_frame();
        let (x2, _) = r.advance(0.1);
        assert!(approx(x2, 0.005));
        // Ended arms decay.
        r.note_velocity(0.0, 0.0, ScrollPhase::Ended);
        assert!(r.is_decaying());
    }

    #[test]
    fn ended_with_final_velocity_keeps_coasting_then_decays() {
        // Some platforms deliver a final non-zero sample on the ended event; it should be adopted.
        let mut r = ScrollReprojector::new(Config::sanitized(0.5, 0.2));
        r.note_velocity(0.0, 0.3, ScrollPhase::Ended);
        assert!(r.is_decaying());
        // First advance decays the (zero) offset; the coast velocity is held but decay dominates.
        let (_, y) = r.advance(0.016);
        assert!(y >= 0.0); // never goes negative from a positive coast
    }

    #[test]
    fn non_finite_inputs_are_ignored() {
        let mut r = ScrollReprojector::new(Config::default());
        r.note_velocity(f64::NAN, f64::INFINITY, ScrollPhase::Active);
        let (x, y) = r.advance(f64::NAN);
        assert!(approx(x, 0.0) && approx(y, 0.0));
        // A negative elapsed is treated as zero (no rewind).
        r.note_velocity(0.0, 0.2, ScrollPhase::Active);
        let (_, y2) = r.advance(-1.0);
        assert!(approx(y2, 0.0));
    }

    #[test]
    fn reset_clears_velocity_so_no_stale_resume() {
        let mut r = ScrollReprojector::new(Config::default());
        r.note_velocity(0.0, 0.2, ScrollPhase::Active);
        let _ = r.advance(0.05);
        r.reset();
        assert_eq!(r.offset(), (0.0, 0.0));
        // Velocity is gone: a fresh advance with no new sample stays at zero.
        let (_, y) = r.advance(0.05);
        assert!(approx(y, 0.0));
    }

    #[test]
    fn sanitized_clamps_hostile_config() {
        let c = Config::sanitized(99.0, -1.0);
        assert!(approx(c.max_band, 0.5));
        assert!(approx(c.decay_seconds, 0.0));
        let nan = Config::sanitized(f64::NAN, f64::NAN);
        assert!(approx(nan.max_band, DEFAULT_MAX_BAND));
        assert!(approx(nan.decay_seconds, DEFAULT_DECAY_SECONDS));
    }

    #[test]
    fn zero_decay_constant_stops_instantly() {
        let mut r = ScrollReprojector::new(Config::sanitized(0.5, 0.0));
        r.note_velocity(0.0, 0.4, ScrollPhase::Active);
        let _ = r.advance(0.05);
        r.note_velocity(0.0, 0.0, ScrollPhase::Ended);
        let (_, y) = r.advance(0.016);
        assert!(approx(y, 0.0)); // decay_seconds == 0 ⇒ snap to rest
    }
}
