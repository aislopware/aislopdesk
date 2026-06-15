//! `ycbcr`: pure, scalar (the BT.709 YCbCr→RGB coefficient table). Selected once per frame on
//! the client's Metal renderer, never per-pixel, so the FFI cost is negligible; the value is a
//! SINGLE SOURCE OF TRUTH for the constants the GPU shader applies (no second Swift literal table).

use aislopdesk_core::ycbcr;

/// The seven YCbCr→RGB coefficients the client's Metal fragment shader applies.
///
/// Flattened for the C ABI (field-for-field [`ycbcr::YCbCrCoefficients`]; all `f32` to match the
/// GPU's single-precision math). Crosses by value.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AisdYCbCrCoefficients {
    /// Luma scale onto [0,1]: video `255/219`, full `1.0`.
    pub luma_scale: f32,
    /// Luma bias subtracted before scaling: video `16/255`, full `0`.
    pub luma_bias: f32,
    /// Chroma centre subtracted from Cb/Cr (`128/255` in both ranges).
    pub chroma_bias: f32,
    /// Cr→R coefficient (range-independent).
    pub cr_to_r: f32,
    /// Cb→G coefficient (range-independent).
    pub cb_to_g: f32,
    /// Cr→G coefficient (range-independent).
    pub cr_to_g: f32,
    /// Cb→B coefficient (range-independent).
    pub cb_to_b: f32,
}

/// The BT.709 YCbCr→RGB coefficients for the negotiated luma range.
///
/// `full_range != 0` ⇒ full swing (luma scale `1.0`, bias `0`), else studio/video swing (the
/// current shader literals, byte-for-byte). Wraps [`ycbcr::coefficients`]. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_ycbcr_coefficients(full_range: u8) -> AisdYCbCrCoefficients {
    let c = ycbcr::coefficients(ycbcr::ColorRange::from_full_range(full_range != 0));
    AisdYCbCrCoefficients {
        luma_scale: c.luma_scale,
        luma_bias: c.luma_bias,
        chroma_bias: c.chroma_bias,
        cr_to_r: c.cr_to_r,
        cb_to_g: c.cb_to_g,
        cr_to_g: c.cr_to_g,
        cb_to_b: c.cb_to_b,
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn ycbcr_coefficients_match_core() {
        let video = aisd_ycbcr_coefficients(0);
        assert_eq!(video.luma_scale, 255.0 / 219.0);
        assert_eq!(video.luma_bias, 16.0 / 255.0);
        assert_eq!(video.chroma_bias, 128.0 / 255.0);
        assert_eq!(video.cr_to_r, 1.5748);
        let full = aisd_ycbcr_coefficients(1);
        assert_eq!(full.luma_scale, 1.0);
        assert_eq!(full.luma_bias, 0.0);
        // Chroma + matrix coefficients are range-independent (only luma differs).
        assert_eq!(video.chroma_bias, full.chroma_bias);
        assert_eq!(video.cr_to_r, full.cr_to_r);
        // Any nonzero byte is full-range (the C ABI reads `!= 0`).
        assert_eq!(aisd_ycbcr_coefficients(0xFF), full);
    }
}
