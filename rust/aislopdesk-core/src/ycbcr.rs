//! YCbCr→RGB coefficients — the canonical `YCbCrConversion` logic (the Swift shell mirrors it).
//!
//! The single source of truth for the BT.709 coefficients the client's Metal shader
//! applies, so the headlessly-testable numbers and the GPU's literals stay in lockstep.
//! Values are `f32` to match the GPU's single-precision math. The whole difference
//! between the two color ranges is the LUMA expansion; chroma + the four matrix
//! coefficients are range-independent.

/// The luma code-range of an encoded NV12 stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorRange {
    /// "Studio swing" — Y in [16,235] (`video_full_range_flag = 0`; today's default).
    Video,
    /// "Full swing" — Y in [0,255] (`video_full_range_flag = 1`).
    Full,
}

impl ColorRange {
    /// Maps the negotiated `helloAck.fullRange` wire bit to a range (`false` → `Video`).
    #[must_use]
    pub const fn from_full_range(full_range: bool) -> Self {
        if full_range {
            Self::Full
        } else {
            Self::Video
        }
    }

    /// The wire bit for `helloAck.fullRange`.
    #[must_use]
    pub const fn is_full_range(self) -> bool {
        matches!(self, Self::Full)
    }
}

/// The seven YCbCr→RGB coefficients the fragment shader applies.
///
/// The shader computes (UV already cropped for zoom/pan):
/// ```text
/// yy = (y - luma_bias) * luma_scale
/// cb =  cbcr.x - chroma_bias
/// cr =  cbcr.y - chroma_bias
/// r  = yy + cr_to_r * cr
/// g  = yy - cb_to_g * cb - cr_to_g * cr
/// b  = yy + cb_to_b * cb
/// ```
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct YCbCrCoefficients {
    /// Luma scale onto [0,1]: video `255/219`, full `1.0`.
    pub luma_scale: f32,
    /// Luma bias subtracted before scaling: video `16/255`, full `0`.
    pub luma_bias: f32,
    /// Chroma centre subtracted from Cb/Cr (`128/255` in both ranges).
    pub chroma_bias: f32,
    /// Cr→R coefficient `2(1-Kr) = 1.5748` (range-independent).
    pub cr_to_r: f32,
    /// Cb→G coefficient `2·Kb(1-Kb)/Kg = 0.1873` (range-independent).
    pub cb_to_g: f32,
    /// Cr→G coefficient `2·Kr(1-Kr)/Kg = 0.4681` (range-independent).
    pub cr_to_g: f32,
    /// Cb→B coefficient `2(1-Kb) = 1.8556` (range-independent).
    pub cb_to_b: f32,
}

/// The BT.709 YCbCr→RGB coefficients for `range`. `Video` reproduces today's hardcoded
/// shader literals exactly; `Full` changes ONLY the luma (scale 1.0, bias 0).
#[must_use]
pub fn coefficients(range: ColorRange) -> YCbCrCoefficients {
    // The four matrix coefficients + chroma centre are shared (range-independent).
    let chroma_bias: f32 = 128.0 / 255.0;
    let cr_to_r: f32 = 1.5748;
    let cb_to_g: f32 = 0.1873;
    let cr_to_g: f32 = 0.4681;
    let cb_to_b: f32 = 1.8556;
    match range {
        ColorRange::Video => YCbCrCoefficients {
            luma_scale: 255.0 / 219.0,
            luma_bias: 16.0 / 255.0,
            chroma_bias,
            cr_to_r,
            cb_to_g,
            cr_to_g,
            cb_to_b,
        },
        ColorRange::Full => YCbCrCoefficients {
            luma_scale: 1.0,
            luma_bias: 0.0,
            chroma_bias,
            cr_to_r,
            cb_to_g,
            cr_to_g,
            cb_to_b,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_range_matches_shader_literals() {
        let c = coefficients(ColorRange::Video);
        assert_eq!(c.luma_scale, 255.0 / 219.0);
        assert_eq!(c.luma_bias, 16.0 / 255.0);
        assert_eq!(c.chroma_bias, 128.0 / 255.0);
        assert_eq!(c.cr_to_r, 1.5748);
        assert_eq!(c.cb_to_g, 0.1873);
        assert_eq!(c.cr_to_g, 0.4681);
        assert_eq!(c.cb_to_b, 1.8556);
    }

    #[test]
    fn full_range_differs_only_in_luma() {
        let v = coefficients(ColorRange::Video);
        let f = coefficients(ColorRange::Full);
        assert_eq!(f.luma_scale, 1.0);
        assert_eq!(f.luma_bias, 0.0);
        // chroma + matrix identical
        assert_eq!(v.chroma_bias, f.chroma_bias);
        assert_eq!(v.cr_to_r, f.cr_to_r);
        assert_eq!(v.cb_to_g, f.cb_to_g);
        assert_eq!(v.cr_to_g, f.cr_to_g);
        assert_eq!(v.cb_to_b, f.cb_to_b);
    }

    #[test]
    fn range_wire_bit_round_trip() {
        assert_eq!(ColorRange::from_full_range(true), ColorRange::Full);
        assert_eq!(ColorRange::from_full_range(false), ColorRange::Video);
        assert!(ColorRange::Full.is_full_range());
        assert!(!ColorRange::Video.is_full_range());
    }
}
