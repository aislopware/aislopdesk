//! Pure re-arm + backoff decision for a UDP `receiveMessage` loop (BUG-L / F3).
//!
//! The canonical `UDPReceiveLoopPolicy` logic; the native Swift shell keeps copies
//! (`AislopdeskVideoHost/Mux/UDPReceiveLoopPolicy.swift` and
//! `AislopdeskVideoClient/Mux/UDPReceiveLoopPolicy.swift`) that track this (golden parity).
//!
//! The receive loop must keep itself armed across TRANSIENT per-datagram errors (an ICMP
//! port-unreachable surfaces as a receive error even while the flow/connection stays `.ready`)
//! and stop ONLY when the flow is genuinely dead. The liveness signal comes from the
//! connection's state handler (`.failed`/`.cancelled`), not from the per-receive error — so the
//! re-arm decision is purely "is the flow still alive?" ([`should_rearm`]).
//!
//! The BUG-L fix re-arms on a transient error, but a SUSTAINED error (an ICMP port-unreachable
//! delivered as ECONNREFUSED on every `receiveMessage` while the flow stays `.ready`) re-armed
//! with ZERO delay → 100% CPU busy-loop. [`next_backoff`] adds the F3 cure: exponential growth
//! from [`UDPReceiveLoopPolicy::BASE_BACKOFF`] (×2 per consecutive error), capped at
//! [`UDPReceiveLoopPolicy::MAX_BACKOFF`]. The loop RESETS its consecutive-error count to 0 on the
//! first error-free datagram, so `next_backoff(0)` is `0.0` — the normal hot path is never
//! delayed.
//!
//! Both functions are pure + unit-testable (no socket / clock). Client + host Swift shell modules
//! each own an identical copy; the behaviour contract is the agreement — this canonical core
//! unifies both copies into one.
//!
//! [`should_rearm`]: UDPReceiveLoopPolicy::should_rearm
//! [`next_backoff`]: UDPReceiveLoopPolicy::next_backoff

/// Stateless namespace for the UDP receive-loop re-arm + backoff policy.
///
/// Modelled as a caseless enum (cannot be constructed); the Swift shell's
/// `enum UDPReceiveLoopPolicy` used purely as a namespace for `static` functions mirrors this.
pub enum UDPReceiveLoopPolicy {}

impl UDPReceiveLoopPolicy {
    /// Smallest re-arm delay after the first consecutive error (5 ms). The Swift shell's
    /// `baseBackoff` mirrors this (internal there; exposed here as a documented contract value
    /// for the Android consumer and the tests).
    pub const BASE_BACKOFF: f64 = 0.005;

    /// Capped re-arm delay so a long ECONNREFUSED storm settles at ~250 ms, not a spin. The
    /// Swift shell's `maxBackoff` mirrors this.
    pub const MAX_BACKOFF: f64 = 0.25;

    /// The largest shift exponent applied to [`BASE_BACKOFF`](Self::BASE_BACKOFF), capping
    /// `consecutiveErrors - 1`. `2^16 · 5 ms ≫ 250 ms` cap, so the cap dominates long before this
    /// and a very large error count cannot overflow the shift.
    const MAX_EXPONENT: i64 = 16;

    /// Re-arm the receive loop iff the flow/connection is still alive. A per-datagram error does
    /// NOT stop the loop; only a dead flow does. (Pure identity over the liveness signal.)
    #[must_use]
    pub const fn should_rearm(connection_is_alive: bool) -> bool {
        connection_is_alive
    }

