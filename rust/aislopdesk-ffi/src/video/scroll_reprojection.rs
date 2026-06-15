//! `scroll_reprojection`: opaque handle (client scroll-hint reprojection offset law). Driven on
//! the main actor / `FramePacer` lock: `note_velocity` per focused-scroll event, `advance` per
//! spare display tick to integrate + read the offset, `note_real_frame` the instant a real decoded
//! frame is presented (the reset that prevents double-counting). The 2-field config crosses as a
//! flat repr(C) struct by value (env resolved Swift-side); `ScrollPhase` crosses as a u8; the
//! integrated offset comes back through two out-params. One owner (the pane's pipeline). Same
//! "Rust owns the state" boundary as the deduper / pacer-depth policy.

use crate::{AISD_ERR_NULL, AisdStatus, free_handle, into_handle};
use aislopdesk_core::scroll_reprojection::{
    Config as ScrollConfig, ScrollPhase, ScrollReprojector,
};

/// [`ScrollPhase::Active`] discriminant — finger on glass, track velocity (no decay).
pub const AISD_SCROLL_PHASE_ACTIVE: u8 = 0;
/// [`ScrollPhase::Momentum`] discriminant — inertial coast, track velocity (no decay).
pub const AISD_SCROLL_PHASE_MOMENTUM: u8 = 1;
/// [`ScrollPhase::Ended`] discriminant — gesture finished, arm the decay.
pub const AISD_SCROLL_PHASE_ENDED: u8 = 2;

/// The 2 [`ScrollConfig`] tunables, flattened for the C ABI (env resolved Swift-side; crosses by
/// value). Field-for-field with the core `Config`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdScrollReprojectorConfig {
    /// Per-axis clamp on the integrated offset (normalized units).
    pub max_band: f64,
    /// Decay time-constant after a scroll ends (seconds).
    pub decay_seconds: f64,
}

impl AisdScrollReprojectorConfig {
    /// Rebuilds the core [`ScrollConfig`] through the sanitizing constructor (so a hostile knob can
    /// never produce a runaway / negative offset).
    const fn to_core(self) -> ScrollConfig {
        ScrollConfig::sanitized(self.max_band, self.decay_seconds)
    }
}

/// Maps a `AISD_SCROLL_PHASE_*` discriminant to the core [`ScrollPhase`]. An unknown value falls
/// back to [`ScrollPhase::Active`] (track, never silently arm a decay).
const fn scroll_phase_from_c(phase: u8) -> ScrollPhase {
    match phase {
        AISD_SCROLL_PHASE_MOMENTUM => ScrollPhase::Momentum,
        AISD_SCROLL_PHASE_ENDED => ScrollPhase::Ended,
        // AISD_SCROLL_PHASE_ACTIVE and any unknown value.
        _ => ScrollPhase::Active,
    }
}

/// Opaque client scroll-hint reprojector.
///
/// Create with [`aisd_scroll_reprojector_new`] (resolved `Config`), drive it with
/// [`aisd_scroll_reprojector_note_velocity`] / [`aisd_scroll_reprojector_advance`] /
/// [`aisd_scroll_reprojector_note_real_frame`], destroy with [`aisd_scroll_reprojector_free`]. One
/// per pane; not thread-safe (the caller's main actor / pacer lock serializes).
pub struct AisdScrollReprojector {
    inner: ScrollReprojector,
}

/// Creates a scroll reprojector from the resolved config (zero offset / zero velocity). Destroy it
/// with [`aisd_scroll_reprojector_free`]. Wraps [`ScrollReprojector::new`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_scroll_reprojector_new(
    config: AisdScrollReprojectorConfig,
) -> *mut AisdScrollReprojector {
    into_handle(AisdScrollReprojector {
        inner: ScrollReprojector::new(config.to_core()),
    })
}

/// Destroys a reprojector created by [`aisd_scroll_reprojector_new`]. No-op on null.
///
/// # Safety
/// `reprojector` must be a pointer from [`aisd_scroll_reprojector_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_scroll_reprojector_free(reprojector: *mut AisdScrollReprojector) {
    // SAFETY: per the contract, `reprojector` is an unfreed handle from `aisd_scroll_reprojector_new`.
    unsafe { free_handle(reprojector) }
}

/// Folds one scroll-velocity sample (`vx`/`vy` in normalized units per second) with its
/// `AISD_SCROLL_PHASE_*` phase. No-op on null. Wraps [`ScrollReprojector::note_velocity`].
///
/// # Safety
/// `reprojector`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_scroll_reprojector_note_velocity(
    reprojector: *mut AisdScrollReprojector,
    vx: f64,
    vy: f64,
    phase: u8,
) {
    // SAFETY: a non-null `reprojector` is a live handle per the contract.
    if let Some(r) = unsafe { reprojector.as_mut() } {
        r.inner.note_velocity(vx, vy, scroll_phase_from_c(phase));
    }
}

