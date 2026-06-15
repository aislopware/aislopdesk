//! `coordinate_mapping`: pure, scalar (per pointer event; FFI cost dwarfed by the `CGEvent`
//! post it precedes, so it swaps unconditionally — no per-frame buffers).
//!
//! Also home to the shared flat geometry types [`AisdPoint`] / [`AisdRect`] / [`AisdScreenInfo`]
//! reused by the `window_placement`, `capture_region`, and `virtual_display_geometry` siblings.

use crate::{AISD_EMPTY, AISD_ERR_NULL, AISD_OK, AisdStatus};
use aislopdesk_core::coordinate_mapping::{self, ScreenInfo};
use aislopdesk_core::geometry::{VideoPoint, VideoRect};

/// A 2-D point in host points, flattened for the C ABI (field-for-field [`VideoPoint`]).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPoint {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl AisdPoint {
    pub(crate) const fn to_core(self) -> VideoPoint {
        VideoPoint::new(self.x, self.y)
    }
    pub(crate) const fn from_core(p: VideoPoint) -> Self {
        Self { x: p.x, y: p.y }
    }
}

/// A rectangle (origin + size), flattened for the C ABI (`x, y, width, height`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdRect {
    /// Origin x.
    pub x: f64,
    /// Origin y.
    pub y: f64,
    /// Extent width.
    pub width: f64,
    /// Extent height.
    pub height: f64,
}

impl AisdRect {
    pub(crate) const fn to_core(self) -> VideoRect {
        VideoRect::xywh(self.x, self.y, self.width, self.height)
    }
    pub(crate) const fn from_core(r: VideoRect) -> Self {
        Self {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        }
    }
}

/// A display (Cocoa-bottom-left frame + Retina backing scale), flattened for the C ABI.
/// Passed in as a borrowed array, never freed by Rust.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdScreenInfo {
    /// The screen's frame in Cocoa bottom-left space (`NSScreen.frame`).
    pub cocoa_frame: AisdRect,
    /// `NSScreen.backingScaleFactor` (1.0 standard, 2.0 Retina).
    pub backing_scale_factor: f64,
}

impl AisdScreenInfo {
    const fn to_core(self) -> ScreenInfo {
        ScreenInfo::new(self.cocoa_frame.to_core(), self.backing_scale_factor)
    }
}

/// Maps a normalised (0..1) window point to a host-window point in CG top-left space (no Y
/// flip, no scale). Wraps [`coordinate_mapping::window_point`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_coord_window_point(
    normalized: AisdPoint,
    window_bounds: AisdRect,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point(
        normalized.to_core(),
        window_bounds.to_core(),
    ))
}

/// Flips a CG-top-left rect into Cocoa bottom-left space given the primary display height.
/// Wraps [`coordinate_mapping::cg_rect_to_cocoa`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_coord_cg_rect_to_cocoa(cg_rect: AisdRect, primary_height: f64) -> AisdRect {
    AisdRect::from_core(coordinate_mapping::cg_rect_to_cocoa(
        cg_rect.to_core(),
        primary_height,
    ))
}

/// Picks the screen a window lives on (largest overlap) and writes its `backing_scale_factor`
/// to `*out_scale`.
///
/// Wraps [`coordinate_mapping::backing_scale_factor`]. Returns [`AISD_OK`]
/// (overlap; `*out_scale` written), [`AISD_EMPTY`] (no overlap; `*out_scale` untouched), or
/// [`AISD_ERR_NULL`] if `out_scale` is null, or `screens` is null while `screen_count != 0`.
/// `screens` is borrowed for the call only.
///
/// # Safety
/// `out_scale` must be a writable `f64`; if `screen_count != 0`, `screens` must point to at
/// least `screen_count` readable [`AisdScreenInfo`] values.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_coord_backing_scale_factor(
    window_bounds_cg: AisdRect,
    screens: *const AisdScreenInfo,
    screen_count: usize,
    primary_height: f64,
    out_scale: *mut f64,
) -> AisdStatus {
    if out_scale.is_null() || (screens.is_null() && screen_count != 0) {
        return AISD_ERR_NULL;
    }
    let core_screens: Vec<ScreenInfo> = if screen_count == 0 {
        Vec::new()
    } else {
        // SAFETY: `screens` is non-null per the check above and covers `screen_count`
        // readable `AisdScreenInfo` values per the contract.
        unsafe { core::slice::from_raw_parts(screens, screen_count) }
            .iter()
            .map(|s| s.to_core())
            .collect()
    };
    coordinate_mapping::backing_scale_factor(
        window_bounds_cg.to_core(),
        &core_screens,
        primary_height,
    )
    .map_or(AISD_EMPTY, |scale| {
        // SAFETY: `out_scale` is non-null per the check above and writable per the contract.
        unsafe { out_scale.write(scale) };
        AISD_OK
    })
}

/// Pixel path: divide by `backing_scale_factor` to get points, then add the window origin.
/// Wraps [`coordinate_mapping::window_point_from_pixel`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_coord_window_point_from_pixel(
    pixel: AisdPoint,
    window_bounds_cg: AisdRect,
    backing_scale_factor: f64,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point_from_pixel(
        pixel.to_core(),
        window_bounds_cg.to_core(),
        backing_scale_factor,
    ))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn coord_window_point_matches_core() {
        let p = aisd_coord_window_point(
            AisdPoint { x: 0.5, y: 0.5 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(p.x, 500.0);
        approx(p.y, 500.0);
        let c = aisd_coord_window_point(
            AisdPoint { x: 1.0, y: 1.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(c.x, 900.0);
        approx(c.y, 800.0);
    }

    #[test]
    fn coord_cg_to_cocoa_flip_matches_core() {
        let r = aisd_coord_cg_rect_to_cocoa(
            AisdRect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            1080.0,
        );
        approx(r.x, 0.0);
        approx(r.y, 880.0);
        approx(r.width, 400.0);
        approx(r.height, 200.0);
    }

    #[test]
    fn coord_backing_scale_picks_retina_after_flip() {
        let screens = [
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 0.0,
                    width: 1920.0,
                    height: 1080.0,
                },
                backing_scale_factor: 1.0,
            },
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 1080.0,
                    width: 2560.0,
                    height: 1440.0,
                },
                backing_scale_factor: 2.0,
            },
        ];
        let win = AisdRect {
            x: 100.0,
            y: -1000.0,
            width: 1280.0,
            height: 800.0,
        };
        let mut scale = 0.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_OK);
        approx(scale, 2.0);
    }

    #[test]
    fn coord_backing_scale_no_overlap_and_null() {
        let screens = [AisdScreenInfo {
            cocoa_frame: AisdRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            backing_scale_factor: 1.0,
        }];
        let win = AisdRect {
            x: 10_000.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let mut scale = -1.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_EMPTY);
        approx(scale, -1.0); // untouched on AISD_EMPTY
        // null out_scale => AISD_ERR_NULL; null screens + count 0 => empty => AISD_EMPTY.
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(
                    win,
                    core::ptr::null(),
                    0,
                    100.0,
                    core::ptr::null_mut(),
                )
            },
            AISD_ERR_NULL
        );
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(win, core::ptr::null(), 0, 100.0, &mut scale)
            },
            AISD_EMPTY
        );
    }

    #[test]
    fn coord_pixel_path_divides_by_scale_once() {
        let p = aisd_coord_window_point_from_pixel(
            AisdPoint { x: 400.0, y: 300.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
            2.0,
        );
        approx(p.x, 300.0);
        approx(p.y, 350.0);
    }
}
