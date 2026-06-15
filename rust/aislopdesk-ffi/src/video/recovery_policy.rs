//! `recovery_policy`: pure, scalar (per gated frame on the client recovery clock).

use aislopdesk_core::recovery_policy::RecoveryPolicy;

/// Whether the client should escalate a stalled LTR-refresh recovery to a forced IDR,
///
/// given
/// the configured policy multiples, time since the first request, the RTT estimate, and
/// whether it is observing loss.
///
/// Wraps [`RecoveryPolicy::should_escalate_to_idr`].
///
/// `observing_loss` crosses as a byte read `!= 0`. The lossy escalation floor (`lossy_floor_s`,
/// from `AISLOPDESK_ESCALATION_FLOOR_MS`) is resolved by the caller and passed in, keeping the
/// core environment-free. Returns `1` to escalate, `0` otherwise. The four multiples map
/// field-for-field onto [`RecoveryPolicy`].
#[must_use]
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn aisd_recovery_policy_should_escalate_to_idr(
    idr_rtt_mult: f64,
    lossy_idr_rtt_mult: f64,
    lossy_floor_s: f64,
    lossy_floor_rtt_mult: f64,
    elapsed_since_request: f64,
    rtt: f64,
    observing_loss: u8,
) -> u8 {
    let policy = RecoveryPolicy::new(
        idr_rtt_mult,
        lossy_idr_rtt_mult,
        lossy_floor_s,
        lossy_floor_rtt_mult,
    );
    u8::from(policy.should_escalate_to_idr(elapsed_since_request, rtt, observing_loss != 0))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    // recovery_policy: defaults 2.0 normal, 1.0 lossy, 60 ms floor, 1.5 floor-rtt-multiple.
    fn escalate(elapsed: f64, rtt: f64, observing: u8) -> u8 {
        aisd_recovery_policy_should_escalate_to_idr(2.0, 1.0, 0.06, 1.5, elapsed, rtt, observing)
    }

    #[test]
    fn recovery_normal_path_is_two_rtt_no_floor() {
        assert_eq!(escalate(0.19, 0.1, 0), 0);
        assert_eq!(escalate(0.20, 0.1, 0), 1);
        assert_eq!(escalate(0.011, 0.006, 0), 0);
        assert_eq!(escalate(0.012, 0.006, 0), 1);
    }

    #[test]
    fn recovery_lossy_path_floored_and_byte_read() {
        assert_eq!(escalate(0.059, 0.01, 1), 0);
        assert_eq!(escalate(0.060, 0.01, 1), 1);
        assert_eq!(escalate(0.0749, 0.05, 1), 0);
        assert_eq!(escalate(0.0751, 0.05, 1), 1);
        assert_eq!(escalate(0.0751, 0.05, 0), 0); // normal clock still waits 2·RTT
        assert_eq!(escalate(0.030, 0.01, 2), 0); // any nonzero byte = observing loss
        assert_eq!(escalate(0.060, 0.01, 2), 1);
        assert_eq!(escalate(0.060, 0.01, 1), escalate(0.060, 0.01, 2));
    }

    #[test]
    fn recovery_matches_core_over_a_grid() {
        for &observing in &[0u8, 1u8] {
            let mut elapsed = 0.0;
            while elapsed <= 0.3 {
                for &rtt in &[0.005, 0.01, 0.05, 0.1, 0.25] {
                    let policy = RecoveryPolicy::new(2.0, 1.0, 0.06, 1.5);
                    let want =
                        u8::from(policy.should_escalate_to_idr(elapsed, rtt, observing != 0));
                    assert_eq!(escalate(elapsed, rtt, observing), want);
                }
                elapsed += 0.007;
            }
        }
    }
}
