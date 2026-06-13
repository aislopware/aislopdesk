//! Video-path C ABI: the scalar realtime policies and small-buffer codecs from
//! `aislopdesk_core`'s video modules.
//!
//! Same memory / error contract as the crate root (see `lib.rs`): scalars cross by value;
//! any [`crate::AisdBytes`] returned owns a Rust allocation freed with [`crate::aisd_bytes_free`];
//! borrowed input buffers (`cap == 0`) are copied, never freed. The pure scalar functions here
//! take no pointers and cannot fail.

use crate::{
    bytes_from_vec, AisdBytes, AisdStatus, AISD_ERR_MALFORMED, AISD_ERR_NULL, AISD_ERR_TRUNCATED,
    AISD_OK,
};
use aislopdesk_core::cursor::CursorUpdate;
use aislopdesk_core::error::VideoProtocolError;
use aislopdesk_core::geometry::VideoPoint;
use aislopdesk_core::live_bitrate_policy;

/// Maps a core video decode error to its boundary status code (shared by the video codecs).
pub(crate) fn status_for_video_error(error: &VideoProtocolError) -> AisdStatus {
    match error {
        VideoProtocolError::Truncated => AISD_ERR_TRUNCATED,
        VideoProtocolError::Malformed(_) => AISD_ERR_MALFORMED,
    }
}

/// Borrows a `(ptr, len)` pair as a slice (empty for `len == 0`, even if `ptr` is null).
///
/// # Safety
/// If `len != 0`, `data` must point to at least `len` readable bytes.
pub(crate) unsafe fn slice_in<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        core::slice::from_raw_parts(data, len)
    }
}

// ---------------------------------------------------------------------------------------
// live_bitrate_policy — pure, scalar (called ~per resolution change, never per frame)
// ---------------------------------------------------------------------------------------

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, never below `floor` or the minimum. Wraps
/// [`live_bitrate_policy::target_bitrate`].
///
/// The caller resolves the `bits_per_pixel` density (e.g. from `AISLOPDESK_BPP`) and passes it
/// in, so the core stays environment-free and the result is deterministic.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    live_bitrate_policy::target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel)
}

/// The absolute minimum live bitrate (bits/sec) — a tiny window never starves the encoder.
/// Wraps [`live_bitrate_policy::MINIMUM_BITRATE`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_minimum() -> i64 {
    live_bitrate_policy::MINIMUM_BITRATE
}

// ---------------------------------------------------------------------------------------
// cursor — the fixed 36-byte hot cursor update (≈120 Hz, small => Rust faster than Data)
// ---------------------------------------------------------------------------------------

/// A decoded cursor update, flattened for the C ABI (the hot 36-byte message; no owned
/// buffer). Field order must match the C header's `AisdCursorUpdate`.
#[repr(C)]
pub struct AisdCursorUpdate {
    /// Cursor shape id (client caches the bitmap by this id).
    pub shape_id: u16,
    /// Visibility (`0` = hidden, nonzero = visible; read as `!= 0`).
    pub visible: u8,
    /// Host-window-space x (points).
    pub x: f64,
    /// Host-window-space y (points).
    pub y: f64,
    /// Hotspot x offset (points).
    pub hotspot_x: f64,
    /// Hotspot y offset (points).
    pub hotspot_y: f64,
}

/// Encodes a cursor update into its fixed 36-byte wire form. On [`AISD_OK`], `*out` owns the
/// buffer — release with [`crate::aisd_bytes_free`]. Wraps [`CursorUpdate::encode`]; cannot
/// fail except for a null `out`.
///
/// # Safety
/// `out` must be a writable [`AisdBytes`] pointer.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_encode(
    shape_id: u16,
    visible: u8,
    x: f64,
    y: f64,
    hotspot_x: f64,
    hotspot_y: f64,
    out: *mut AisdBytes,
) -> AisdStatus {
    if out.is_null() {
        return AISD_ERR_NULL;
    }
    let update = CursorUpdate {
        position: VideoPoint::new(x, y),
        shape_id,
        hotspot: VideoPoint::new(hotspot_x, hotspot_y),
        visible: visible != 0,
    };
    out.write(bytes_from_vec(update.encode()));
    AISD_OK
}

/// Decodes a cursor update into `*out`. Wraps [`CursorUpdate::decode`]: rejects a wrong type
/// byte or non-finite coordinate ([`AISD_ERR_MALFORMED`]) and a short body
/// ([`AISD_ERR_TRUNCATED`]). `data` may be null only when `len == 0`.
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdCursorUpdate,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match CursorUpdate::decode(slice_in(data, len)) {
        Ok(c) => {
            out.write(AisdCursorUpdate {
                shape_id: c.shape_id,
                visible: u8::from(c.visible),
                x: c.position.x,
                y: c.position.y,
                hotspot_x: c.hotspot.x,
                hotspot_y: c.hotspot.y,
            });
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    const BPP: f64 = live_bitrate_policy::DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn live_bitrate_target_matches_core() {
        assert_eq!(
            aisd_live_bitrate_target(1920, 1080, 60, 12_000_000, BPP),
            18_662_400
        );
        assert_eq!(
            aisd_live_bitrate_target(2816, 1778, 60, 12_000_000, BPP),
            45_061_632
        );
        assert_eq!(
            aisd_live_bitrate_target(320, 240, 60, 12_000_000, BPP),
            12_000_000
        );
        assert_eq!(
            aisd_live_bitrate_target(64, 64, 60, 0, BPP),
            aisd_live_bitrate_minimum()
        );
        assert_eq!(
            aisd_live_bitrate_target(0, -10, 0, 0, BPP),
            aisd_live_bitrate_minimum()
        );
    }

    #[test]
    fn live_bitrate_minimum_is_one_megabit() {
        assert_eq!(aisd_live_bitrate_minimum(), 1_000_000);
    }

    fn zeroed_cursor() -> AisdCursorUpdate {
        AisdCursorUpdate {
            shape_id: 0,
            visible: 0,
            x: 0.0,
            y: 0.0,
            hotspot_x: 0.0,
            hotspot_y: 0.0,
        }
    }

    #[test]
    fn cursor_update_round_trips() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(42, 1, 1920.0, 1080.0, 8.0, 8.0, &mut frame),
                AISD_OK
            );
            assert_eq!(frame.len, 36);
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.shape_id, 42);
            assert_eq!(out.visible, 1);
            assert_eq!(
                (out.x, out.y, out.hotspot_x, out.hotspot_y),
                (1920.0, 1080.0, 8.0, 8.0)
            );
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn cursor_update_rejects_nan_wrong_type_and_short() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(1, 1, f64::NAN, 0.0, 0.0, 0.0, &mut frame),
                AISD_OK
            );
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_ERR_MALFORMED
            );
            crate::aisd_bytes_free(frame);

            let bad = [99u8; 36]; // wrong type byte
            assert_eq!(
                aisd_cursor_update_decode(bad.as_ptr(), bad.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            assert_eq!(
                aisd_cursor_update_decode([1u8].as_ptr(), 1, &mut out),
                AISD_ERR_TRUNCATED
            );
        }
    }
}
