//! `decode_gate`: opaque handle (client pre-emptive drop-until-anchor decode admission). Driven
//! on the client session actor: `note_loss` / `note_*_failure` / `note_decode_succeeded` fold
//! state, verdict gates each reassembled frame — per-frame cadence, never per-fragment. One owner
//! (`AislopdeskVideoClientSession`), actor-serialized. Same "Rust owns the state" boundary as the
//! deduper. Mode/Verdict cross as `u32` discriminants (Open/Submit = 0); the lost-frame bounds
//! cross as a (`u32 out`, `u8 is_some`) Option pair.

use aislopdesk_core::decode_gate::{
    DecodeGate, Mode as DecodeGateMode, Verdict as DecodeGateVerdict,
};

/// [`DecodeGateMode::Open`] discriminant — chain intact, everything submits.
pub const AISD_DECODE_GATE_MODE_OPEN: u32 = 0;
/// [`DecodeGateMode::BrokenChain`] discriminant — loss since the last anchor, session alive.
pub const AISD_DECODE_GATE_MODE_BROKEN_CHAIN: u32 = 1;
/// [`DecodeGateMode::NeedKeyframe`] discriminant — session torn down / never configured.
pub const AISD_DECODE_GATE_MODE_NEED_KEYFRAME: u32 = 2;

/// [`DecodeGateVerdict::Submit`] discriminant — feed this frame to the decoder.
pub const AISD_DECODE_GATE_VERDICT_SUBMIT: u32 = 0;
/// [`DecodeGateVerdict::Drop`] discriminant — drop this frame (would tear the session down).
pub const AISD_DECODE_GATE_VERDICT_DROP: u32 = 1;

/// Opaque client drop-until-anchor decode gate.
///
/// Create with [`aisd_decode_gate_new`], fold state with the `_note_*` calls, query each frame
/// with [`aisd_decode_gate_verdict`], destroy with [`aisd_decode_gate_free`]. One per client
/// session; not thread-safe (drive it from a single isolation domain / actor).
pub struct AisdDecodeGate {
    inner: DecodeGate,
}

const fn decode_gate_mode_to_c(mode: DecodeGateMode) -> u32 {
    match mode {
        DecodeGateMode::Open => AISD_DECODE_GATE_MODE_OPEN,
        DecodeGateMode::BrokenChain => AISD_DECODE_GATE_MODE_BROKEN_CHAIN,
        DecodeGateMode::NeedKeyframe => AISD_DECODE_GATE_MODE_NEED_KEYFRAME,
    }
}

/// Creates a fresh, open decode gate. Destroy it with [`aisd_decode_gate_free`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_decode_gate_new() -> *mut AisdDecodeGate {
    Box::into_raw(Box::new(AisdDecodeGate {
        inner: DecodeGate::new(),
    }))
}

/// Destroys a gate created by [`aisd_decode_gate_new`]. No-op on null.
///
/// # Safety
/// `gate` must be a pointer from [`aisd_decode_gate_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_free(gate: *mut AisdDecodeGate) {
    unsafe {
        if !gate.is_null() {
            drop(Box::from_raw(gate));
        }
    }
}

/// The current admission mode as an `AISD_DECODE_GATE_MODE_*` discriminant (Open `0` for a null
/// handle — a missing gate admits everything).
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_mode(gate: *const AisdDecodeGate) -> u32 {
    unsafe {
        gate.as_ref().map_or(AISD_DECODE_GATE_MODE_OPEN, |g| {
            decode_gate_mode_to_c(g.inner.mode())
        })
    }
}

/// The OLDEST lost frame id of the episode. Returns `1` and writes the id to `out` when present,
/// `0` (leaving `out` untouched) for none or a null handle.
///
/// # Safety
/// `gate`, if non-null, must be a live handle; `out`, if the return is `1`, must be writable.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_min_lost_frame_id(
    gate: *const AisdDecodeGate,
    out: *mut u32,
) -> u8 {
    unsafe {
        match gate.as_ref().and_then(|g| g.inner.min_lost_frame_id()) {
            Some(id) if !out.is_null() => {
                *out = id;
                1
            }
            _ => 0,
        }
    }
}

/// The NEWEST lost frame id of the episode. Returns `1` and writes the id to `out` when present,
/// `0` (leaving `out` untouched) for none or a null handle.
///
/// # Safety
/// `gate`, if non-null, must be a live handle; `out`, if the return is `1`, must be writable.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_max_lost_frame_id(
    gate: *const AisdDecodeGate,
    out: *mut u32,
) -> u8 {
    unsafe {
        match gate.as_ref().and_then(|g| g.inner.max_lost_frame_id()) {
            Some(id) if !out.is_null() => {
                *out = id;
                1
            }
            _ => 0,
        }
    }
}

/// Folds one unrecoverably-lost frame. No-op on null. Wraps [`DecodeGate::note_loss`].
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_note_loss(gate: *mut AisdDecodeGate, frame_id: u32) {
    unsafe {
        if let Some(g) = gate.as_mut() {
            g.inner.note_loss(frame_id);
        }
    }
}

