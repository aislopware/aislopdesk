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
use aislopdesk_core::adaptive_fec;
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

// ---------------------------------------------------------------------------------------
// adaptive_fec — pure, scalar (tier/next_tier_state ~per netstats report; group_size on the
// reassemble/packetize path; FFI overhead negligible vs decode/encode)
// ---------------------------------------------------------------------------------------

/// Tier-decision state for the dwell-gated adaptive-FEC variant, flattened for the C ABI.
/// Mirrors [`adaptive_fec::TierState`] field-for-field (`#[repr(C)]`, same field order). Crosses
/// by value in both directions.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdTierState {
    /// Current wire tier (0..=7 on the wire; any `u8` is total).
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
}

impl From<adaptive_fec::TierState> for AisdTierState {
    fn from(s: adaptive_fec::TierState) -> Self {
        Self {
            tier: s.tier,
            relax_streak: s.relax_streak,
            sticky_relax_remaining: s.sticky_relax_remaining,
        }
    }
}

impl From<AisdTierState> for adaptive_fec::TierState {
    fn from(s: AisdTierState) -> Self {
        adaptive_fec::TierState::new(s.tier, s.relax_streak, s.sticky_relax_remaining)
    }
}

/// Maps a wire tier to the FEC group size both ends must use. Wraps
/// [`adaptive_fec::group_size`]. Returns `1` and writes the group size to `*out` for a parity
/// tier; returns `0` for the OFF (no-parity) tier (leaving `*out` untouched — treat as nil).
/// TOTAL over every `tier` (unknown → `default_group_size`, never traps). A null `out` returns
/// `0` without writing.
///
/// # Safety
/// `out`, if non-null, must be a writable `usize` pointer.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_adaptive_fec_group_size(
    tier: u8,
    default_group_size: usize,
    out: *mut usize,
) -> u8 {
    match adaptive_fec::group_size(tier, default_group_size) {
        // Return `1` only when a size was actually written, so the return is a clean
        // postcondition (`1` ⟺ `*out` holds a valid group size). A null `out` (caller error)
        // yields `0` like the OFF tier — nothing written, no UB.
        Some(g) if !out.is_null() => {
            out.write(g);
            1
        }
        _ => 0,
    }
}

/// Picks the next wire tier from the EWMA `loss` and the `previous_tier` (the plain decider;
/// the production host uses [`aisd_adaptive_fec_next_tier_state`]). Wraps [`adaptive_fec::tier`].
/// `allow_off` is the OFF-tier escape hatch resolved by the caller from `AISLOPDESK_FEC_ALLOW_OFF`
/// (read `!= 0`), keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_tier(loss: f64, previous_tier: u8, allow_off: u8) -> u8 {
    adaptive_fec::tier(loss, previous_tier, allow_off != 0)
}

/// Dwell-gated tier step — the production entry point. Wraps [`adaptive_fec::next_tier_state`]:
/// escalation is immediate (one step, resets the relax streak); relaxation is counted across
/// consecutive relax-demanding reports and applied at the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Returns the next state by value.
/// `allow_off` / `saw_unrecovered_loss` are bytes read `!= 0`; the caller resolves `allow_off`
/// from the environment and passes `dwell`, keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_next_tier_state(
    loss: f64,
    state: AisdTierState,
    dwell: i32,
    allow_off: u8,
    saw_unrecovered_loss: u8,
) -> AisdTierState {
    adaptive_fec::next_tier_state(
        loss,
        state.into(),
        dwell,
        allow_off != 0,
        saw_unrecovered_loss != 0,
    )
    .into()
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

    #[test]
    fn adaptive_fec_group_size_matches_core() {
        let mut out: usize = 0;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(0, 5, &mut out) }, 1);
        assert_eq!(out, 5);
        out = 999;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(1, 5, &mut out) }, 0);
        assert_eq!(out, 999, "OFF must not write *out");
        for (tier, def, want) in [
            (2u8, 5usize, 10usize),
            (3, 5, 3),
            (4, 5, 2),
            (5, 5, 5),
            (200, 7, 7),
        ] {
            out = 0;
            assert_eq!(
                unsafe { aisd_adaptive_fec_group_size(tier, def, &mut out) },
                1
            );
            assert_eq!(out, want, "tier {tier} default {def}");
        }
        assert_eq!(
            unsafe { aisd_adaptive_fec_group_size(0, 5, core::ptr::null_mut()) },
            0
        );
    }

    #[test]
    fn adaptive_fec_tier_matches_core() {
        assert_eq!(
            aisd_adaptive_fec_tier(0.10, 0, 0),
            adaptive_fec::tier(0.10, 0, false)
        );
        assert_eq!(aisd_adaptive_fec_tier(0.10, 0, 0), 3);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 0), 2);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 1), 1);
        assert_eq!(
            aisd_adaptive_fec_tier(0.0, 2, 2),
            1,
            "any nonzero allow_off is true"
        );
        assert_eq!(aisd_adaptive_fec_tier(0.015, 0, 0), 0);
    }

    #[test]
    fn adaptive_fec_next_tier_state_matches_core() {
        let dwell = adaptive_fec::RELAX_DWELL_REPORTS;
        let armed = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 0,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            1,
        );
        assert_eq!(
            armed.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS
        );
        let esc = aisd_adaptive_fec_next_tier_state(
            0.10,
            AisdTierState {
                tier: 0,
                relax_streak: 10,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!((esc.tier, esc.relax_streak), (3, 0));
        let core_next = adaptive_fec::next_tier_state(
            0.0,
            adaptive_fec::TierState::new(0, 5, 0),
            dwell,
            false,
            false,
        );
        let ffi_next = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 5,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!(adaptive_fec::TierState::from(ffi_next), core_next);
    }

    #[test]
    fn adaptive_fec_tier_state_repr_round_trips() {
        let s = adaptive_fec::TierState::new(3, 7, 11);
        assert_eq!(adaptive_fec::TierState::from(AisdTierState::from(s)), s);
    }
}
