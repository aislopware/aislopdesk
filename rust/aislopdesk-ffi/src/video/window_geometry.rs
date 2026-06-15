//! `window_geometry`: the move/resize/bounds/title metadata channel (occasional, per window
//! move/resize/title; one owned title buffer, marshaled like `AisdWireMessage`).

use super::{slice_in, status_for_video_error};
use crate::{
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec,
    copy_in, drop_bytes,
};
use aislopdesk_core::geometry::{VideoPoint, VideoRect, VideoSize};
use aislopdesk_core::window_geometry::WindowGeometryMessage;

/// [`WindowGeometryMessage::Move`] discriminator (`kind`).
pub const AISD_WINDOW_GEOMETRY_MOVE: u8 = 1;
/// [`WindowGeometryMessage::Resize`] discriminator.
pub const AISD_WINDOW_GEOMETRY_RESIZE: u8 = 2;
/// [`WindowGeometryMessage::Bounds`] discriminator.
pub const AISD_WINDOW_GEOMETRY_BOUNDS: u8 = 3;
/// [`WindowGeometryMessage::Title`] discriminator.
pub const AISD_WINDOW_GEOMETRY_TITLE: u8 = 4;

/// A window-geometry message, flattened for the C ABI.
///
/// `kind` (`AISD_WINDOW_GEOMETRY_*`) selects which fields are meaningful: `MOVE` uses `x`/`y`;
/// `RESIZE` uses `width`/`height`; `BOUNDS` uses all four; `TITLE` uses `title` (UTF-8). On a
/// decode `out` the `title` owns a Rust allocation — release with [`aisd_window_geometry_free`];
/// on an encode input it is a borrowed `(ptr, len)` (`cap` ignored) or [`AisdBytes::EMPTY`].
#[repr(C)]
pub struct AisdWindowGeometry {
    /// Message discriminator (`AISD_WINDOW_GEOMETRY_*`).
    pub kind: u8,
    /// `MOVE` / `BOUNDS` origin x (points).
    pub x: f64,
    /// `MOVE` / `BOUNDS` origin y (points).
    pub y: f64,
    /// `RESIZE` / `BOUNDS` width (points).
    pub width: f64,
    /// `RESIZE` / `BOUNDS` height (points).
    pub height: f64,
    /// `TITLE` UTF-8 bytes (owned out / borrowed in; [`AisdBytes::EMPTY`] otherwise).
    pub title: AisdBytes,
}

impl AisdWindowGeometry {
    /// An all-zero `MOVE`-shaped struct with an empty title — the base every decode fills in.
    const fn zeroed() -> Self {
        Self {
            kind: 0,
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            title: AisdBytes::EMPTY,
        }
    }
}

