//! `recovery`: client→host loss-recovery / ack / cursor-reship / netstats codec. Per recovery
//! datagram (a few/sec during loss) and per netstats report (~1 Hz); the body is all-scalar (no
//! owned buffers), so it crosses by value both ways — no allocation, no `*_free`.

use super::{slice_in, status_for_video_error};
use crate::{
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec,
};
use aislopdesk_core::recovery::{NetworkStatsReport, RecoveryMessage};

/// [`RecoveryMessage::Ack`] discriminator (`kind`).
pub const AISD_RECOVERY_ACK: u8 = 1;
/// [`RecoveryMessage::RequestLtrRefresh`] discriminator.
pub const AISD_RECOVERY_REQUEST_LTR_REFRESH: u8 = 2;
/// [`RecoveryMessage::RequestIdr`] discriminator.
pub const AISD_RECOVERY_REQUEST_IDR: u8 = 3;
/// [`RecoveryMessage::RequestCursorShape`] discriminator.
pub const AISD_RECOVERY_REQUEST_CURSOR_SHAPE: u8 = 4;
/// [`RecoveryMessage::NetworkStats`] discriminator.
pub const AISD_RECOVERY_NETWORK_STATS: u8 = 5;

/// A client→host network-feedback report, flattened for the C ABI.
///
/// Field-for-field [`NetworkStatsReport`] (eleven `u32`s). All fields are RELATIVE (windowed
/// counters / a host-stamp echo / client-local deltas), so the host derives RTT in its own clock
/// without cross-machine skew. Crosses by value.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AisdNetworkStats {
    /// Complete frames received this window.
    pub frames_received: u32,
    /// Of those, how many were completed via FEC recovery.
    pub fec_recovered: u32,
    /// Frames declared unrecoverably lost this window.
    pub unrecovered: u32,
    /// The newest `host_send_ts_millis` observed on a video fragment (0 = none).
    pub latest_host_send_ts: u32,
    /// Client-local elapsed ms since it observed `latest_host_send_ts`.
    pub client_hold_ms: u32,
    /// Inter-arrival jitter (microseconds), RFC3550 2nd-difference form.
    pub owd_jitter_micros: u32,
    /// Delay-gradient `modifiedTrend` ×1000, clamped, as an `i32` bit-pattern (0 = inert).
    pub owd_trend_milli: u32,
    /// Detector flags: bits 0-1 = state, bits 8-15 = `min(num_deltas, 255)`.
    pub owd_trend_flags: u32,
    /// Windowed count of presents that ended a dense-flow late gap.
    pub pacer_late_frames: u32,
    /// Windowed count of late-gap episodes opened (superset of `pacer_late_frames`).
    pub pacer_present_gaps: u32,
    /// Gauge: the client pacer's live presentation depth (0 = no pacer attached).
    pub pacer_depth: u32,
}

impl AisdNetworkStats {
    const fn to_core(self) -> NetworkStatsReport {
        NetworkStatsReport {
            frames_received: self.frames_received,
            fec_recovered: self.fec_recovered,
            unrecovered: self.unrecovered,
            latest_host_send_ts: self.latest_host_send_ts,
            client_hold_ms: self.client_hold_ms,
            owd_jitter_micros: self.owd_jitter_micros,
            owd_trend_milli: self.owd_trend_milli,
            owd_trend_flags: self.owd_trend_flags,
            pacer_late_frames: self.pacer_late_frames,
            pacer_present_gaps: self.pacer_present_gaps,
            pacer_depth: self.pacer_depth,
        }
    }
    const fn from_core(r: NetworkStatsReport) -> Self {
        Self {
            frames_received: r.frames_received,
            fec_recovered: r.fec_recovered,
            unrecovered: r.unrecovered,
            latest_host_send_ts: r.latest_host_send_ts,
            client_hold_ms: r.client_hold_ms,
            owd_jitter_micros: r.owd_jitter_micros,
            owd_trend_milli: r.owd_trend_milli,
            owd_trend_flags: r.owd_trend_flags,
            pacer_late_frames: r.pacer_late_frames,
            pacer_present_gaps: r.pacer_present_gaps,
            pacer_depth: r.pacer_depth,
        }
    }
}

