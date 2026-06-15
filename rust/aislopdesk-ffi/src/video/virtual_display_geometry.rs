//! `virtual_display_geometry`: pure scalar (VD creation path; startup-or-rare).

use super::{AisdPoint, AisdRect};
use aislopdesk_core::geometry::VideoRect;
use aislopdesk_core::virtual_display_geometry::{self, VirtualDisplayGeometry};

/// A virtual-display geometry: the clamped input fields plus the derived framebuffer pixel
/// dimensions and the chip-limit check.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdVDGeometry {
    /// Clamped logical width in points.
    pub point_width: i64,
    /// Clamped logical height in points.
    pub point_height: i64,
    /// Clamped backing scale (1 = standard, 2 = Retina).
    pub scale: i64,
    /// Clamped chip horizontal pixel ceiling.
    pub max_horizontal_pixels: i64,
    /// `point_width * scale`.
    pub pixel_width: i64,
    /// `point_height * scale`.
    pub pixel_height: i64,
    /// `1` if `pixel_width` exceeds the chip ceiling, else `0`.
    pub exceeds_pixel_limit: u8,
}

/// A physical millimetre size (width, height) for a virtual display descriptor.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdVDMillimeters {
    /// Physical width in millimetres.
    pub width: f64,
    /// Physical height in millimetres.
    pub height: f64,
}

/// Builds a (clamped) virtual-display geometry and returns its derived scalar fields. Wraps
/// [`VirtualDisplayGeometry::new`]. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_vd_geometry(
    point_width: i64,
    point_height: i64,
    scale: i64,
    max_horizontal_pixels: i64,
) -> AisdVDGeometry {
    let g = VirtualDisplayGeometry::new(point_width, point_height, scale, max_horizontal_pixels);
    AisdVDGeometry {
        point_width: g.point_width,
        point_height: g.point_height,
        scale: g.scale,
        max_horizontal_pixels: g.max_horizontal_pixels,
        pixel_width: g.pixel_width(),
        pixel_height: g.pixel_height(),
        exceeds_pixel_limit: u8::from(g.exceeds_pixel_limit()),
    }
}

/// Physical size in millimetres for a display of `pixel_width × pixel_height` at `target_ppi`
/// (non-finite / `< 1` ppi is clamped to `1.0`). Wraps
/// [`VirtualDisplayGeometry::size_in_millimeters`].
///
/// Built with `scale = 1` so the geometry's pixel dimensions equal the inputs verbatim,
/// preserving the exact `(pixel / ppi) * 25.4` op order for bit parity.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_vd_size_in_millimeters(
    pixel_width: i64,
    pixel_height: i64,
    target_ppi: f64,
) -> AisdVDMillimeters {
    let g = VirtualDisplayGeometry::new(pixel_width, pixel_height, 1, i64::MAX);
    let mm = g.size_in_millimeters(target_ppi);
    AisdVDMillimeters {
        width: mm.width,
        height: mm.height,
    }
}

/// The VD global origin flush to the right of the rightmost existing display.
///
/// Returns (`maxX`, `0`), or `(0, 0)` when there are no displays. Wraps
/// [`virtual_display_geometry::origin_to_right`]. `displays` is borrowed for the call only.
///
/// # Safety
/// If `display_count != 0`, `displays` must point to at least `display_count` readable
/// [`AisdRect`] values.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_vd_origin_to_right(
    displays: *const AisdRect,
    display_count: usize,
) -> AisdPoint {
    unsafe {
        let rects: Vec<VideoRect> = if display_count == 0 || displays.is_null() {
            Vec::new()
        } else {
            core::slice::from_raw_parts(displays, display_count)
                .iter()
                .map(|r| r.to_core())
                .collect()
        };
        AisdPoint::from_core(virtual_display_geometry::origin_to_right(&rects))
    }
}