/// Records a hard decode failure (session torn down). No-op on null. Wraps
/// [`DecodeGate::note_hard_decode_failure`].
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_decode_gate_note_hard_decode_failure(
    gate: *mut AisdDecodeGate,
) {
    unsafe {
        if let Some(g) = gate.as_mut() {
            g.inner.note_hard_decode_failure();
        }
    }
}

/// Records that the decoder is awaiting a keyframe. No-op on null. Wraps
/// [`DecodeGate::note_awaiting_keyframe`].
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_decode_gate_note_awaiting_keyframe(gate: *mut AisdDecodeGate) {
    unsafe {
        if let Some(g) = gate.as_mut() {
            g.inner.note_awaiting_keyframe();
        }
    }
}

/// Admission decision for one reassembled frame as an `AISD_DECODE_GATE_VERDICT_*` discriminant.
///
/// `keyframe` / `acked_anchored` are bytes read `!= 0`. Pure — never mutates; returns Submit `0`
/// for a null handle (a missing gate admits everything). Wraps [`DecodeGate::verdict`].
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_verdict(
    gate: *const AisdDecodeGate,
    frame_id: u32,
    keyframe: u8,
    acked_anchored: u8,
) -> u32 {
    unsafe {
        gate.as_ref().map_or(AISD_DECODE_GATE_VERDICT_SUBMIT, |g| {
            match g
                .inner
                .verdict(frame_id, keyframe != 0, acked_anchored != 0)
            {
                DecodeGateVerdict::Submit => AISD_DECODE_GATE_VERDICT_SUBMIT,
                DecodeGateVerdict::Drop => AISD_DECODE_GATE_VERDICT_DROP,
            }
        })
    }
}

/// Folds one successful decode (`keyframe` read `!= 0`). No-op on null. Wraps
/// [`DecodeGate::note_decode_succeeded`].
///
/// # Safety
/// `gate`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_decode_gate_note_decode_succeeded(
    gate: *mut AisdDecodeGate,
    frame_id: u32,
    keyframe: u8,
) {
    unsafe {
        if let Some(g) = gate.as_mut() {
            g.inner.note_decode_succeeded(frame_id, keyframe != 0);
        }
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn decode_gate_handle_gates_until_anchor() {
        unsafe {
            let g = aisd_decode_gate_new();
            assert!(!g.is_null());
            // Fresh gate is Open ⇒ everything submits.
            assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_OPEN);
            assert_eq!(
                aisd_decode_gate_verdict(g, 10, 0, 0),
                AISD_DECODE_GATE_VERDICT_SUBMIT
            );
            let mut id: u32 = 12345;
            assert_eq!(aisd_decode_gate_min_lost_frame_id(g, &mut id), 0);
            assert_eq!(id, 12345); // untouched when none.

            // A loss opens a broken-chain episode.
            aisd_decode_gate_note_loss(g, 100);
            aisd_decode_gate_note_loss(g, 110);
            assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_BROKEN_CHAIN);
            assert_eq!(aisd_decode_gate_min_lost_frame_id(g, &mut id), 1);
            assert_eq!(id, 100);
            assert_eq!(aisd_decode_gate_max_lost_frame_id(g, &mut id), 1);
            assert_eq!(id, 110);
            // Delta between losses drops; pre-break delta + keyframe + acked anchor submit.
            assert_eq!(
                aisd_decode_gate_verdict(g, 105, 0, 0),
                AISD_DECODE_GATE_VERDICT_DROP
            );
            assert_eq!(
                aisd_decode_gate_verdict(g, 99, 0, 0),
                AISD_DECODE_GATE_VERDICT_SUBMIT
            );
            assert_eq!(
                aisd_decode_gate_verdict(g, 111, 0, 1),
                AISD_DECODE_GATE_VERDICT_SUBMIT
            );

            // A hard failure escalates to need-keyframe (acked anchor no longer enough).
            aisd_decode_gate_note_hard_decode_failure(g);
            assert_eq!(
                aisd_decode_gate_mode(g),
                AISD_DECODE_GATE_MODE_NEED_KEYFRAME
            );
            assert_eq!(
                aisd_decode_gate_verdict(g, 111, 0, 1),
                AISD_DECODE_GATE_VERDICT_DROP
            );
            assert_eq!(
                aisd_decode_gate_verdict(g, 112, 1, 0),
                AISD_DECODE_GATE_VERDICT_SUBMIT
            );
            // A keyframe newer than every loss re-opens the gate.
            aisd_decode_gate_note_decode_succeeded(g, 112, 1);
            assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_OPEN);
            assert_eq!(aisd_decode_gate_min_lost_frame_id(g, &mut id), 0);

            aisd_decode_gate_free(g);
            aisd_decode_gate_free(core::ptr::null_mut()); // no-op
            // Null handle: Open mode, Submit verdict, no lost bounds.
            assert_eq!(
                aisd_decode_gate_mode(core::ptr::null()),
                AISD_DECODE_GATE_MODE_OPEN
            );
            assert_eq!(
                aisd_decode_gate_verdict(core::ptr::null(), 1, 0, 0),
                AISD_DECODE_GATE_VERDICT_SUBMIT
            );
            assert_eq!(
                aisd_decode_gate_max_lost_frame_id(core::ptr::null(), &mut id),
                0
            );
        }
    }
}
