//! `recovery_request_deduper`: opaque handle (host-session recovery-request dedup). Per recovery
//! burst (a few/sec during loss), NOT per-frame; the actor owns one handle, isolation serializes
//! the calls. The same "Rust owns the state" boundary as the terminal `FrameDecoder`.

use super::slice_in;
use crate::{free_handle, into_handle};
use aislopdesk_core::recovery_request_deduper::RecoveryRequestDeduper;

/// Opaque host-side recovery-request dedup ring.
///
/// Create with [`aisd_recovery_deduper_new`], admit datagrams with
/// [`aisd_recovery_deduper_admit`], destroy with [`aisd_recovery_deduper_free`]. One per host
/// session; not thread-safe (drive it from a single isolation domain).
pub struct AisdRecoveryDeduper {
    inner: RecoveryRequestDeduper,
}

/// Creates a recovery-request deduper. Destroy it with [`aisd_recovery_deduper_free`].
///
/// `window_seconds` drops duplicates for that long after the first sighting (`0` ⇒ always admit);
/// `capacity` is the ring size (floored to 1). Wraps [`RecoveryRequestDeduper::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_recovery_deduper_new(
    window_seconds: f64,
    capacity: usize,
) -> *mut AisdRecoveryDeduper {
    into_handle(AisdRecoveryDeduper {
        inner: RecoveryRequestDeduper::new(window_seconds, capacity),
    })
}

/// Destroys a deduper created by [`aisd_recovery_deduper_new`]. No-op on null.
///
/// # Safety
/// `deduper` must be a pointer from [`aisd_recovery_deduper_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_deduper_free(deduper: *mut AisdRecoveryDeduper) {
    // SAFETY: per the contract, `deduper` is an unfreed handle from `aisd_recovery_deduper_new`.
    unsafe { free_handle(deduper) }
}

/// Admits a recovery-request datagram. Wraps [`RecoveryRequestDeduper::admit`].
///
/// Returns `1` = first sighting within the window (the caller should process it), `0` = a
/// byte-identical duplicate (the caller should drop it).
///
/// FAIL-OPEN: a null handle, or a null `datagram` with a nonzero `len`, returns `1` (process) —
/// never `0` — so a caller bug degrades to the pre-dedup "act on every copy" behaviour rather than
/// silently swallowing a real recovery request. `datagram` may be null only when `len == 0` (an
/// empty datagram admits normally).
///
/// # Safety
/// `deduper` must be a live handle; if `len != 0`, `datagram` must point to at least `len`
/// readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_deduper_admit(
    deduper: *mut AisdRecoveryDeduper,
    datagram: *const u8,
    len: usize,
    now: f64,
) -> u8 {
    if deduper.is_null() || (datagram.is_null() && len != 0) {
        return 1; // fail-open: process rather than drop a real request on a caller error.
    }
    // SAFETY: `deduper` is non-null (checked above) and a live handle per the contract; `datagram`
    // covers `len` readable bytes per the contract (and the null+len check above).
    u8::from(unsafe { (*deduper).inner.admit(slice_in(datagram, len), now) })
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn recovery_deduper_dedups_redundant_burst() {
        let d = aisd_recovery_deduper_new(0.025, 16);
        let wire = [3u8, 0, 0, 0, 50]; // a recovery-request datagram (type byte + body)
        unsafe {
            assert_eq!(
                aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.000),
                1
            );
            assert_eq!(
                aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.005),
                0
            );
            // A distinct datagram is admitted alongside.
            let other = [4u8, 1];
            assert_eq!(
                aisd_recovery_deduper_admit(d, other.as_ptr(), other.len(), 100.006),
                1
            );
            aisd_recovery_deduper_free(d);
            aisd_recovery_deduper_free(core::ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn recovery_deduper_window_expiry_readmits() {
        let d = aisd_recovery_deduper_new(0.020, 16);
        let wire = [3u8, 0, 0, 1, 144];
        unsafe {
            assert_eq!(
                aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.000),
                1
            );
            assert_eq!(
                aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.010),
                0
            );
            assert_eq!(
                aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.025),
                1,
                "ages back to admissible after the window"
            );
            aisd_recovery_deduper_free(d);
        }
    }

    #[test]
    fn recovery_deduper_null_handle_fails_open() {
        // A null handle admits (process) rather than dropping a real recovery request.
        let wire = [3u8, 0];
        assert_eq!(
            unsafe {
                aisd_recovery_deduper_admit(core::ptr::null_mut(), wire.as_ptr(), wire.len(), 0.0)
            },
            1
        );
    }
}
