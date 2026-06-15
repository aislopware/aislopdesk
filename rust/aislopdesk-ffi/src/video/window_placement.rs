//! `window_placement`: pure, flat-struct (`HiDPI` VD-park path; occasional, never per-frame).

use super::AisdRect;
use aislopdesk_core::geometry::VideoSize;
use aislopdesk_core::window_placement;

/// The result of [`window_placement::placement`], flattened for the C ABI.
///
/// The move-target origin (`x`, `y`), the clamped window size (`width`, `height`), and
/// `needs_resize` (a byte, `1` = the window overhangs the display by >½ pt and must be shrunk
/// before the move).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPlacement {
    /// Move-target origin x (the display's top-left x, returned verbatim).
    pub x: f64,
    /// Move-target origin y.
    pub y: f64,
    /// Clamped window width (`min(window, display)`).
    pub width: f64,
    /// Clamped window height.
    pub height: f64,
    /// `1` if the window must be resized DOWN before the move, else `0`.
    pub needs_resize: u8,
}

/// Clamp a window of `window_w × window_h` to `display` (shrink-only) and place it at the
/// display's top-left origin. Wraps [`window_placement::placement`]. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_window_placement(
    window_w: f64,
    window_h: f64,
    display: AisdRect,
) -> AisdPlacement {
    let p = window_placement::placement(VideoSize::new(window_w, window_h), display.to_core());
    AisdPlacement {
        x: p.origin.x,
        y: p.origin.y,
        width: p.size.width,
        height: p.size.height,
        needs_resize: u8::from(p.needs_resize),
    }
}

/// Whether a window of `size_w × size_h` fits inside `bounds` (½-pt tolerance). Returns `1` if it
/// fits, `0` otherwise. Wraps [`window_placement::fits`]. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_window_fits(size_w: f64, size_h: f64, bounds: AisdRect) -> u8 {
    u8::from(window_placement::fits(
        VideoSize::new(size_w, size_h),
        bounds.to_core(),
    ))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use aislopdesk_core::geometry::VideoRect;

    #[test]
    fn window_placement_matches_core() {
        let display = AisdRect {
            x: 3840.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        // Oversized width clamps to the display; height kept; resize flagged.
        let p = aisd_window_placement(2400.0, 800.0, display);
        let core = window_placement::placement(
            VideoSize::new(2400.0, 800.0),
            VideoRect::xywh(3840.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.x.to_bits(), core.origin.x.to_bits());
        assert_eq!(p.y.to_bits(), core.origin.y.to_bits());
        assert_eq!(p.width.to_bits(), core.size.width.to_bits());
        assert_eq!(p.height.to_bits(), core.size.height.to_bits());
        assert_eq!(p.needs_resize, u8::from(core.needs_resize));
        assert_eq!(p.needs_resize, 1);
    }

    #[test]
    fn window_fits_matches_core() {
        let bounds = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        assert_eq!(aisd_window_fits(1920.0, 1080.0, bounds), 1); // exact
        assert_eq!(aisd_window_fits(1920.4, 1080.0, bounds), 1); // within ½-pt tol
        assert_eq!(aisd_window_fits(1921.0, 1080.0, bounds), 0); // width over
    }
}