    /// The delay (seconds — Swift `TimeInterval`) before re-arming the UDP `receiveMessage` loop
    /// after an ERROR-bearing completion, given how many errors have arrived back-to-back without
    /// an intervening good datagram.
    ///
    /// `baseBackoff · 2^(n-1)`, capped at `maxBackoff`. `n ≤ 0` ⇒ no error ⇒ `0.0` (immediate
    /// re-arm — the hot path resets the count to 0 on the first good datagram). The shift exponent
    /// is capped at [`MAX_EXPONENT`](Self::MAX_EXPONENT) so a large `n` cannot overflow.
    ///
    /// `consecutive_errors` is the number of back-to-back errors INCLUDING the one just observed
    /// (`0` ⇒ no error, immediate re-arm).
    #[must_use]
    pub const fn next_backoff(consecutive_errors: i64) -> f64 {
        // Swift: `guard consecutiveErrors > 0 else { return 0 }`.
        if consecutive_errors <= 0 {
            return 0.0;
        }
        // Swift: `min(consecutiveErrors - 1, 16)`. `consecutive_errors >= 1` here, so
        // `consecutive_errors - 1 >= 0` (no underflow) and lands in `[0, 16]`.
        let exponent: u32 = if consecutive_errors - 1 < Self::MAX_EXPONENT {
            (consecutive_errors - 1) as u32
        } else {
            Self::MAX_EXPONENT as u32
        };
        // Swift: `baseBackoff * Double(1 << exponent)`. `exponent <= 16`, so `1u64 << exponent`
        // is at most 65536 — no overflow. Cast preserves the left-to-right float op order.
        let scaled = Self::BASE_BACKOFF * (1u64 << exponent) as f64;
        // Swift global `min(scaled, maxBackoff)` == `maxBackoff < scaled ? maxBackoff : scaled`.
        // Inputs are always finite here, so this agrees with `f64::min`; the ternary mirrors the
        // Swift definition exactly.
        if Self::MAX_BACKOFF < scaled {
            Self::MAX_BACKOFF
        } else {
            scaled
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Same accuracy threshold as the Swift `UDPReceiveLoopPolicyTests` (`accuracy: 1e-9`).
    const EPS: f64 = 1e-9;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() <= EPS, "{a} !~= {b}");
    }

    // MARK: BUG-L — re-arm iff the flow is alive (the Swift `UDPReceiveLoopPolicyTests` suite cross-checks the same).

    #[test]
    fn rearms_while_flow_alive() {
        assert!(UDPReceiveLoopPolicy::should_rearm(true));
    }

    #[test]
    fn stops_when_flow_dead() {
        assert!(!UDPReceiveLoopPolicy::should_rearm(false));
    }

    // MARK: F3 — consecutive-error backoff (no busy-loop) cases (the Swift `UDPReceiveLoopPolicyTests` suite cross-checks the same).