/// A client→host recovery message, flattened for the C ABI.
///
/// `kind` (`AISD_RECOVERY_*`) selects which fields are meaningful: `ACK` → `stream_seq`;
/// `REQUEST_LTR_REFRESH` → `from_frame_id`/`to_frame_id`/`last_decoded_frame_id`; `REQUEST_IDR`
/// → `last_decoded_frame_id`; `REQUEST_CURSOR_SHAPE` → `shape_id`; `NETWORK_STATS` → `stats`.
/// All fields are scalar, so the struct crosses by value with no owned buffers (no `*_free`).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AisdRecoveryMessage {
    /// Message discriminator (`AISD_RECOVERY_*`).
    pub kind: u8,
    /// `ACK.stream_seq` (WF-8 reuse: an LTR `frame_id` in this field).
    pub stream_seq: u32,
    /// `REQUEST_LTR_REFRESH` lost-range start frame id.
    pub from_frame_id: u32,
    /// `REQUEST_LTR_REFRESH` lost-range end frame id.
    pub to_frame_id: u32,
    /// `REQUEST_LTR_REFRESH` / `REQUEST_IDR` decode frontier (the wire sentinel = nothing decoded).
    pub last_decoded_frame_id: u32,
    /// `REQUEST_CURSOR_SHAPE` missing shape id.
    pub shape_id: u16,
    /// `NETWORK_STATS` report payload.
    pub stats: AisdNetworkStats,
}

/// Rebuilds a core [`RecoveryMessage`] from the caller's C struct, validating the `kind`.
const fn c_to_recovery_message(m: &AisdRecoveryMessage) -> Result<RecoveryMessage, AisdStatus> {
    let message = match m.kind {
        AISD_RECOVERY_ACK => RecoveryMessage::Ack {
            stream_seq: m.stream_seq,
        },
        AISD_RECOVERY_REQUEST_LTR_REFRESH => RecoveryMessage::RequestLtrRefresh {
            from_frame_id: m.from_frame_id,
            to_frame_id: m.to_frame_id,
            last_decoded_frame_id: m.last_decoded_frame_id,
        },
        AISD_RECOVERY_REQUEST_IDR => RecoveryMessage::RequestIdr {
            last_decoded_frame_id: m.last_decoded_frame_id,
        },
        AISD_RECOVERY_REQUEST_CURSOR_SHAPE => RecoveryMessage::RequestCursorShape {
            shape_id: m.shape_id,
        },
        AISD_RECOVERY_NETWORK_STATS => RecoveryMessage::NetworkStats(m.stats.to_core()),
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(message)
}

/// Flattens a core [`RecoveryMessage`] into the C struct.
fn recovery_message_to_c(message: &RecoveryMessage) -> AisdRecoveryMessage {
    let mut out = AisdRecoveryMessage {
        kind: message.message_type(),
        ..AisdRecoveryMessage::default()
    };
    match message {
        RecoveryMessage::Ack { stream_seq } => out.stream_seq = *stream_seq,
        RecoveryMessage::RequestLtrRefresh {
            from_frame_id,
            to_frame_id,
            last_decoded_frame_id,
        } => {
            out.from_frame_id = *from_frame_id;
            out.to_frame_id = *to_frame_id;
            out.last_decoded_frame_id = *last_decoded_frame_id;
        }
        RecoveryMessage::RequestIdr {
            last_decoded_frame_id,
        } => out.last_decoded_frame_id = *last_decoded_frame_id,
        RecoveryMessage::RequestCursorShape { shape_id } => out.shape_id = *shape_id,
        RecoveryMessage::NetworkStats(r) => out.stats = AisdNetworkStats::from_core(*r),
    }
    out
}

/// Encodes a caller-built [`AisdRecoveryMessage`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_message_encode(
    msg: *const AisdRecoveryMessage,
    out: *mut AisdBytes,
) -> AisdStatus {
    unsafe {
        if msg.is_null() || out.is_null() {
            return AISD_ERR_NULL;
        }
        match c_to_recovery_message(&*msg) {
            Ok(message) => {
                out.write(bytes_from_vec(message.encode()));
                AISD_OK
            }
            Err(status) => status,
        }
    }
}

