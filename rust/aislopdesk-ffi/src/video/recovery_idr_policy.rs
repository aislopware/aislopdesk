//! `recovery_idr_policy`: opaque handle (host delivery-keyed recovery-IDR admission). Driven on
//! the host session actor: `note_keyframe_sent` per encoded keyframe, `note_keyframe_delivered`
//! per ack, `decide()` per recovery request (NOT per-frame). One owner
//! (`AislopdeskVideoHostSession`), actor-serialized. Env knobs stay resolved Swift-side and cross
//! as the seven Config scalars. Verdict crosses as a u8 discriminant. Same "Rust owns the state"
//! boundary as the deduper.

use crate::{free_handle, into_handle};
use aislopdesk_core::recovery_idr_policy::{
    Config as RecoveryIdrConfig, RecoveryIdrPolicy, Verdict as RecoveryIdrVerdict,
};

/// [`RecoveryIdrVerdict::Grant`] discriminant — force a real IDR now (token-gated).
pub const AISD_RECOVERY_IDR_GRANT: u8 = 0;
/// [`RecoveryIdrVerdict::SuppressGrantPending`] discriminant — a grant is already latched.
pub const AISD_RECOVERY_IDR_SUPPRESS_GRANT_PENDING: u8 = 1;
/// [`RecoveryIdrVerdict::SuppressStale`] discriminant — the request predates an acked keyframe.
pub const AISD_RECOVERY_IDR_SUPPRESS_STALE: u8 = 2;
/// [`RecoveryIdrVerdict::SuppressInFlight`] discriminant — the newest keyframe may still arrive.
pub const AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT: u8 = 3;
/// [`RecoveryIdrVerdict::SuppressRateLimited`] discriminant — the token bucket is empty.
pub const AISD_RECOVERY_IDR_SUPPRESS_RATE_LIMITED: u8 = 4;

const fn recovery_idr_verdict_to_c(v: RecoveryIdrVerdict) -> u8 {
    match v {
        RecoveryIdrVerdict::Grant => AISD_RECOVERY_IDR_GRANT,
        RecoveryIdrVerdict::SuppressGrantPending => AISD_RECOVERY_IDR_SUPPRESS_GRANT_PENDING,
        RecoveryIdrVerdict::SuppressStale => AISD_RECOVERY_IDR_SUPPRESS_STALE,
        RecoveryIdrVerdict::SuppressInFlight => AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT,
        RecoveryIdrVerdict::SuppressRateLimited => AISD_RECOVERY_IDR_SUPPRESS_RATE_LIMITED,
    }
}

/// Opaque host delivery-keyed recovery-IDR admission policy.
///
/// Create with [`aisd_recovery_idr_policy_new`] (resolved `Config` scalars), drive it with the
/// `_note_keyframe_*` / `_decide` calls, destroy with [`aisd_recovery_idr_policy_free`]. One per
/// host session; not thread-safe (drive it from a single isolation domain / actor).
pub struct AisdRecoveryIdrPolicy {
    inner: RecoveryIdrPolicy,
}

/// Creates a recovery-IDR policy from the resolved config scalars. Destroy it with
/// [`aisd_recovery_idr_policy_free`].
///
/// The seven scalars are the already-env-resolved [`RecoveryIdrConfig`] fields (the core stays
/// env-free; the caller resolves `AISLOPDESK_IDR_*` Swift-side). Wraps [`RecoveryIdrPolicy::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_recovery_idr_policy_new(
    grace_fraction: f64,
    grace_floor_seconds: f64,
    grace_ceil_seconds: f64,
    bucket_capacity: f64,
    refill_tokens_per_second: f64,
    grant_pending_timeout: f64,
    keyframe_ring_capacity: usize,
) -> *mut AisdRecoveryIdrPolicy {
    into_handle(AisdRecoveryIdrPolicy {
        inner: RecoveryIdrPolicy::new(RecoveryIdrConfig {
            grace_fraction,
            grace_floor_seconds,
            grace_ceil_seconds,
            bucket_capacity,
            refill_tokens_per_second,
            grant_pending_timeout,
            keyframe_ring_capacity,
        }),
    })
}

/// Destroys a policy created by [`aisd_recovery_idr_policy_new`]. No-op on null.
///
/// # Safety
/// `policy` must be a pointer from [`aisd_recovery_idr_policy_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_free(policy: *mut AisdRecoveryIdrPolicy) {
    // SAFETY: per the contract, `policy` is an unfreed handle from `aisd_recovery_idr_policy_new`.
    unsafe { free_handle(policy) }
}

/// The current token-bucket level (observability / tests), or `0.0` for a null handle.
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_available_tokens(
    policy: *const AisdRecoveryIdrPolicy,
) -> f64 {
    // SAFETY: a non-null `policy` is a live handle per the contract.
    unsafe { policy.as_ref() }.map_or(0.0, |p| p.inner.available_tokens())
}

