//! `frame_hash`: the NEON NV12 frame-hash C ABI (zero-copy over borrowed, locked plane pointers).
//!
//! The host hashes each captured frame's luma + chroma planes to detect a pixel-identical re-delivery.
//!
//! `ScreenCaptureKit` sometimes re-delivers an identical `.complete` frame; matching its hash to the
//! last submitted frame lets the host skip re-encoding it. The plane pointers come straight from the
//! already-locked `CVPixelBuffer` (`CVPixelBufferGetBaseAddressOfPlane`), so this entry point
//! BORROWS them for the call only — it never copies a plane and never frees a pointer. The hash
//! itself runs the NEON kernel ([`crate::frame_hash::NeonFrameHash`]), byte-identical to the scalar
//! [`aislopdesk_core::frame_hash`] reference (Android default + differential oracle).

use super::slice_in;
use crate::frame_hash::NeonFrameHash;

/// The value a degenerate / null-guarded call returns instead of panicking.
///
/// A null `y`, a zero `width`/`height`, or a `y_stride < width` cannot describe a real frame, so the
/// host treats this value as "no usable hash" (the caller additionally gates suppression on a
/// non-sentinel result). It is `u64::MAX`, distinct from `0` so a genuine all-zero plane — which
/// hashes to a real avalanche value, not 0 — is never confused with it.
pub const AISD_FRAME_HASH_SENTINEL: u64 = u64::MAX;

/// Hashes an NV12 frame into a 64-bit value over BORROWED plane pointers (zero-copy).
///
/// * `y` / `y_stride`: the luma plane base pointer and its byte stride. The plane must hold at least
///   `y_stride * height` readable bytes (the row-by-row hasher additionally stops early if a row
///   would read past that, so an over-stated `height` degrades safely rather than reading OOB).
/// * `width` / `height`: the VISIBLE luma dimensions in pixels; only the first `width` bytes of each
///   `y_stride`-spaced row are hashed, so row padding never affects the result (resolution-stable).
/// * `cbcr` / `cbcr_stride`: the interleaved NV12 chroma plane (or `NULL` for a luma-only hash).
///   When non-null it must hold at least `cbcr_stride * (height / 2)` readable bytes.
///
/// Returns [`AISD_FRAME_HASH_SENTINEL`] (never a panic across the boundary) when `y` is null or a
/// dimension is degenerate (`width == 0`, `height == 0`, or `y_stride < width`). `cbcr` null with a
/// nonzero implied chroma size is treated as a luma-only hash, never a fault.
///
/// # Safety
/// If the implied plane sizes are nonzero, `y` (and `cbcr` when non-null) must point to at least
/// that many readable, initialized bytes that stay valid for the call. The pointers are borrowed —
/// Rust neither retains nor frees them. No pointer is ever written through.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_frame_hash_nv12(
    y: *const u8,
    y_stride: usize,
    width: usize,
    height: usize,
    cbcr: *const u8,
    cbcr_stride: usize,
) -> u64 {
    // Null / degenerate guard: nothing is dereferenced, a defined sentinel is returned.
    if y.is_null() || width == 0 || height == 0 || y_stride < width {
        return AISD_FRAME_HASH_SENTINEL;
    }

    // Borrow the luma plane for exactly `y_stride * height` bytes (the row hasher bounds-guards each
    // row inside this, so it never reads past the slice even if the caller over-stated `height`).
    // `checked_mul` keeps a hostile stride*height from wrapping the length.
    let Some(y_len) = y_stride.checked_mul(height) else {
        return AISD_FRAME_HASH_SENTINEL;
    };
    // SAFETY: per the contract `y` points to >= `y_stride * height` readable bytes (guarded above);
    // `slice_in` builds a borrowed, read-only slice of exactly that length.
    let y_plane = unsafe { slice_in(y, y_len) };

    // Chroma is optional (luma-only when null). Its visible region is `height / 2` rows.
    let chroma_rows = height / 2;
    let cbcr_plane: &[u8] = if cbcr.is_null() || cbcr_stride == 0 || chroma_rows == 0 {
        &[]
    } else if let Some(cbcr_len) = cbcr_stride.checked_mul(chroma_rows) {
        // SAFETY: per the contract a non-null `cbcr` points to >= `cbcr_stride * (height / 2)`
        // readable bytes; `slice_in` borrows exactly that, read-only, for the call.
        unsafe { slice_in(cbcr, cbcr_len) }
    } else {
        &[] // pathological stride*rows overflow ⇒ fall back to luma-only rather than fault
    };

    NeonFrameHash::hash_nv12(y_plane, y_stride, width, height, cbcr_plane, cbcr_stride)
}

