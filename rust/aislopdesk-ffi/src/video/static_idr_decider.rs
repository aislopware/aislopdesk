//! `static_idr_decider`: opaque handle (host static-window forced-IDR heartbeat). Driven on the
//! capture frameQueue: `should_reencode` per timer tick, `on_complete_frame` per real frame,
//! `record_synthetic` per synthetic emission — per-frame cadence, never per-fragment. One owner
//! (`WindowCapturer`), frameQueue-serialized, same "Rust owns the state" boundary as the deduper.

use crate::{free_handle, into_handle};
use aislopdesk_core::static_idr_decider::StaticIDRDecider;

/// Opaque host static-window forced-IDR decider.
///
/// Create with [`aisd_static_idr_decider_new`], drive it with the `_on_complete_frame` /
/// `_record_synthetic` / `_should_reencode` calls, destroy with [`aisd_static_idr_decider_free`].
/// One per capturer; not thread-safe (drive it from a single isolation domain / queue).
pub struct AisdStaticIdrDecider {
    inner: StaticIDRDecider,
}

/// Creates a static-IDR decider. Destroy it with [`aisd_static_idr_decider_free`].
///
/// `heartbeat` is the cadence in seconds. `has_quiet_window != 0` sets the quiet window to
/// `quiet_window`; otherwise the core default (one cadence = `heartbeat`) is used. Wraps
/// [`StaticIDRDecider::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_static_idr_decider_new(
    heartbeat: f64,
    quiet_window: f64,
    has_quiet_window: u8,
) -> *mut AisdStaticIdrDecider {
    let quiet = if has_quiet_window != 0 {
        Some(quiet_window)
    } else {
        None
    };
    into_handle(AisdStaticIdrDecider {
        inner: StaticIDRDecider::new(heartbeat, quiet),
    })
}

/// Destroys a decider created by [`aisd_static_idr_decider_new`]. No-op on null.
///
/// # Safety
/// `decider` must be a pointer from [`aisd_static_idr_decider_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_free(decider: *mut AisdStaticIdrDecider) {
    // SAFETY: per the contract, `decider` is an unfreed handle from `aisd_static_idr_decider_new`.
    unsafe { free_handle(decider) }
}

/// The configured heartbeat cadence (seconds), or `0.0` for a null handle.
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_heartbeat(
    decider: *const AisdStaticIdrDecider,
) -> f64 {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    unsafe { decider.as_ref() }.map_or(0.0, |d| d.inner.heartbeat())
}

/// The configured quiet window (seconds), or `0.0` for a null handle.
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_quiet_window(
    decider: *const AisdStaticIdrDecider,
) -> f64 {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    unsafe { decider.as_ref() }.map_or(0.0, |d| d.inner.quiet_window())
}

/// Uptime seconds of the last REAL `.complete`-frame encode (`0.0` = none / null handle).
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_last_complete_encode(
    decider: *const AisdStaticIdrDecider,
) -> f64 {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    unsafe { decider.as_ref() }.map_or(0.0, |d| d.inner.last_complete_encode())
}

/// Uptime seconds of the last SYNTHETIC re-encode (`0.0` = none / null handle).
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_last_synthetic_encode(
    decider: *const AisdStaticIdrDecider,
) -> f64 {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    unsafe { decider.as_ref() }.map_or(0.0, |d| d.inner.last_synthetic_encode())
}

/// Re-anchors the live clock: a REAL `.complete` frame was encoded at `now`. No-op on null.
/// Wraps [`StaticIDRDecider::on_complete_frame`].
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_static_idr_decider_on_complete_frame(
    decider: *mut AisdStaticIdrDecider,
    now: f64,
) {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    if let Some(d) = unsafe { decider.as_mut() } {
        d.inner.on_complete_frame(now);
    }
}

/// Re-anchors the synthetic clock: the timer fired a synthetic re-encode at `now`. No-op on null.
/// Wraps [`StaticIDRDecider::record_synthetic`].
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_static_idr_decider_record_synthetic(
    decider: *mut AisdStaticIdrDecider,
    now: f64,
) {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    if let Some(d) = unsafe { decider.as_mut() } {
        d.inner.record_synthetic(now);
    }
}

/// Whether the caller should re-encode the cached buffer as a forced IDR now.
///
/// Wraps [`StaticIDRDecider::should_reencode`]. `forced_latched` / `has_retained_buffer` are
/// bytes read `!= 0`. Returns `1` to re-encode, `0` otherwise (and `0` for a null handle — a
/// missing decider never forces an encode).
///
/// # Safety
/// `decider`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_static_idr_decider_should_reencode(
    decider: *const AisdStaticIdrDecider,
    now: f64,
    forced_latched: u8,
    has_retained_buffer: u8,
) -> u8 {
    // SAFETY: a non-null `decider` is a live handle per the contract.
    unsafe { decider.as_ref() }.map_or(0, |d| {
        u8::from(
            d.inner
                .should_reencode(now, forced_latched != 0, has_retained_buffer != 0),
        )
    })
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn static_idr_decider_handle_drives_cadence() {
        unsafe {
            // Default quiet window == heartbeat (has_quiet_window = 0).
            let d = aisd_static_idr_decider_new(1.0, 0.0, 0);
            assert!(!d.is_null());
            assert_eq!(aisd_static_idr_decider_heartbeat(d), 1.0);
            assert_eq!(aisd_static_idr_decider_quiet_window(d), 1.0);
            // Armed, none emitted yet, no real frame ⇒ fire.
            assert_eq!(aisd_static_idr_decider_should_reencode(d, 0.5, 0, 1), 1);
            // No retained buffer ⇒ never fire.
            assert_eq!(aisd_static_idr_decider_should_reencode(d, 50.0, 1, 0), 0);
            // A real frame at t=10 ⇒ quiet window suppresses for < heartbeat after.
            aisd_static_idr_decider_on_complete_frame(d, 10.0);
            assert_eq!(aisd_static_idr_decider_last_complete_encode(d), 10.0);
            assert_eq!(aisd_static_idr_decider_should_reencode(d, 10.5, 0, 1), 0);
            // Past the heartbeat after the real frame ⇒ fire.
            assert_eq!(aisd_static_idr_decider_should_reencode(d, 11.0, 0, 1), 1);
            // Synthetic re-anchors the cadence.
            aisd_static_idr_decider_record_synthetic(d, 11.0);
            assert_eq!(aisd_static_idr_decider_last_synthetic_encode(d), 11.0);
            assert_eq!(aisd_static_idr_decider_should_reencode(d, 11.5, 0, 1), 0);
            aisd_static_idr_decider_free(d);
            aisd_static_idr_decider_free(core::ptr::null_mut()); // no-op
            // A null handle never forces an encode.
            assert_eq!(
                aisd_static_idr_decider_should_reencode(core::ptr::null(), 0.0, 1, 1),
                0
            );
            // An explicit quiet window is honoured.
            let d2 = aisd_static_idr_decider_new(2.5, 1.0, 1);
            assert_eq!(aisd_static_idr_decider_quiet_window(d2), 1.0);
            aisd_static_idr_decider_free(d2);
        }
    }
}