/// Decodes a recovery message into `*out`.
///
/// `data` may be null only when `len == 0`. Maps an unknown type / trailing bytes to
/// [`crate::AISD_ERR_MALFORMED`] and a short body to [`crate::AISD_ERR_TRUNCATED`]. The output is
/// all-scalar (no owned buffer), so there is no `*_free`.
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_recovery_message_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdRecoveryMessage,
) -> AisdStatus {
    unsafe {
        if out.is_null() || (data.is_null() && len != 0) {
            return AISD_ERR_NULL;
        }
        match RecoveryMessage::decode(slice_in(data, len)) {
            Ok(message) => {
                out.write(recovery_message_to_c(&message));
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
    use crate::AISD_ERR_MALFORMED;

    fn zeroed_recovery() -> AisdRecoveryMessage {
        AisdRecoveryMessage::default()
    }

    #[test]
    fn recovery_message_round_trips_every_variant() {
        unsafe {
            // RequestLtrRefresh — three frame ids.
            let mut msg = zeroed_recovery();
            msg.kind = AISD_RECOVERY_REQUEST_LTR_REFRESH;
            msg.from_frame_id = 50;
            msg.to_frame_id = 52;
            msg.last_decoded_frame_id = 49;
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_recovery_message_encode(&msg, &mut frame), AISD_OK);
            let mut out = zeroed_recovery();
            assert_eq!(
                aisd_recovery_message_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out, msg);
            crate::aisd_bytes_free(frame);

            // NetworkStats — a full eleven-field report (incl. a negative trend bit-pattern).
            let mut stats = zeroed_recovery();
            stats.kind = AISD_RECOVERY_NETWORK_STATS;
            stats.stats = AisdNetworkStats {
                frames_received: 600,
                fec_recovered: 12,
                unrecovered: 3,
                latest_host_send_ts: 1_234_567,
                client_hold_ms: 7,
                owd_jitter_micros: 850,
                owd_trend_milli: (-987_i32) as u32,
                owd_trend_flags: (42_u32 << 8) | 1,
                pacer_late_frames: 4,
                pacer_present_gaps: 6,
                pacer_depth: 2,
            };
            let mut sframe = AisdBytes::EMPTY;
            assert_eq!(aisd_recovery_message_encode(&stats, &mut sframe), AISD_OK);
            let mut sout = zeroed_recovery();
            assert_eq!(
                aisd_recovery_message_decode(sframe.ptr, sframe.len, &mut sout),
                AISD_OK
            );
            assert_eq!(sout, stats);
            crate::aisd_bytes_free(sframe);
        }
    }

    #[test]
    fn recovery_message_rejects_trailing_bytes_and_unknown_kind() {
        unsafe {
            // A valid Ack body + one trailing byte → malformed (byte-keyed dedup contract).
            let mut ack = zeroed_recovery();
            ack.kind = AISD_RECOVERY_ACK;
            ack.stream_seq = 1;
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_recovery_message_encode(&ack, &mut frame), AISD_OK);
            let mut padded = core::slice::from_raw_parts(frame.ptr, frame.len).to_vec();
            padded.push(0);
            let mut out = zeroed_recovery();
            assert_eq!(
                aisd_recovery_message_decode(padded.as_ptr(), padded.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            crate::aisd_bytes_free(frame);

            // An unknown kind cannot encode.
            let mut bad = zeroed_recovery();
            bad.kind = 99;
            let mut bframe = AisdBytes::EMPTY;
            assert_eq!(
                aisd_recovery_message_encode(&bad, &mut bframe),
                AISD_ERR_INVALID_ARGUMENT
            );
        }
    }
}