/// The chip's horizontal pixel ceiling from a CPU brand string (Pro/Max/Ultra → 7680, base
/// Apple M → 6144, else 7680). Wraps [`virtual_display_geometry::chip_pixel_limit`].
///
/// # Safety
/// `cpu_brand` must be a valid NUL-terminated C string, or null (treated as the default).
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_vd_chip_pixel_limit(cpu_brand: *const core::ffi::c_char) -> i64 {
    unsafe {
        if cpu_brand.is_null() {
            return virtual_display_geometry::chip_pixel_limit("");
        }
        let s = core::ffi::CStr::from_ptr(cpu_brand).to_string_lossy();
        virtual_display_geometry::chip_pixel_limit(&s)
    }
}

/// Writes the descending refresh-rate modes for a VD driven at `fps` into `rates` and returns
/// the count. Wraps [`virtual_display_geometry::refresh_rates`] (always 2 or 3 values).
///
/// Writes nothing (but still returns the needed count) if `rates` is null or `capacity` is
/// smaller than the count, so a caller can size a buffer; in practice 3 slots always suffice.
///
/// # Safety
/// If non-null, `rates` must point to at least `capacity` writable `f64` values.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_vd_refresh_rates(
    fps: i64,
    rates: *mut f64,
    capacity: usize,
) -> usize {
    unsafe {
        let v = virtual_display_geometry::refresh_rates(fps);
        if !rates.is_null() && capacity >= v.len() {
            for (i, r) in v.iter().enumerate() {
                rates.add(i).write(*r);
            }
        }
        v.len()
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn vd_geometry_matches_core() {
        let r = aisd_vd_geometry(1920, 1080, 2, 7680);
        let core = VirtualDisplayGeometry::new(1920, 1080, 2, 7680);
        assert_eq!(r.pixel_width, core.pixel_width());
        assert_eq!(r.pixel_height, core.pixel_height());
        assert_eq!(r.exceeds_pixel_limit, u8::from(core.exceeds_pixel_limit()));
        assert_eq!(r.pixel_width, 3840);
        // 4K-point at 2x exceeds a 6144 base-chip ceiling.
        assert_eq!(aisd_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit, 1);
    }

    #[test]
    fn vd_size_in_millimeters_matches_core() {
        let mm = aisd_vd_size_in_millimeters(3840, 2160, 163.0);
        let core = VirtualDisplayGeometry::new(3840, 2160, 1, i64::MAX).size_in_millimeters(163.0);
        assert_eq!(mm.width.to_bits(), core.width.to_bits());
        assert_eq!(mm.height.to_bits(), core.height.to_bits());
    }

    #[test]
    fn vd_origin_to_right_matches_core() {
        let displays = [
            AisdRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            AisdRect {
                x: 1920.0,
                y: 0.0,
                width: 2560.0,
                height: 1440.0,
            },
        ];
        let p = unsafe { aisd_vd_origin_to_right(displays.as_ptr(), displays.len()) };
        assert_eq!(p.x, 4480.0);
        assert_eq!(p.y, 0.0);
        // empty → (0,0)
        let e = unsafe { aisd_vd_origin_to_right(core::ptr::null(), 0) };
        assert_eq!(e.x, 0.0);
        assert_eq!(e.y, 0.0);
    }

    #[test]
    fn vd_chip_pixel_limit_matches_core() {
        let pro = std::ffi::CString::new("Apple M3 Pro").unwrap();
        let base = std::ffi::CString::new("Apple M2").unwrap();
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(pro.as_ptr()) }, 7680);
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(base.as_ptr()) }, 6144);
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(core::ptr::null()) }, 7680);
    }

    #[test]
    fn vd_refresh_rates_matches_core() {
        let mut buf = [0.0f64; 3];
        let n = unsafe { aisd_vd_refresh_rates(120, buf.as_mut_ptr(), buf.len()) };
        let core = virtual_display_geometry::refresh_rates(120);
        assert_eq!(n, core.len());
        assert_eq!(&buf[..n], core.as_slice());
        // 60 fps → exactly [60, 30]
        let n2 = unsafe { aisd_vd_refresh_rates(60, buf.as_mut_ptr(), buf.len()) };
        assert_eq!(n2, 2);
        assert_eq!(&buf[..2], &[60.0, 30.0]);
    }
}