/// Rebuilds a core [`WindowGeometryMessage`] from the caller's C struct, validating the `kind`
/// and any UTF-8 title.
///
/// # Safety
/// A non-empty `title` in `m` must point to that many readable bytes.
unsafe fn c_to_window_geometry(
    m: &AisdWindowGeometry,
) -> Result<WindowGeometryMessage, AisdStatus> {
    unsafe {
        let message = match m.kind {
            AISD_WINDOW_GEOMETRY_MOVE => WindowGeometryMessage::Move(VideoPoint::new(m.x, m.y)),
            AISD_WINDOW_GEOMETRY_RESIZE => {
                WindowGeometryMessage::Resize(VideoSize::new(m.width, m.height))
            }
            AISD_WINDOW_GEOMETRY_BOUNDS => {
                WindowGeometryMessage::Bounds(VideoRect::xywh(m.x, m.y, m.width, m.height))
            }
            AISD_WINDOW_GEOMETRY_TITLE => {
                let title =
                    String::from_utf8(copy_in(m.title)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?;
                WindowGeometryMessage::Title(title)
            }
            _ => return Err(AISD_ERR_INVALID_ARGUMENT),
        };
        Ok(message)
    }
}

/// Flattens a core [`WindowGeometryMessage`] into the C struct, allocating an owned buffer for a
/// title.
fn window_geometry_to_c(message: &WindowGeometryMessage) -> AisdWindowGeometry {
    let mut out = AisdWindowGeometry::zeroed();
    out.kind = message.message_type();
    match message {
        WindowGeometryMessage::Move(p) => {
            out.x = p.x;
            out.y = p.y;
        }
        WindowGeometryMessage::Resize(s) => {
            out.width = s.width;
            out.height = s.height;
        }
        WindowGeometryMessage::Bounds(r) => {
            out.x = r.origin.x;
            out.y = r.origin.y;
            out.width = r.size.width;
            out.height = r.size.height;
        }
        WindowGeometryMessage::Title(t) => out.title = bytes_from_vec(t.clone().into_bytes()),
    }
    out
}

/// Encodes a caller-built [`AisdWindowGeometry`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`
/// / non-UTF-8 `title`.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; a non-empty `title` inside `*msg` must
/// point to that many readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_window_geometry_encode(
    msg: *const AisdWindowGeometry,
    out: *mut AisdBytes,
) -> AisdStatus {
    unsafe {
        if msg.is_null() || out.is_null() {
            return AISD_ERR_NULL;
        }
        match c_to_window_geometry(&*msg) {
            Ok(message) => {
                out.write(bytes_from_vec(message.encode()));
                AISD_OK
            }
            Err(status) => status,
        }
    }
}

/// Decodes a window-geometry message into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `title` buffer — release with [`aisd_window_geometry_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / non-UTF-8 title /
/// unknown type to [`crate::AISD_ERR_MALFORMED`] and a short body to [`crate::AISD_ERR_TRUNCATED`].
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_window_geometry_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdWindowGeometry,
) -> AisdStatus {
    unsafe {
        if out.is_null() || (data.is_null() && len != 0) {
            return AISD_ERR_NULL;
        }
        match WindowGeometryMessage::decode(slice_in(data, len)) {
            Ok(message) => {
                out.write(window_geometry_to_c(&message));
                AISD_OK
            }
            Err(e) => status_for_video_error(&e),
        }
    }
}