#[cfg(test)]
mod tests {
    // `w`/`h` (width/height) and `a`/`b` (two hashes to compare) are the clearest names here.
    #![allow(clippy::many_single_char_names)]
    use super::*;
    use aislopdesk_core::frame_hash;

    /// Drive the C ABI exactly as a C caller (raw pointers). A small synthetic NV12 plane suffices —
    /// the byte-exactness vs the scalar core is covered exhaustively by the kernel's differential
    /// test; here we prove the boundary marshals pointers/lengths correctly and guards nulls.
    #[test]
    fn frame_hash_abi_is_deterministic_and_matches_core() {
        let (w, h, stride) = (40usize, 24usize, 48usize);
        let y: Vec<u8> = (0..stride * h).map(|i| (i * 31 + 7) as u8).collect();
        let cbcr: Vec<u8> = (0..stride * (h / 2)).map(|i| (i * 17 + 3) as u8).collect();

        // SAFETY: the slices outlive the call and cover the implied plane sizes.
        let a = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
        let b = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
        assert_eq!(a, b, "the same frame must hash identically across calls");
        assert_ne!(
            a, AISD_FRAME_HASH_SENTINEL,
            "a valid frame must not return the sentinel"
        );

        // Equals the scalar core over the same logical planes.
        let core = frame_hash::hash_nv12(&y, stride, w, h, &cbcr, stride);
        assert_eq!(a, core, "the C ABI must equal the scalar core hash");
    }

    #[test]
    fn frame_hash_abi_changes_on_a_one_byte_edit() {
        let (w, h, stride) = (32usize, 16usize, 32usize);
        let mut y: Vec<u8> = vec![0x80; stride * h];
        // SAFETY: valid slice, luma-only (null chroma).
        let base = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, core::ptr::null(), 0) };
        y[123] ^= 0x01;
        let edited =
            unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, core::ptr::null(), 0) };
        assert_ne!(base, edited, "a one-byte change must change the hash");
    }

    #[test]
    fn frame_hash_abi_null_and_degenerate_return_sentinel() {
        let y = [0u8; 64];
        // Null luma.
        let n = unsafe { aisd_frame_hash_nv12(core::ptr::null(), 8, 8, 8, core::ptr::null(), 0) };
        assert_eq!(n, AISD_FRAME_HASH_SENTINEL, "null y ⇒ sentinel");
        // Zero dims.
        let z = unsafe { aisd_frame_hash_nv12(y.as_ptr(), 0, 0, 0, core::ptr::null(), 0) };
        assert_eq!(z, AISD_FRAME_HASH_SENTINEL, "zero dims ⇒ sentinel");
        // stride < width.
        let s = unsafe { aisd_frame_hash_nv12(y.as_ptr(), 4, 8, 2, core::ptr::null(), 0) };
        assert_eq!(s, AISD_FRAME_HASH_SENTINEL, "stride < width ⇒ sentinel");
    }

    #[test]
    fn frame_hash_abi_luma_only_equals_null_chroma() {
        let (w, h, stride) = (16usize, 16usize, 16usize);
        let y: Vec<u8> = (0..stride * h).map(|i| (i * 13) as u8).collect();
        // Null chroma and zero-stride chroma must both mean luma-only (identical result).
        let a = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, core::ptr::null(), 0) };
        let b = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, core::ptr::null(), 16) };
        assert_eq!(
            a, b,
            "null chroma ⇒ luma-only regardless of the passed chroma stride"
        );
        assert_eq!(a, frame_hash::hash_nv12(&y, stride, w, h, &[], 0));
    }
}