/// Records that a keyframe was handed to the wire at `now`. No-op on null. Wraps
/// [`RecoveryIdrPolicy::note_keyframe_sent`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_note_keyframe_sent(
    policy: *mut AisdRecoveryIdrPolicy,
    frame_id: u32,
    now: f64,
) {
    // SAFETY: a non-null `policy` is a live handle per the contract.
    if let Some(p) = unsafe { policy.as_mut() } {
        p.inner.note_keyframe_sent(frame_id, now);
    }
}

/// Records that the client decode-ACKed a keyframe. No-op on null. Wraps
/// [`RecoveryIdrPolicy::note_keyframe_delivered`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_note_keyframe_delivered(
    policy: *mut AisdRecoveryIdrPolicy,
    frame_id: u32,
) {
    // SAFETY: a non-null `policy` is a live handle per the contract.
    if let Some(p) = unsafe { policy.as_mut() } {
        p.inner.note_keyframe_delivered(frame_id);
    }
}

/// The admission decision for one IDR-issuing recovery request, as an `AISD_RECOVERY_IDR_*`
/// discriminant.
///
/// `has_client_last_decoded == 0` ⇒ the wire sentinel "nothing decoded yet" (`client_last_decoded`
/// is then ignored). Returns Grant (`0`) for a null handle (recovery proceeds rather than
/// wedging). Wraps [`RecoveryIdrPolicy::decide`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_decide(
    policy: *mut AisdRecoveryIdrPolicy,
    now: f64,
    client_last_decoded: u32,
    has_client_last_decoded: u8,
    smoothed_rtt_seconds: f64,
) -> u8 {
    let last = if has_client_last_decoded != 0 {
        Some(client_last_decoded)
    } else {
        None
    };
    // SAFETY: a non-null `policy` is a live handle per the contract.
    unsafe { policy.as_mut() }.map_or(AISD_RECOVERY_IDR_GRANT, |p| {
        recovery_idr_verdict_to_c(p.inner.decide(now, last, smoothed_rtt_seconds))
    })
}

/// The in-flight grace window (seconds) for the given smoothed RTT, or `0.0` for a null handle.
/// Wraps [`RecoveryIdrPolicy::grace`].
///
/// # Safety
/// `policy`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_idr_policy_grace(
    policy: *const AisdRecoveryIdrPolicy,
    rtt: f64,
) -> f64 {
    // SAFETY: a non-null `policy` is a live handle per the contract.
    unsafe { policy.as_ref() }.map_or(0.0, |p| p.inner.grace(rtt))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn recovery_idr_policy_handle_gates_grants() {
        unsafe {
            // Defaults: grace 0.75/[0.040,0.250], bucket 2, refill 2/s, grant-pending 1.5, ring 4.
            let p = aisd_recovery_idr_policy_new(0.75, 0.040, 0.250, 2.0, 2.0, 1.5, 4);
            assert!(!p.is_null());
            assert_eq!(aisd_recovery_idr_policy_available_tokens(p), 2.0);
            // First request (nothing decoded yet, no keyframe sent) grants and spends a token.
            assert_eq!(
                aisd_recovery_idr_policy_decide(p, 10.0, 0, 0, 0.05),
                AISD_RECOVERY_IDR_GRANT
            );
            assert_eq!(aisd_recovery_idr_policy_available_tokens(p), 1.0);
            // A fresh keyframe in flight ⇒ a behind client is suppressed within the grace window.
            aisd_recovery_idr_policy_note_keyframe_sent(p, 100, 5.0);
            assert_eq!(
                aisd_recovery_idr_policy_decide(p, 5.02, 99, 1, 0.05),
                AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT
            );
            // grace() is the clamped fraction.
            assert!((aisd_recovery_idr_policy_grace(p, 0.0) - 0.040).abs() < 1e-9);
            // A request older than an acked keyframe is stale.
            aisd_recovery_idr_policy_note_keyframe_delivered(p, 100);
            assert_eq!(
                aisd_recovery_idr_policy_decide(p, 9.0, 99, 1, 0.05),
                AISD_RECOVERY_IDR_SUPPRESS_STALE
            );
            aisd_recovery_idr_policy_free(p);
            aisd_recovery_idr_policy_free(core::ptr::null_mut()); // no-op
            // A null handle grants (recovery proceeds) and reports zero tokens/grace.
            assert_eq!(
                aisd_recovery_idr_policy_decide(core::ptr::null_mut(), 0.0, 0, 0, 0.0),
                AISD_RECOVERY_IDR_GRANT
            );
            assert_eq!(
                aisd_recovery_idr_policy_available_tokens(core::ptr::null()),
                0.0
            );
            assert_eq!(aisd_recovery_idr_policy_grace(core::ptr::null(), 1.0), 0.0);
        }
    }
}