/// Releases the owned `title` buffer inside an [`AisdWindowGeometry`] and resets it to empty.
/// Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdWindowGeometry`] previously filled by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_window_geometry_free(msg: *mut AisdWindowGeometry) {
    unsafe {
        if msg.is_null() {
            return;
        }
        let m = &mut *msg;
        drop_bytes(m.title);
        m.title = AisdBytes::EMPTY;
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::{AISD_ERR_MALFORMED, AISD_ERR_TRUNCATED};

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        unsafe {
            if b.ptr.is_null() || b.len == 0 {
                Vec::new()
            } else {
                core::slice::from_raw_parts(b.ptr, b.len).to_vec()
            }
        }
    }

    /// Borrows a slice as an input `AisdBytes` (encode copies it, never frees).
    fn borrow(bytes: &[u8]) -> AisdBytes {
        if bytes.is_empty() {
            AisdBytes::EMPTY
        } else {
            AisdBytes {
                ptr: bytes.as_ptr().cast_mut(),
                len: bytes.len(),
                cap: 0,
            }
        }
    }

    #[test]
    fn window_geometry_round_trips_every_variant() {
        unsafe {
            let title = "héllo · 窗口";
            let cases = [
                (
                    WindowGeometryMessage::Move(VideoPoint::new(10.0, 20.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_MOVE,
                        x: 10.0,
                        y: 20.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Resize(VideoSize::new(640.0, 480.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_RESIZE,
                        width: 640.0,
                        height: 480.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Bounds(VideoRect::xywh(1.0, 2.0, 3.0, 4.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_BOUNDS,
                        x: 1.0,
                        y: 2.0,
                        width: 3.0,
                        height: 4.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Title(title.to_owned()),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_TITLE,
                        title: borrow(title.as_bytes()),
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
            ];
            for (core_msg, c_in) in cases {
                // Encode through the C struct is byte-identical to the core encode.
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_window_geometry_encode(&c_in, &mut frame), AISD_OK);
                assert_eq!(
                    view(frame),
                    core_msg.encode(),
                    "encode parity {}",
                    c_in.kind
                );
                // Decode it back; the flat struct re-decodes to the same core message.
                let mut out = AisdWindowGeometry::zeroed();
                assert_eq!(
                    aisd_window_geometry_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                let round = match out.kind {
                    AISD_WINDOW_GEOMETRY_MOVE => {
                        WindowGeometryMessage::Move(VideoPoint::new(out.x, out.y))
                    }
                    AISD_WINDOW_GEOMETRY_RESIZE => {
                        WindowGeometryMessage::Resize(VideoSize::new(out.width, out.height))
                    }
                    AISD_WINDOW_GEOMETRY_BOUNDS => WindowGeometryMessage::Bounds(VideoRect::xywh(
                        out.x, out.y, out.width, out.height,
                    )),
                    _ => WindowGeometryMessage::Title(String::from_utf8(view(out.title)).unwrap()),
                };
                assert_eq!(round, core_msg, "decode parity {}", out.kind);
                aisd_window_geometry_free(&mut out);
                aisd_window_geometry_free(&mut out); // idempotent
                crate::aisd_bytes_free(frame);
            }
        }
    }

    #[test]
    fn window_geometry_empty_title_is_null_buffer() {
        unsafe {
            let c_in = AisdWindowGeometry {
                kind: AISD_WINDOW_GEOMETRY_TITLE,
                ..AisdWindowGeometry::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_window_geometry_encode(&c_in, &mut frame), AISD_OK);
            // Just the type byte (4); an empty title adds nothing.
            assert_eq!(view(frame), vec![AISD_WINDOW_GEOMETRY_TITLE]);
            let mut out = AisdWindowGeometry::zeroed();
            assert_eq!(
                aisd_window_geometry_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.kind, AISD_WINDOW_GEOMETRY_TITLE);
            assert!(out.title.ptr.is_null(), "empty title is the null buffer");
            aisd_window_geometry_free(&mut out);
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn window_geometry_encode_and_decode_error_paths() {
        unsafe {
            let mut out_bytes = AisdBytes::EMPTY;
            // Unknown kind on encode.
            let bad_kind = AisdWindowGeometry {
                kind: 99,
                ..AisdWindowGeometry::zeroed()
            };
            assert_eq!(
                aisd_window_geometry_encode(&bad_kind, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Non-UTF-8 title on encode.
            let invalid = [0xFFu8, 0xFE];
            let bad_title = AisdWindowGeometry {
                kind: AISD_WINDOW_GEOMETRY_TITLE,
                title: borrow(&invalid),
                ..AisdWindowGeometry::zeroed()
            };
            assert_eq!(
                aisd_window_geometry_encode(&bad_title, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Null guards.
            let mut out = AisdWindowGeometry::zeroed();
            assert_eq!(
                aisd_window_geometry_encode(core::ptr::null(), &mut out_bytes),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_window_geometry_decode(core::ptr::null(), 1, &mut out),
                AISD_ERR_NULL
            );
            // Decode: unknown type → malformed; short move body → truncated; bad title → malformed.
            assert_eq!(
                aisd_window_geometry_decode([9u8].as_ptr(), 1, &mut out),
                AISD_ERR_MALFORMED
            );
            let short_move = [AISD_WINDOW_GEOMETRY_MOVE, 0, 0];
            assert_eq!(
                aisd_window_geometry_decode(short_move.as_ptr(), short_move.len(), &mut out),
                AISD_ERR_TRUNCATED
            );
            let bad_title_wire = [AISD_WINDOW_GEOMETRY_TITLE, 0xFF, 0xFE];
            assert_eq!(
                aisd_window_geometry_decode(
                    bad_title_wire.as_ptr(),
                    bad_title_wire.len(),
                    &mut out
                ),
                AISD_ERR_MALFORMED
            );
            aisd_window_geometry_free(core::ptr::null_mut()); // no-op
        }
    }
}
