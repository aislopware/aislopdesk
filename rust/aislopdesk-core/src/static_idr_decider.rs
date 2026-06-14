//! Pure decider for the static-window forced-IDR heartbeat (VIDEO-HOST-1).
//!
//! The canonical `StaticIDRDecider` logic; the native Swift shell keeps a copy
//! (`Sources/AislopdeskVideoHost/VideoSessionLogic.swift`) that tracks this (golden parity).
//!
//! Holds the cadence anchors and answers a single question: *given the clock and what
//! was last encoded, should the frameQueue timer re-encode the cached buffer as a forced
//! IDR right now?* There is no I/O — the caller owns the retained buffer, the timer, and
//! the encode. This is the "decider beside the actor" discipline shared with
//! [`IdleReapDecider`](crate::idle_reap_decider::IdleReapDecider): the policy is pure and headlessly
//! unit-testable (injected `now`), while the side effects (retain, timer, encode) stay
//! thin in the capture path.
//!
//! ## Clock model
//!
//! `TimeInterval` maps to `f64` seconds. The two anchors ([`last_complete_encode`] and
//! [`last_synthetic_encode`]) use `0.0` as the "none yet" sentinel exactly as the Swift
//! source does (uptime seconds are always `> 0` in practice, so `0.0` is unambiguous).
//!
//! ## The cadence
//!
//! * The capture path calls [`on_complete_frame`](StaticIDRDecider::on_complete_frame) on
//!   every real `.complete` frame, re-anchoring the live clock.
//! * The timer calls
//!   [`should_reencode`](StaticIDRDecider::should_reencode) each tick, then
//!   [`record_synthetic`](StaticIDRDecider::record_synthetic) when it fires.
//! * The heartbeat is measured from the last **synthetic** emission only (SHARPNESS,
//!   2026-06-10 — see [`should_reencode`](StaticIDRDecider::should_reencode)), so the
//!   first crisp re-anchor after motion stops fires as soon as the quiet window clears
//!   (~1 s, Parsec-like) rather than a full heartbeat after the last real frame.
//!
//! [`last_complete_encode`]: StaticIDRDecider::last_complete_encode
//! [`last_synthetic_encode`]: StaticIDRDecider::last_synthetic_encode

/// Pure decider for the static-window forced-IDR heartbeat.
///
/// `Copy` (four `f64`s) so it behaves like the Swift shell's `Sendable, Equatable` value struct.
/// `PartialEq`: two deciders are equal iff all four fields match; the Swift shell's synthesized
/// `Equatable` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StaticIDRDecider {
    /// Heartbeat cadence (seconds). Matches `WindowCapturer.heartbeatIDRInterval` (1.0) in the Swift shell.
    heartbeat: f64,
    /// Quiet window (seconds): suppress a synthetic re-encode if a REAL `.complete` frame
    /// was encoded within this window — a live screen drives IDRs through the normal path,
    /// so the timer must not double-emit. Default = `heartbeat` (one cadence).
    quiet_window: f64,
    /// Uptime seconds of the last REAL `.complete`-frame encode (live path). `0.0` = none yet.
    last_complete_encode: f64,
    /// Uptime seconds of the last SYNTHETIC (timer-driven cached) re-encode. `0.0` = none yet.
    last_synthetic_encode: f64,
}

impl StaticIDRDecider {
    /// Builds a decider with the given `heartbeat` cadence (seconds).
    ///
    /// `quiet_window` is `Some(secs)` to set it explicitly, or `None` to take the Swift
    /// default of one cadence (`quiet_window == heartbeat`). The Swift shell's
    /// `init(heartbeat:quietWindow:)` matches this, where `quietWindow` defaults to `nil ?? heartbeat`.
    #[must_use]
    pub fn new(heartbeat: f64, quiet_window: Option<f64>) -> Self {
        Self {
            heartbeat,
            // Swift: `self.quietWindow = quietWindow ?? heartbeat`.
            quiet_window: quiet_window.unwrap_or(heartbeat),
            last_complete_encode: 0.0,
            last_synthetic_encode: 0.0,
        }
    }

    /// The heartbeat cadence in seconds.
    #[must_use]
    pub const fn heartbeat(&self) -> f64 {
        self.heartbeat
    }

    /// The quiet window in seconds (defaults to [`heartbeat`](Self::heartbeat)).
    #[must_use]
    pub const fn quiet_window(&self) -> f64 {
        self.quiet_window
    }

    /// Uptime seconds of the last REAL `.complete`-frame encode (`0.0` = none yet).
    #[must_use]
    pub const fn last_complete_encode(&self) -> f64 {
        self.last_complete_encode
    }

    /// Uptime seconds of the last SYNTHETIC (timer-driven) re-encode (`0.0` = none yet).
    #[must_use]
    pub const fn last_synthetic_encode(&self) -> f64 {
        self.last_synthetic_encode
    }