/// Integrates over `elapsed_seconds` (or decays a stopped scroll), clamps, and writes the offset.
///
/// The resulting offset goes into `*out_x` / `*out_y`. Returns [`AISD_ERR_NULL`] for a null handle
/// or a null out-param (the out-params are left untouched), else [`crate::AISD_OK`]. Wraps
/// [`ScrollReprojector::advance`].
///
/// # Safety
/// `reprojector`, if non-null, must be a live handle; `out_x` / `out_y` must be writable, non-null
/// pointers.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_scroll_reprojector_advance(
    reprojector: *mut AisdScrollReprojector,
    elapsed_seconds: f64,
    out_x: *mut f64,
    out_y: *mut f64,
) -> AisdStatus {
    if out_x.is_null() || out_y.is_null() {
        return AISD_ERR_NULL;
    }
    // SAFETY: a non-null `reprojector` is a live handle per the contract.
    let Some(r) = (unsafe { reprojector.as_mut() }) else {
        return AISD_ERR_NULL;
    };
    let (x, y) = r.inner.advance(elapsed_seconds);
    // SAFETY: `out_x` / `out_y` are non-null per the check above and writable per the contract.
    unsafe {
        out_x.write(x);
        out_y.write(y);
    }
    crate::AISD_OK
}

/// Resets the offset (and integration baseline) to exactly zero (the no-double-count reset).
///
/// Call the instant a real decoded frame is presented so the hint is never added on top of the
/// real scroll. The live velocity is preserved. No-op on null. Wraps
/// [`ScrollReprojector::note_real_frame`].
///
/// # Safety
/// `reprojector`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_scroll_reprojector_note_real_frame(
    reprojector: *mut AisdScrollReprojector,
) {
    // SAFETY: a non-null `reprojector` is a live handle per the contract.
    if let Some(r) = unsafe { reprojector.as_mut() } {
        r.inner.note_real_frame();
    }
}

/// Fully resets the reprojector (offset AND velocity to zero) — call when a pane goes idle / loses
/// focus so a stale velocity can never resume. No-op on null. Wraps [`ScrollReprojector::reset`].
///
/// # Safety
/// `reprojector`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_scroll_reprojector_reset(
    reprojector: *mut AisdScrollReprojector,
) {
    // SAFETY: a non-null `reprojector` is a live handle per the contract.
    if let Some(r) = unsafe { reprojector.as_mut() } {
        r.inner.reset();
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::AISD_OK;

    fn default_config() -> AisdScrollReprojectorConfig {
        let c = ScrollConfig::default();
        AisdScrollReprojectorConfig {
            max_band: c.max_band,
            decay_seconds: c.decay_seconds,
        }
    }

    #[test]
    fn scroll_reprojector_handle_integrates_resets_and_clamps() {
        unsafe {
            let r = aisd_scroll_reprojector_new(default_config());
            assert!(!r.is_null());
            let (mut x, mut y) = (0.0, 0.0);
            // Drive a velocity, advance, read a non-zero offset.
            aisd_scroll_reprojector_note_velocity(r, 0.0, 0.2, AISD_SCROLL_PHASE_ACTIVE);
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y),
                AISD_OK
            );
            assert!((y - 0.01).abs() < 1e-9 && x.abs() < 1e-12);
            // A real frame resets the offset to EXACTLY zero (no double-count).
            aisd_scroll_reprojector_note_real_frame(r);
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 0.0, &mut x, &mut y),
                AISD_OK
            );
            assert_eq!((x, y), (0.0, 0.0));
            // The velocity survived: re-integrates from zero.
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y),
                AISD_OK
            );
            assert!((y - 0.01).abs() < 1e-9);
            // A fast flick clamps to the band.
            aisd_scroll_reprojector_note_real_frame(r);
            aisd_scroll_reprojector_note_velocity(r, 0.0, 50.0, AISD_SCROLL_PHASE_MOMENTUM);
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 1.0, &mut x, &mut y),
                AISD_OK
            );
            assert!((y - default_config().max_band).abs() < 1e-9);
            // Ended arms the decay → the offset shrinks.
            aisd_scroll_reprojector_note_velocity(r, 0.0, 0.0, AISD_SCROLL_PHASE_ENDED);
            let before = y;
            let _ = aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y);
            assert!(y < before);
            // reset clears everything.
            aisd_scroll_reprojector_reset(r);
            let _ = aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y);
            assert_eq!((x, y), (0.0, 0.0));

            aisd_scroll_reprojector_free(r);
            // Null-handle behaviour: every fold is a no-op, advance reports NULL and leaves the
            // out-params untouched, free is a no-op.
            aisd_scroll_reprojector_note_velocity(
                core::ptr::null_mut(),
                1.0,
                1.0,
                AISD_SCROLL_PHASE_ACTIVE,
            );
            aisd_scroll_reprojector_note_real_frame(core::ptr::null_mut());
            aisd_scroll_reprojector_reset(core::ptr::null_mut());
            x = 7.0;
            y = 9.0;
            assert_eq!(
                aisd_scroll_reprojector_advance(core::ptr::null_mut(), 0.1, &mut x, &mut y),
                AISD_ERR_NULL
            );
            assert_eq!((x, y), (7.0, 9.0)); // untouched
            aisd_scroll_reprojector_free(core::ptr::null_mut());
        }
    }

    #[test]
    fn advance_null_out_params_is_null_error() {
        unsafe {
            let r = aisd_scroll_reprojector_new(default_config());
            let mut x = 0.0;
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 0.1, core::ptr::null_mut(), &mut x),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_scroll_reprojector_advance(r, 0.1, &mut x, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            aisd_scroll_reprojector_free(r);
        }
    }
}
