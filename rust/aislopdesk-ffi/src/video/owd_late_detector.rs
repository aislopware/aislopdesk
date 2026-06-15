//! `owd_late_detector`: opaque handle (client per-frame one-way-delay spike detector). Driven on
//! the client session actor: one `note()` per strictly-newer decoded frame, returning the
//! deviation above threshold when the sample is a network-late spike. Per-frame cadence, scalar
//! in/out. One owner (`AislopdeskVideoClientSession`), actor-serialized. Env knobs stay resolved
//! Swift-side and cross as the four resolved Config scalars. Same "Rust owns the state" boundary
//! as the deduper.

use crate::{free_handle, into_handle};
use aislopdesk_core::owd_late_detector::{Config as OwdLateConfig, OwdLateDetector};

/// Opaque client one-way-delay spike detector.
///
/// Create with [`aisd_owd_late_detector_new`] (resolved `Config` scalars), fold samples with
/// [`aisd_owd_late_detector_note`], destroy with [`aisd_owd_late_detector_free`]. One per client
/// session; not thread-safe (drive it from a single isolation domain / actor).
pub struct AisdOwdLateDetector {
    inner: OwdLateDetector,
}

/// Creates an OWD spike detector from the resolved config scalars. Destroy it with
/// [`aisd_owd_late_detector_free`].
///
/// `bucket_ms` / `threshold_floor_ms` / `threshold_interval_fraction` / `warmup_samples` are the
/// already-env-resolved [`OwdLateConfig`] fields (the core stays env-free; the caller resolves
/// `AISLOPDESK_OWD_LATE_*` Swift-side). Wraps [`OwdLateDetector::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_owd_late_detector_new(
    bucket_ms: f64,
    threshold_floor_ms: f64,
    threshold_interval_fraction: f64,
    warmup_samples: usize,
) -> *mut AisdOwdLateDetector {
    into_handle(AisdOwdLateDetector {
        inner: OwdLateDetector::new(OwdLateConfig {
            bucket_ms,
            threshold_floor_ms,
            threshold_interval_fraction,
            warmup_samples,
        }),
    })
}

/// Destroys a detector created by [`aisd_owd_late_detector_new`]. No-op on null.
///
/// # Safety
/// `detector` must be a pointer from [`aisd_owd_late_detector_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_owd_late_detector_free(detector: *mut AisdOwdLateDetector) {
    // SAFETY: per the contract, `detector` is an unfreed handle from `aisd_owd_late_detector_new`.
    unsafe { free_handle(detector) }
}

/// Folds one per-frame sample.
///
/// Returns `1` and writes the deviation above threshold (ms) to `out_deviation` when the sample is
/// a network-late spike, else `0` (leaving `out_deviation` untouched). Returns `0` for a null
/// handle (a missing detector never reports late). Wraps [`OwdLateDetector::note`].
///
/// # Safety
/// `detector`, if non-null, must be a live handle; `out_deviation`, if the return is `1`, must be
/// writable.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_owd_late_detector_note(
    detector: *mut AisdOwdLateDetector,
    arrival_ms: f64,
    send_ts: u32,
    interval_ms: f64,
    out_deviation: *mut f64,
) -> u8 {
    // SAFETY: a non-null `detector` is a live handle per the contract.
    match unsafe { detector.as_mut() }.and_then(|d| d.inner.note(arrival_ms, send_ts, interval_ms))
    {
        Some(dev) if !out_deviation.is_null() => {
            // SAFETY: `out_deviation` is non-null per the guard and writable per the contract.
            unsafe { out_deviation.write(dev) };
            1
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn owd_late_detector_handle_flags_spikes() {
        unsafe {
            // Defaults: bucket 2000ms, floor 25ms, frac 1.25, warmup 20.
            let d = aisd_owd_late_detector_new(2000.0, 25.0, 1.25, 20);
            assert!(!d.is_null());
            let interval = 1000.0 / 60.0;
            let mut arrival = 5000.0;
            let mut send: u32 = 91_000;
            let mut dev = -1.0;
            // Warm with 30 clean steady samples — none classify late.
            for _ in 0..30 {
                assert_eq!(
                    aisd_owd_late_detector_note(d, arrival, send, interval, &mut dev),
                    0
                );
                arrival += 16.7;
                send = send.wrapping_add(17);
            }
            assert_eq!(dev, -1.0); // never written while clean.
            // A 40ms spike past the floor is late, deviation > 10ms.
            arrival += 16.7 + 40.0;
            send = send.wrapping_add(17);
            assert_eq!(
                aisd_owd_late_detector_note(d, arrival, send, interval, &mut dev),
                1
            );
            assert!(dev > 10.0);
            aisd_owd_late_detector_free(d);
            aisd_owd_late_detector_free(core::ptr::null_mut()); // no-op
            // A null handle never reports late.
            assert_eq!(
                aisd_owd_late_detector_note(core::ptr::null_mut(), 0.0, 0, interval, &mut dev),
                0
            );
        }
    }
}