    /// The capture path encoded a REAL frame at `now`. Re-anchors the live clock so the
    /// timer stays quiet while the screen is live, and a heartbeat measures from the last
    /// real frame. The Swift shell's `onCompleteFrame(now:)` mirrors this.
    pub const fn on_complete_frame(&mut self, now: f64) {
        self.last_complete_encode = now;
    }

    /// The timer fired a synthetic re-encode at `now`. Re-anchors the synthetic clock.
    /// The Swift shell's `recordSynthetic(now:)` mirrors this.
    pub const fn record_synthetic(&mut self, now: f64) {
        self.last_synthetic_encode = now;
    }

    /// Decision for a frameQueue timer tick. PURE (no mutation). The Swift shell's
    /// `shouldReencode(now:forcedLatched:hasRetainedBuffer:)` mirrors this branch-for-branch.
    ///
    /// * `forced_latched`: a client recovery/keyframe request is pending (drained by caller).
    /// * `has_retained_buffer`: a cached `.complete` pixel buffer exists to re-encode.
    ///
    /// Returns `true` iff the caller should re-encode the cached buffer as a forced IDR.
    #[must_use]
    pub fn should_reencode(
        &self,
        now: f64,
        forced_latched: bool,
        has_retained_buffer: bool,
    ) -> bool {
        // No cached pixels ⇒ nothing to re-encode (e.g. before the first ever .complete frame).
        if !has_retained_buffer {
            return false;
        }
        // A real frame within the quiet window ⇒ the live path is (or just was) driving the
        // stream; let it own the cadence, don't double-emit. (A recovery request while live is
        // already serviced faster by the live `.complete` latch drain — the timer is the
        // fallback only when the live path has gone quiet, so the quiet window gates forced too.)
        let since_complete = now - self.last_complete_encode;
        if self.last_complete_encode != 0.0 && since_complete < self.quiet_window {
            return false;
        }
        // Recovery request always wins once the live path is quiet (latency-critical: a client
        // is frozen). Fire regardless of heartbeat phase.
        if forced_latched {
            return true;
        }
        // Otherwise: heartbeat — measured from the last SYNTHETIC emission only (SHARPNESS,
        // 2026-06-10; was `max(lastComplete, lastSynthetic)`). Measuring from the last REAL frame
        // made the FIRST crisp re-anchor after a scroll wait a full heartbeat even though the
        // quiet window had long passed; Parsec re-sharpens in ~1 s. With the synthetic-only anchor
        // the first crisp fires as soon as the quiet window clears (~1 s after motion stops),
        // while the steady-state static cadence stays one `heartbeat` apart.
        if self.last_synthetic_encode == 0.0 {
            return true; // armed, none emitted yet, quiet ⇒ fire now
        }
        (now - self.last_synthetic_encode) >= self.heartbeat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEARTBEAT: f64 = 1.0;

    fn make(quiet_window: Option<f64>) -> StaticIDRDecider {
        StaticIDRDecider::new(HEARTBEAT, quiet_window)
    }

    // 1. No cached buffer ⇒ never fire, for every now/forced combination.
    #[test]
    fn no_buffer_never_fires() {
        let d = make(None);
        for now in [0.0, 1.0, 5.0, 100.0] {
            for forced in [false, true] {
                assert!(
                    !d.should_reencode(now, forced, false),
                    "no buffer must never fire (now={now}, forced={forced})"
                );
            }
        }
    }

    // 2. Armed, never emitted, buffer present ⇒ fire at any now > 0.
    #[test]
    fn armed_never_emitted_fires() {
        let d = make(None);
        assert!(d.should_reencode(0.001, false, true));
        assert!(d.should_reencode(50.0, false, true));
    }

    // 3. Heartbeat boundary is inclusive (>=): fires at exactly +heartbeat, not just before.
    #[test]
    fn heartbeat_boundary_inclusive() {
        let mut d = make(None);
        d.on_complete_frame(10.0);
        assert!(
            d.should_reencode(11.0, false, true),
            "exactly one heartbeat elapsed ⇒ fire (>= inclusive)"
        );
        assert!(
            !d.should_reencode(10.999, false, true),
            "just under one heartbeat ⇒ no fire"
        );
    }

    // 4. Quiet window suppresses the heartbeat while the live path is driving.
    #[test]
    fn quiet_window_suppresses_heartbeat() {
        let mut d = make(None);
        d.on_complete_frame(10.0);
        assert!(
            !d.should_reencode(10.5, false, true),
            "a real frame within the quiet window ⇒ live path owns it"
        );
    }

    // 5. Quiet window suppresses even a forced (recovery) request — the live latch drain handles it.
    #[test]
    fn quiet_window_suppresses_forced() {
        let mut d = make(None);
        d.on_complete_frame(10.0);
        assert!(
            !d.should_reencode(10.5, true, true),
            "while live, recovery is serviced by the .complete latch drain, not the timer"
        );
    }

    // 6. Forced wins once quiet, BEFORE the heartbeat would otherwise fire (quietWindow < heartbeat
    //    isolates that recovery beats the heartbeat phase).
    #[test]
    fn forced_wins_once_quiet_before_heartbeat() {
        let mut d = make(Some(0.3)); // shorter than heartbeat (1.0) to isolate the forced path
        d.record_synthetic(10.1); // recent synthetic anchor ⇒ the heartbeat phase is mid-cycle
        d.on_complete_frame(10.0);
        // now=10.5: past the 0.3 quiet window but only 0.4 < 1.0 since the synthetic anchor →
        // heartbeat alone is silent.
        assert!(
            !d.should_reencode(10.5, false, true),
            "sub-heartbeat, no forced ⇒ no fire"
        );
        assert!(
            d.should_reencode(10.5, true, true),
            "forced fires immediately once past the quiet window, any heartbeat phase"
        );
    }

    // 6b. Quiet-window EXACT boundary (sinceComplete == quietWindow): the strict `<` means the
    //     frame at exactly +quietWindow is NOT suppressed → a forced request fires; a sub-heartbeat
    //     non-forced still does not. Pins the strict-`<` semantics against a `<`→`<=` regression.
    #[test]
    fn quiet_window_exact_boundary() {
        let mut d = make(Some(0.3));
        d.record_synthetic(9.9); // recent synthetic anchor ⇒ the heartbeat phase is mid-cycle
        d.on_complete_frame(10.0);
        assert!(
            d.should_reencode(10.3, true, true),
            "forced at exactly +quietWindow ⇒ fire (strict `<` does not suppress the boundary)"
        );
        assert!(
            !d.should_reencode(10.3, false, true),
            "non-forced sub-heartbeat at the quiet boundary ⇒ still no fire"
        );
    }

    // 2b. Forced + armed (no real frame ever encoded, buffer present) — the real first-frame
    //     recovery on a window that went static immediately ⇒ fire.
    #[test]
    fn forced_armed_fires() {
        let d = make(None);
        assert!(
            d.should_reencode(0.5, true, true),
            "forced recovery with a cached buffer but no prior emission ⇒ fire"
        );
    }

    // 7. A synthetic emission re-anchors the cadence (measured from the synthetic anchor).
    #[test]
    fn synthetic_re_anchors_cadence() {
        let mut d = make(None);
        d.on_complete_frame(10.0);
        d.record_synthetic(11.0); // a synthetic fired at 11
        assert!(
            !d.should_reencode(11.5, false, true),
            "0.5s after the synthetic ⇒ no fire"
        );
        assert!(
            d.should_reencode(12.0, false, true),
            "one heartbeat after the synthetic ⇒ fire"
        );
    }

    // 8. A real frame after a synthetic still gates via its quiet window; once quiet AND one
    //    heartbeat past the synthetic anchor, fire.
    #[test]
    fn real_frame_after_synthetic_re_anchors_to_real() {
        let mut d = make(None);
        d.record_synthetic(11.0);
        d.on_complete_frame(11.2); // a real frame landed shortly after the synthetic
        assert!(
            !d.should_reencode(11.9, false, true),
            "within the quiet window of the real frame ⇒ no fire"
        );
        assert!(
            d.should_reencode(12.3, false, true),
            "quiet window cleared + one heartbeat past the synthetic anchor ⇒ fire"
        );
    }

    // 11. SHARPNESS (2026-06-10): the FIRST crisp after motion stops fires as soon as the quiet
    //     window clears — it does NOT wait a full heartbeat from the last REAL frame. Production
    //     shape: heartbeat 2.5, quietWindow 1.0 ⇒ crisp ~1 s after the scroll ends (Parsec-like),
    //     then steady-state synthetics one heartbeat apart.
    #[test]
    fn first_crisp_after_motion_fires_at_quiet_window_not_heartbeat() {
        let mut d = StaticIDRDecider::new(2.5, Some(1.0));
        d.record_synthetic(2.0); // an old static-phase synthetic long ago
        d.on_complete_frame(10.0); // ...then motion; the last real frame lands at t=10
        assert!(
            !d.should_reencode(10.9, false, true),
            "still inside the quiet window ⇒ live path owns it"
        );
        assert!(
            d.should_reencode(11.0, false, true),
            "quiet window cleared ⇒ first crisp fires NOW (not at lastComplete+heartbeat=12.5)"
        );
        d.record_synthetic(11.0);
        assert!(
            !d.should_reencode(12.5, false, true),
            "subsequent statics pace one heartbeat from the synthetic anchor"
        );
        assert!(
            d.should_reencode(13.5, false, true),
            "heartbeat elapsed since the synthetic ⇒ steady-state cadence holds"
        );
    }

    // 9. lastComplete == 0 but lastSynthetic set: the quiet-window check is skipped (guarded by
    //    lastComplete != 0), cadence is measured from the synthetic anchor.
    #[test]
    fn last_emission_picks_synthetic_when_no_real_frame() {
        let mut d = make(None);
        d.record_synthetic(5.0);
        assert!(
            !d.should_reencode(5.5, false, true),
            "0.5s after the only (synthetic) emission, no real frame ⇒ no fire"
        );
        assert!(
            d.should_reencode(6.0, false, true),
            "one heartbeat after the synthetic anchor ⇒ fire (cadence from lastSynthetic)"
        );
    }

    // 10. Equatable sanity — identical anchors compare equal (guards against accidental field drift).
    #[test]
    fn equatable() {
        let mut a = make(None);
        let mut b = make(None);
        assert_eq!(a, b);
        a.on_complete_frame(10.0);
        b.on_complete_frame(10.0);
        a.record_synthetic(11.0);
        b.record_synthetic(11.0);
        assert_eq!(a, b);
        b.record_synthetic(12.0);
        assert_ne!(a, b);
    }

    // Default quietWindow == heartbeat (one cadence) when None is passed.
    #[test]
    fn default_quiet_window_equals_heartbeat() {
        let d = StaticIDRDecider::new(2.0, None);
        assert_eq!(d.quiet_window(), 2.0);
        assert_eq!(d.heartbeat(), 2.0);
    }

    // ---- Additional edge cases ----

    // now == 0.0 with an armed buffer and nothing emitted: lastComplete==0 skips the quiet guard,
    // not forced, lastSynthetic==0 ⇒ fire. (The Swift comment says "now > 0" but the branch order
    // also fires at exactly 0.0.)
    #[test]
    fn armed_at_now_zero_fires() {
        let d = make(None);
        assert!(d.should_reencode(0.0, false, true));
    }

    // No buffer beats every other condition — even forced + past heartbeat is suppressed.
    #[test]
    fn no_buffer_beats_forced_and_heartbeat() {
        let mut d = make(None);
        d.on_complete_frame(1.0);
        d.record_synthetic(1.0);
        assert!(!d.should_reencode(1000.0, true, false));
    }

    // Explicit quiet_window longer than heartbeat: a real frame within that long window suppresses
    // even though more than one heartbeat has elapsed since the (older) synthetic anchor.
    #[test]
    fn long_quiet_window_suppresses_past_heartbeat() {
        let mut d = StaticIDRDecider::new(1.0, Some(5.0));
        d.record_synthetic(0.0); // synthetic anchored at the 0.0 sentinel ⇒ treated as "none yet"
        d.on_complete_frame(10.0);
        // 2 s after the real frame: > heartbeat (1.0) but < quiet_window (5.0) ⇒ suppressed.
        assert!(
            !d.should_reencode(12.0, false, true),
            "inside the long quiet window ⇒ no fire despite heartbeat elapsing"
        );
        // Past the quiet window: lastSynthetic is the 0.0 sentinel ⇒ armed ⇒ fire.
        assert!(d.should_reencode(15.1, false, true));
    }

    // Constructor stores anchors at the 0.0 sentinel and getters reflect mutations.
    #[test]
    fn getters_reflect_state() {
        let mut d = make(Some(0.7));
        assert_eq!(d.last_complete_encode(), 0.0);
        assert_eq!(d.last_synthetic_encode(), 0.0);
        assert_eq!(d.quiet_window(), 0.7);
        d.on_complete_frame(3.0);
        d.record_synthetic(4.0);
        assert_eq!(d.last_complete_encode(), 3.0);
        assert_eq!(d.last_synthetic_encode(), 4.0);
    }

    // Heartbeat boundary measured from the synthetic anchor is inclusive at exactly +heartbeat
    // and silent just under (mirrors test 3 but via the synthetic path, lastComplete==0).
    #[test]
    fn synthetic_heartbeat_boundary_inclusive() {
        let mut d = make(None);
        d.record_synthetic(20.0);
        assert!(
            !d.should_reencode(20.999, false, true),
            "just under one heartbeat since the synthetic ⇒ no fire"
        );
        assert!(
            d.should_reencode(21.0, false, true),
            "exactly one heartbeat since the synthetic ⇒ fire"
        );
    }

    // Copy semantics: a copy is independent of later mutation (value-type parity with Swift).
    #[test]
    fn copy_is_independent() {
        let mut a = make(None);
        a.on_complete_frame(5.0);
        let b = a; // Copy
        a.on_complete_frame(9.0);
        assert_eq!(b.last_complete_encode(), 5.0);
        assert_eq!(a.last_complete_encode(), 9.0);
    }
}