    #[test]
    fn no_backoff_without_error() {
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(0), 0.0);
    }

    #[test]
    fn backoff_grows_exponentially_from_base() {
        approx(UDPReceiveLoopPolicy::next_backoff(1), 0.005);
        approx(UDPReceiveLoopPolicy::next_backoff(2), 0.010);
        approx(UDPReceiveLoopPolicy::next_backoff(3), 0.020);
        approx(UDPReceiveLoopPolicy::next_backoff(4), 0.040);
        approx(UDPReceiveLoopPolicy::next_backoff(5), 0.080);
    }

    #[test]
    fn backoff_is_capped() {
        approx(UDPReceiveLoopPolicy::next_backoff(6), 0.160); // last value below the cap
        approx(UDPReceiveLoopPolicy::next_backoff(7), 0.250); // 5·2^6 = 320ms → cap
        approx(UDPReceiveLoopPolicy::next_backoff(100), 0.250); // no overflow
    }

    #[test]
    fn backoff_resets_to_immediate_after_success() {
        approx(UDPReceiveLoopPolicy::next_backoff(5), 0.080);
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(0), 0.0); // good datagram resets
    }

    // MARK: added edge cases (the spec's enumeration).

    /// `should_rearm` is a pure identity over its argument.
    #[test]
    fn should_rearm_is_identity() {
        for alive in [true, false] {
            assert_eq!(UDPReceiveLoopPolicy::should_rearm(alive), alive);
        }
    }

    /// Swift's `guard consecutiveErrors > 0` treats every non-positive count as "no error" ⇒
    /// immediate re-arm. (Rust never reaches the subtraction for these, so there is no underflow.)
    #[test]
    fn non_positive_counts_are_immediate() {
        for n in [0_i64, -1, -2, -100, i64::MIN] {
            assert_eq!(UDPReceiveLoopPolicy::next_backoff(n), 0.0, "n = {n}");
        }
    }

    /// The doubling chain below the cap is an EXACT power-of-two scaling of `BASE_BACKOFF`
    /// (incrementing the float exponent), so the bits land on the decimal literals exactly.
    #[test]
    fn backoff_doubling_is_bit_exact() {
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(1), 0.005);
        assert_eq!(
            UDPReceiveLoopPolicy::next_backoff(1),
            UDPReceiveLoopPolicy::BASE_BACKOFF
        );
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(2), 0.01);
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(3), 0.02);
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(4), 0.04);
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(5), 0.08);
        assert_eq!(UDPReceiveLoopPolicy::next_backoff(6), 0.16);
    }

    /// Once `scaled` exceeds the cap, the result is EXACTLY `MAX_BACKOFF` (the ternary returns the
    /// constant unchanged) for every count up to the largest representable.
    #[test]
    fn cap_returns_exactly_max_backoff() {
        for n in [7_i64, 8, 16, 17, 100, 1_000, 1_000_000, i64::MAX] {
            assert_eq!(
                UDPReceiveLoopPolicy::next_backoff(n),
                UDPReceiveLoopPolicy::MAX_BACKOFF,
                "n = {n}",
            );
        }
    }

    /// The exponent cap boundary: `n - 1 == 16` (the largest uncapped exponent) still overshoots
    /// the cap, and `n - 1 > 16` is clamped to the same shift — both saturate to `MAX_BACKOFF`,
    /// and a huge `n` neither overflows the shift nor panics.
    #[test]
    fn exponent_cap_and_large_counts_saturate() {
        // exponent = min(16, 16) = 16 → 5ms · 65536 = 327.68s → cap.
        assert_eq!(
            UDPReceiveLoopPolicy::next_backoff(17),
            UDPReceiveLoopPolicy::MAX_BACKOFF
        );
        // exponent capped at 16 again; the value is the cap regardless of how large n grows
        // (and a huge n neither overflows the shift nor panics).
        assert_eq!(
            UDPReceiveLoopPolicy::next_backoff(i64::MAX),
            UDPReceiveLoopPolicy::MAX_BACKOFF,
        );
    }

    /// The backoff is monotonically non-decreasing in the error count and never below 0 nor above
    /// the cap.
    #[test]
    fn backoff_is_monotonic_and_bounded() {
        let mut prev = UDPReceiveLoopPolicy::next_backoff(0);
        assert_eq!(prev, 0.0);
        for n in 1..=64_i64 {
            let cur = UDPReceiveLoopPolicy::next_backoff(n);
            assert!(cur >= prev, "n = {n}: {cur} < {prev}");
            assert!(
                (0.0..=UDPReceiveLoopPolicy::MAX_BACKOFF).contains(&cur),
                "n = {n}: {cur}"
            );
            prev = cur;
        }
        assert_eq!(prev, UDPReceiveLoopPolicy::MAX_BACKOFF);
    }

    /// Both entry points are usable in a `const` context (the port keeps them `const fn`).
    #[test]
    fn usable_in_const_context() {
        const REARM: bool = UDPReceiveLoopPolicy::should_rearm(true);
        const FIRST: f64 = UDPReceiveLoopPolicy::next_backoff(1);
        const CAPPED: f64 = UDPReceiveLoopPolicy::next_backoff(1_000);
        assert_eq!(REARM, UDPReceiveLoopPolicy::should_rearm(true));
        assert_eq!(FIRST, UDPReceiveLoopPolicy::BASE_BACKOFF);
        assert_eq!(CAPPED, UDPReceiveLoopPolicy::MAX_BACKOFF);
    }
}
