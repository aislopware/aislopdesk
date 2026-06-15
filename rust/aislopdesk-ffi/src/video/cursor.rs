//! `cursor`: the fixed 36-byte hot cursor update (≈120 Hz, small => Rust faster than `Data`).

use super::{slice_in, status_for_video_error};
use crate::{AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec};
use aislopdesk_core::cursor::CursorUpdate;
use aislopdesk_core::geometry::VideoPoint;

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

/// Encodes a cursor update into its fixed 36-byte wire form.
///
/// On [`AISD_OK`], `*out` owns the
/// buffer — release with [`crate::aisd_bytes_free`]. Wraps [`CursorUpdate::encode`]; cannot
/// fail except for a null `out`.
///
/// # Safety
/// `out` must be a writable [`AisdBytes`] pointer.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_cursor_update_encode(
    shape_id: u16,
    visible: u8,
    x: f64,
    y: f64,
    hotspot_x: f64,
    hotspot_y: f64,
    out: *mut AisdBytes,
) -> AisdStatus {
    unsafe {
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
}

/// Decodes a cursor update into `*out`.
///
/// Wraps [`CursorUpdate::decode`]: rejects a wrong type
/// byte or non-finite coordinate ([`crate::AISD_ERR_MALFORMED`]) and a short body
/// ([`crate::AISD_ERR_TRUNCATED`]). `data` may be null only when `len == 0`.
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_cursor_update_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdCursorUpdate,
) -> AisdStatus {
    unsafe {
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
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::{AISD_ERR_MALFORMED, AISD_ERR_TRUNCATED};

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
