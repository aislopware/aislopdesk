//! `packetizer`: the per-frame video SEND hot path over the C ABI.
//!
//! An OPAQUE handle ([`AisdVideoPacketizer`]) wraps the core
//! [`VideoPacketizer`](aislopdesk_core::fragment::VideoPacketizer) — the single source of truth for
//! the MTU split, the per-frame FEC group size, the parity append, and the 19-byte header stamp.
//! This is the symmetric counterpart of the receive-side [`AisdReassembler`](super::reassembler) and
//! makes the send path Rust-owned too. The Swift/Android shell drives it one frame at a time:
//!
//! * [`aisd_video_packetizer_new`] builds the packetizer with the SAME knobs the Swift one took (the
//!   FEC group size `k` and parity-per-group `m`). It constructs the core's NEON-backed
//!   [`ReedSolomonFec`](aislopdesk_core::fec::ReedSolomonFec) internally — the packetizer OWNS its
//!   FEC, so there is no second codec and no double-FEC (mirroring the reassembler). `m == 1` is the
//!   production / byte-identical XOR-equivalent wire. Pass `k == 0` (or `m == 0`) for a NO-FEC
//!   packetizer (no parity fragments) — mirroring `VideoPacketizer(fec: nil)`.
//! * [`aisd_packetize`] fragments ONE AVCC frame (borrowed) into the fully-formed wire datagrams
//!   (each = 19-byte header + payload, data then parity) in transmit order, optionally interleaved
//!   for burst resilience, returning them as ONE owned [`AisdBytesArray`]. The per-frame options
//!   cross by value as a flat [`AisdPacketizeOptions`].
//! * [`aisd_video_packetizer_peek_next_frame_id`] / [`aisd_video_packetizer_peek_next_stream_seq`]
//!   expose the counters the host actor reads BEFORE packetizing (the LTR / recovery-IDR records key
//!   off the frame-id the next `packetize` will assign).
//! * [`aisd_video_packetizer_free`] destroys the handle.
//!
//! ## One staging buffer, no per-fragment recursion
//!
//! The returned [`AisdBytesArray`] holds one owned [`crate::AisdBytes`] per fragment, each already
//! the complete wire datagram (`FrameFragment::encode`). The whole frame is fragmented with a single
//! linear walk and the encode is a single `extend_from_slice` per fragment — O(frame size) heap,
//! O(1) stack. There is no per-fragment recursive borrow (the prior Swift FEC-marshaling bug that
//! stack-overflowed on large keyframes), so a multi-megabyte keyframe is handled flat.
//!
//! ## Memory & safety contract
//!
//! Same as the crate root: the input AVCC frame is BORROWED (read, never freed); each returned
//! fragment buffer is a fresh Rust allocation — release the whole array with
//! [`crate::aisd_bytes_array_free`]. The packetize NEVER panics: a null / oversize guard returns a
//! status, and the core's `u16` fragment-count / payload-length invariants hold by construction for
//! any real frame.

use crate::gf_neon::NeonGf;
use crate::{
    AISD_ERR_NULL, AISD_OK, AisdBytes, AisdBytesArray, AisdStatus, bytes_from_vec,
    bytes_vec_into_raw, free_handle, into_handle, slice_in,
};
use aislopdesk_core::adaptive_fec;
use aislopdesk_core::fec::{FecScheme, ReedSolomonFec};
use aislopdesk_core::fragment::{FrameFragment, PacketizeOptions, VideoPacketizer};
use aislopdesk_core::interleaver::interleave;

/// The per-frame packetize options, flattened for the C ABI.
///
/// Maps field-for-field onto [`PacketizeOptions`] plus the two send-path knobs the core
/// `packetize` does not carry (`fec_group_size` overrides the codec's default `k` per frame, and
/// `interleave` selects the burst-resilient transmit reorder). Field order MUST match the C header's
/// `AisdPacketizeOptions`. The boolean-ish fields are plain `u8` (read as `!= 0`), never a Rust
/// `bool`, so a JNI `jboolean` of any nonzero value is valid (no `bool`-validity UB).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct AisdPacketizeOptions {
    /// Sets the keyframe (IDR) flag on every fragment. Read as `!= 0`.
    pub keyframe: u8,
    /// Sets the crisp static-refresh flag (informational). Read as `!= 0`.
    pub crisp: u8,
    /// Sets bit 6 (LTR) on every fragment so the client acks the frame on decode. Read as `!= 0`.
    pub is_ltr: u8,
    /// Sets bit 7 (encoded via `ForceLTRRefresh`). Read as `!= 0`.
    pub acked_anchored: u8,
    /// WF-4 adaptive-FEC tier (0..=7); selects the per-frame group size and is stamped into the
    /// flags so the client splits data/parity with the same size.
    pub fec_tier: u8,
    /// Run the burst-resilient transmit interleave on the produced fragments. Read as `!= 0`. The
    /// interleave is keyed by the SAME per-frame group size the parity used (m-aware).
    pub interleave: u8,
    /// Host-monotonic ms since session start, stamped on every fragment of this frame (0 = off).
    pub host_send_ts_millis: u32,
    /// Per-frame data-fragment group size `k` the parity + interleave use (the host resolves it from
    /// the tier via `AdaptiveFECPolicy.groupSize`; the core's default is the codec's `k`). When
    /// `0`, the packetizer's configured default group size is used (matching tier 0 / no override).
    pub fec_group_size: usize,
}

impl AisdPacketizeOptions {
    /// Splits the flat options into the core [`PacketizeOptions`] (the flag/tier/timestamp bundle).
    /// `fec_group_size` and `interleave` are consumed by the boundary fn directly, not the core.
    const fn core_options(self) -> PacketizeOptions {
        PacketizeOptions {
            keyframe: self.keyframe != 0,
            crisp: self.crisp != 0,
            host_send_ts_millis: self.host_send_ts_millis,
            fec_tier: self.fec_tier,
            is_ltr: self.is_ltr != 0,
            acked_anchored: self.acked_anchored != 0,
        }
    }
}

/// Opaque per-stream video packetizer (the send hot path).
///
/// Create with [`aisd_video_packetizer_new`], fragment frames with [`aisd_packetize`], read the
/// pre-increment counters with the `peek_*` getters, destroy with [`aisd_video_packetizer_free`].
/// One per video stream; not thread-safe — drive it from the single host send loop. Holds the
/// configured default group size so a frame that does not override it reproduces the codec's `k`.
pub struct AisdVideoPacketizer {
    inner: VideoPacketizer,
    /// The codec's default data-fragment group size (`k`), or 1 for a no-FEC packetizer — the
    /// per-frame override falls back to this when `fec_group_size == 0`.
    default_group_size: usize,
}

/// Builds a packetizer that appends `m` parity shards per group of `k` data fragments.
///
/// The packetizer OWNS a freshly-built NEON-backed Reed-Solomon codec (`[k + m, k]`) — there is no
/// externally-supplied FEC handle and therefore no double-codec (mirroring [`aisd_reassembler_new`]
/// on the receive side). `m == 1` is the production wire (XOR-equivalent, byte-identical). Pass
/// `k == 0` (or `m == 0`) to build a NO-FEC packetizer (no parity fragments) — mirroring
/// `VideoPacketizer(fec: nil)`.
///
/// Returns null (NOT a panic/abort across the boundary) for an invalid FEC config: `k >= 1` but
/// `m >= 1` with `k + m > 255` (the Cauchy index sets must fit GF(2^8)). Destroy a non-null result
/// with [`aisd_video_packetizer_free`].
///
/// [`aisd_reassembler_new`]: super::reassembler::aisd_reassembler_new
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_video_packetizer_new(k: usize, m: usize) -> *mut AisdVideoPacketizer {
    // k == 0 (or m == 0) => no-FEC packetizer, matching `VideoPacketizer(fec: nil)`. A non-zero k
    // with an invalid (k, m) is rejected as null so the core's RS construction asserts never trip
    // across FFI (mirrors `aisd_fec_codec_new` / `aisd_reassembler_new`).
    let (fec, default_group_size): (Option<Box<dyn FecScheme>>, usize) = if k == 0 || m == 0 {
        (None, 1)
    } else if k.saturating_add(m) > 255 {
        return core::ptr::null_mut();
    } else {
        (
            Some(Box::new(ReedSolomonFec::with_backend(k, m, NeonGf)) as Box<dyn FecScheme>),
            k,
        )
    };
    into_handle(AisdVideoPacketizer {
        inner: VideoPacketizer::new(fec),
        default_group_size,
    })
}

/// Destroys a packetizer created by [`aisd_video_packetizer_new`]. No-op on null.
///
/// # Safety
/// `packetizer` must be a pointer from [`aisd_video_packetizer_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_packetizer_free(packetizer: *mut AisdVideoPacketizer) {
    // SAFETY: per the contract, `packetizer` is an unfreed handle from `aisd_video_packetizer_new`.
    unsafe { free_handle(packetizer) }
}

/// The `frame_id` the NEXT [`aisd_packetize`] call will assign (0 for a null handle).
///
/// The host actor reads this BEFORE packetizing so it can record the `frame_id ↔ LTR-token` mapping
/// (and the recovery-IDR keyframe record) for the frame about to be sent — `packetize` increments
/// the counter internally, exactly like the Swift `peekNextFrameID`.
///
/// # Safety
/// `packetizer`, if non-null, must be a live handle from [`aisd_video_packetizer_new`].
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_packetizer_peek_next_frame_id(
    packetizer: *const AisdVideoPacketizer,
) -> u32 {
    // SAFETY: a non-null `packetizer` is a live handle per the contract.
    unsafe { packetizer.as_ref() }.map_or(0, |p| p.inner.peek_next_frame_id())
}

/// The `stream_seq` the next emitted datagram will carry (0 for a null handle).
///
/// # Safety
/// `packetizer`, if non-null, must be a live handle from [`aisd_video_packetizer_new`].
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_packetizer_peek_next_stream_seq(
    packetizer: *const AisdVideoPacketizer,
) -> u32 {
    // SAFETY: a non-null `packetizer` is a live handle per the contract.
    unsafe { packetizer.as_ref() }.map_or(0, |p| p.inner.peek_next_stream_seq())
}

/// Fragments one AVCC frame into fully-formed wire datagrams, writing them to `*out_fragments`.
///
/// `avcc` is the encoded frame's AVCC bytes (length-prefixed NAL units), BORROWED — read, never
/// freed; `avcc` may be null only when `avcc_len == 0` (a zero-byte frame still yields one fragment).
/// `opts` crosses by value. On [`AISD_OK`], `*out_fragments` owns an [`AisdBytesArray`] of one
/// fragment per datagram, each already the complete wire bytes (19-byte header + payload), in
/// transmit order (data fragments, then parity; column-major when `opts.interleave != 0`). Release
/// the whole array with [`crate::aisd_bytes_array_free`].
///
/// The packetizer assigns the per-frame `frame_id` and the monotonic per-datagram `stream_seq`
/// internally, and runs the FEC parity through its OWNED codec (no double-FEC). The per-frame group
/// size is `opts.fec_group_size` (or the codec's default `k` when `0`); the interleave is keyed by
/// the same size (m-aware), so the `m == 1` send order is byte-identical to the pre-port wire.
///
/// Returns [`AISD_ERR_NULL`] for a null `packetizer` / `out_fragments` (or a null `avcc` with a
/// nonzero `avcc_len`), else [`AISD_OK`]. NEVER panics: the only failure is a null argument; an
/// empty frame yields a single one-fragment array.
///
/// # Safety
/// `out_fragments` must be a writable [`AisdBytesArray`]; if `avcc_len != 0`, `avcc` must point to
/// at least `avcc_len` readable bytes. On [`AISD_OK`] `*out_fragments` is overwritten as raw output
/// WITHOUT freeing any prior contents, so release a previously-returned array held in the same
/// storage with [`crate::aisd_bytes_array_free`] first (or use fresh storage) to avoid leaking it.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_packetize(
    packetizer: *mut AisdVideoPacketizer,
    avcc: *const u8,
    avcc_len: usize,
    opts: AisdPacketizeOptions,
    out_fragments: *mut AisdBytesArray,
) -> AisdStatus {
    if packetizer.is_null() || out_fragments.is_null() || (avcc.is_null() && avcc_len != 0) {
        return AISD_ERR_NULL;
    }
    // SAFETY: `avcc` covers `avcc_len` readable bytes per the contract (and the null+len check).
    let frame = unsafe { slice_in(avcc, avcc_len) };
    // SAFETY: `packetizer` is a live handle per the contract and the null check above.
    let p = unsafe { &mut *packetizer };

    // The per-frame group size the parity + interleave both use. The core `packetize` derives the
    // parity group size from the tier (`AdaptiveFECPolicy.groupSize(forTier:default:)`); we pass the
    // host-resolved override as that default so a heavier adaptive tier groups at the requested
    // width, and the interleave is keyed by the IDENTICAL value (so data/parity split + send order
    // agree). `0` falls back to the codec's configured `k` (tier-0 / no override).
    let default_group = if opts.fec_group_size == 0 {
        p.default_group_size
    } else {
        opts.fec_group_size
    };
    let fragments = p
        .inner
        .packetize_with_default_group(frame, opts.core_options(), default_group);

    // Burst-resilient transmit interleave, keyed by the SAME per-frame group size the parity used
    // (OFF tier => group 1 => no-op; tier 0 => default group => identical). m is recovered inside.
    let interleave_group = adaptive_fec::group_size(opts.fec_tier, default_group).unwrap_or(1);
    let ordered = if opts.interleave != 0 {
        interleave(fragments, interleave_group)
    } else {
        fragments
    };

    // Encode each fragment to its full wire bytes (header + payload) into one owned buffer. One
    // linear walk, one `extend_from_slice` per fragment — O(frame size) heap, O(1) stack.
    let items: Vec<AisdBytes> = ordered
        .into_iter()
        .map(|f| bytes_from_vec(f.encode()))
        .collect();
    let (ptr, count) = bytes_vec_into_raw(items);
    // SAFETY: `out_fragments` is non-null per the check above and writable per the contract.
    unsafe { out_fragments.write(AisdBytesArray { items: ptr, count }) };
    AISD_OK
}

/// Reorders already-encoded wire fragments into burst-resilient transmit order, m-aware.
///
/// The standalone counterpart of the `opts.interleave` knob in [`aisd_packetize`] — for callers that
/// hold the fully-encoded datagrams and want only the column-major reorder (e.g. the host's
/// `FragmentInterleaver` API and the loopback validator). Each element of `fragments` is a BORROWED
/// wire datagram (19-byte header + payload); they are parsed, reordered by [`interleave`] (data
/// column-major across FEC groups, then parity column-major across groups — `m` recovered from the
/// parity count), and the reordered datagrams returned as one owned [`AisdBytesArray`] (release with
/// [`crate::aisd_bytes_array_free`]). NO wire change: only the SEND ORDER differs; each datagram's
/// bytes (header + payload) are byte-identical to the input. `group_size <= 1` (or too few fragments)
/// is a no-op pass-through, byte-for-byte.
///
/// Returns [`AISD_ERR_NULL`] for a null `fragments` (with a nonzero `count`) / `out`. NEVER panics:
/// a datagram that fails to parse is dropped from the reorder set (a corrupt fragment never crashes
/// the send loop), so the output is always a valid owned array.
///
/// # Safety
/// `out` must be writable; if `count != 0`, `fragments` must point to `count` readable [`AisdBytes`],
/// each whose non-empty `(ptr, len)` covers `len` readable bytes for the call. On [`AISD_OK`] `*out`
/// is overwritten as raw output WITHOUT freeing prior contents (release a prior array first).
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_interleave(
    fragments: *const AisdBytes,
    count: usize,
    group_size: usize,
    out: *mut AisdBytesArray,
) -> AisdStatus {
    if out.is_null() || (fragments.is_null() && count != 0) {
        return AISD_ERR_NULL;
    }
    // Parse each borrowed wire datagram into a core fragment. An un-parseable datagram is dropped
    // (never a crash) — the reorder is a pure permutation of the fragments it could parse.
    let parsed: Vec<FrameFragment> = if count == 0 {
        Vec::new()
    } else {
        // SAFETY: per the contract, `fragments` covers `count` readable `AisdBytes`.
        let items = unsafe { core::slice::from_raw_parts(fragments, count) };
        items
            .iter()
            .filter_map(|b| {
                // SAFETY: each non-empty `(ptr, len)` covers `len` readable bytes per the contract.
                let bytes = unsafe { slice_in(b.ptr, b.len) };
                FrameFragment::decode(bytes).ok()
            })
            .collect()
    };
    let ordered = interleave(parsed, group_size);
    let items: Vec<AisdBytes> = ordered
        .into_iter()
        .map(|f| bytes_from_vec(f.encode()))
        .collect();
    let (ptr, n) = bytes_vec_into_raw(items);
    // SAFETY: `out` is non-null per the check above and writable per the contract.
    unsafe {
        out.write(AisdBytesArray {
            items: ptr,
            count: n,
        });
    };
    AISD_OK
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` / `&x` -> `*mut` / `*const` coercions.
    #![allow(clippy::borrow_as_ptr)]
    use super::*;
    use aislopdesk_core::fragment::{Flags, FrameFragment};

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it via the array).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        unsafe {
            if b.ptr.is_null() || b.len == 0 {
                Vec::new()
            } else {
                core::slice::from_raw_parts(b.ptr, b.len).to_vec()
            }
        }
    }

    fn default_opts() -> AisdPacketizeOptions {
        AisdPacketizeOptions {
            keyframe: 0,
            crisp: 0,
            is_ltr: 0,
            acked_anchored: 0,
            fec_tier: 0,
            interleave: 0,
            host_send_ts_millis: 0,
            fec_group_size: 0,
        }
    }

    /// Packetizes a frame through the C ABI, decoding each returned datagram back to a fragment.
    unsafe fn packetize(
        p: *mut AisdVideoPacketizer,
        frame: &[u8],
        opts: AisdPacketizeOptions,
    ) -> Vec<FrameFragment> {
        let mut out = AisdBytesArray::EMPTY;
        let status = unsafe { aisd_packetize(p, frame.as_ptr(), frame.len(), opts, &mut out) };
        assert_eq!(status, AISD_OK);
        let frags: Vec<FrameFragment> = unsafe {
            (0..out.count)
                .map(|i| {
                    let bytes = view(*out.items.add(i));
                    FrameFragment::decode(&bytes).expect("each returned datagram decodes")
                })
                .collect()
        };
        unsafe {
            crate::aisd_bytes_array_free(&mut out);
            crate::aisd_bytes_array_free(&mut out); // idempotent
        }
        assert!(out.items.is_null() && out.count == 0);
        frags
    }

    /// Concatenates the data fragments' payloads back into the original AVCC frame.
    fn reassemble_data(frags: &[FrameFragment]) -> Vec<u8> {
        let mut by_index: Vec<(u16, Vec<u8>)> = frags
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .map(|f| (f.header.frag_index, f.payload.clone()))
            .collect();
        by_index.sort_by_key(|(i, _)| *i);
        by_index.into_iter().flat_map(|(_, p)| p).collect()
    }

    #[test]
    fn new_rejects_invalid_fec_but_allows_no_fec() {
        // k == 0 => no-FEC (valid). Invalid RS (k+m>255) => null. m == 0 => no-FEC.
        let no_fec = aisd_video_packetizer_new(0, 1);
        assert!(!no_fec.is_null());
        unsafe { aisd_video_packetizer_free(no_fec) };
        assert!(
            aisd_video_packetizer_new(200, 56).is_null(),
            "k+m>255 rejected"
        );
        let m0 = aisd_video_packetizer_new(5, 0);
        assert!(!m0.is_null());
        unsafe { aisd_video_packetizer_free(m0) };
        unsafe { aisd_video_packetizer_free(core::ptr::null_mut()) }; // no-op
    }

    #[test]
    fn empty_frame_yields_one_fragment() {
        unsafe {
            let p = aisd_video_packetizer_new(0, 1);
            let frags = packetize(p, &[], default_opts());
            assert_eq!(frags.len(), 1);
            assert_eq!(frags[0].header.frag_count, 1);
            assert!(frags[0].payload.is_empty());
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn large_frame_chunks_by_mtu_with_monotonic_seq() {
        unsafe {
            let p = aisd_video_packetizer_new(0, 1);
            let frame = vec![0x5Au8; VideoPacketizer::MAX_PAYLOAD_SIZE * 2 + 10];
            let opts = AisdPacketizeOptions {
                keyframe: 1,
                ..default_opts()
            };
            let frags = packetize(p, &frame, opts);
            assert_eq!(frags.len(), 3);
            assert_eq!(frags[0].payload.len(), VideoPacketizer::MAX_PAYLOAD_SIZE);
            assert_eq!(frags[2].payload.len(), 10);
            // monotonic stream_seq, shared frame_id 0, keyframe stamped.
            assert_eq!(frags[0].header.stream_seq, 0);
            assert_eq!(frags[2].header.stream_seq, 2);
            assert!(frags.iter().all(|f| f.header.frame_id == 0));
            assert!(
                frags
                    .iter()
                    .all(|f| f.header.flags.contains(Flags::KEYFRAME))
            );
            // data fragments concatenate back to the original AVCC.
            assert_eq!(reassemble_data(&frags), frame);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn fec_appends_parity_m1_wire_identical_order() {
        unsafe {
            // k=5 m=1: 6 data fragments => ceil(6/5)=2 parity. No interleave => data then parity in
            // index order, the byte-identical send order.
            let p = aisd_video_packetizer_new(5, 1);
            let frame = vec![3u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 6];
            let frags = packetize(p, &frame, default_opts());
            let data = frags
                .iter()
                .filter(|f| !f.header.flags.contains(Flags::PARITY))
                .count();
            let parity = frags
                .iter()
                .filter(|f| f.header.flags.contains(Flags::PARITY))
                .count();
            assert_eq!(data, 6);
            assert_eq!(parity, 2);
            assert!(frags.iter().all(|f| f.header.frag_count == 8));
            // send order is data (index 0..5) then parity (6,7) — unchanged.
            let order: Vec<u16> = frags.iter().map(|f| f.header.frag_index).collect();
            assert_eq!(order, vec![0, 1, 2, 3, 4, 5, 6, 7]);
            assert_eq!(reassemble_data(&frags), frame);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn m2_produces_two_parity_per_group() {
        unsafe {
            // k=2 m=2: 5 data fragments => ceil(5/2)=3 groups * 2 = 6 parity.
            let p = aisd_video_packetizer_new(2, 2);
            let frame = vec![7u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5];
            // fec_group_size override to 2 so the per-frame group matches the codec's k.
            let opts = AisdPacketizeOptions {
                fec_group_size: 2,
                ..default_opts()
            };
            let frags = packetize(p, &frame, opts);
            let parity = frags
                .iter()
                .filter(|f| f.header.flags.contains(Flags::PARITY))
                .count();
            assert_eq!(parity, 6, "3 groups * m=2");
            assert_eq!(reassemble_data(&frags), frame);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn interleave_reorders_transmit_but_preserves_set_and_data() {
        unsafe {
            // 7 data fragments, group 3, m=1 => column-major [0,3,6,1,4,2,5], parity last.
            let p = aisd_video_packetizer_new(3, 1);
            let frame = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 7];
            let opts = AisdPacketizeOptions {
                interleave: 1,
                fec_group_size: 3,
                ..default_opts()
            };
            let frags = packetize(p, &frame, opts);
            let data_order: Vec<u16> = frags
                .iter()
                .filter(|f| !f.header.flags.contains(Flags::PARITY))
                .map(|f| f.header.frag_index)
                .collect();
            assert_eq!(data_order, vec![0, 3, 6, 1, 4, 2, 5]);
            // data still reassembles (reassemble sorts by index, so reorder is transparent).
            assert_eq!(reassemble_data(&frags), frame);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn peek_counters_track_packetize() {
        unsafe {
            let p = aisd_video_packetizer_new(0, 1);
            assert_eq!(aisd_video_packetizer_peek_next_frame_id(p), 0);
            assert_eq!(aisd_video_packetizer_peek_next_stream_seq(p), 0);
            let frame = vec![1u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 2];
            let frags = packetize(p, &frame, default_opts());
            assert_eq!(frags.len(), 2);
            // one frame consumed, two datagrams emitted.
            assert_eq!(aisd_video_packetizer_peek_next_frame_id(p), 1);
            assert_eq!(aisd_video_packetizer_peek_next_stream_seq(p), 2);
            // null handle getters return 0.
            assert_eq!(
                aisd_video_packetizer_peek_next_frame_id(core::ptr::null()),
                0
            );
            assert_eq!(
                aisd_video_packetizer_peek_next_stream_seq(core::ptr::null()),
                0
            );
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn standalone_interleave_reorders_wire_datagrams_byte_identical() {
        unsafe {
            // Build 7 data + parity fragments (no interleave), encode them, then run the standalone
            // interleave over the wire datagrams and assert the same column-major data order, the
            // same set, and byte-identical datagram bytes (only the send order changed).
            let p = aisd_video_packetizer_new(3, 1);
            let frame = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 7];
            let opts = AisdPacketizeOptions {
                fec_group_size: 3,
                ..default_opts()
            };
            let mut produced = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_packetize(p, frame.as_ptr(), frame.len(), opts, &mut produced),
                AISD_OK
            );
            // Borrow the produced datagrams back in as the interleave input.
            let borrowed: Vec<AisdBytes> = (0..produced.count)
                .map(|i| {
                    let b = *produced.items.add(i);
                    AisdBytes {
                        ptr: b.ptr,
                        len: b.len,
                        cap: 0,
                    }
                })
                .collect();
            let mut out = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_interleave(borrowed.as_ptr(), borrowed.len(), 3, &mut out),
                AISD_OK
            );
            assert_eq!(
                out.count, produced.count,
                "permutation: same fragment count"
            );
            let frags: Vec<FrameFragment> = (0..out.count)
                .map(|i| FrameFragment::decode(&view(*out.items.add(i))).unwrap())
                .collect();
            let data_order: Vec<u16> = frags
                .iter()
                .filter(|f| !f.header.flags.contains(Flags::PARITY))
                .map(|f| f.header.frag_index)
                .collect();
            assert_eq!(data_order, vec![0, 3, 6, 1, 4, 2, 5]);
            // each reordered datagram's bytes are byte-identical to one of the inputs (no wire change).
            let inputs: std::collections::BTreeSet<Vec<u8>> = (0..produced.count)
                .map(|i| view(*produced.items.add(i)))
                .collect();
            let outputs: std::collections::BTreeSet<Vec<u8>> =
                (0..out.count).map(|i| view(*out.items.add(i))).collect();
            assert_eq!(
                inputs, outputs,
                "the datagram bytes are unchanged — only the order"
            );
            crate::aisd_bytes_array_free(&mut out);
            crate::aisd_bytes_array_free(&mut produced);
            aisd_video_packetizer_free(p);

            // null/empty guards.
            assert_eq!(
                aisd_interleave(core::ptr::null(), 3, 3, &mut out),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_interleave(core::ptr::null(), 0, 3, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            // empty input => empty array, OK.
            assert_eq!(aisd_interleave(core::ptr::null(), 0, 3, &mut out), AISD_OK);
            assert_eq!(out.count, 0);
            crate::aisd_bytes_array_free(&mut out);
        }
    }

    #[test]
    fn null_guards() {
        unsafe {
            let p = aisd_video_packetizer_new(0, 1);
            let mut out = AisdBytesArray::EMPTY;
            let frame = [1u8, 2, 3];
            assert_eq!(
                aisd_packetize(
                    core::ptr::null_mut(),
                    frame.as_ptr(),
                    3,
                    default_opts(),
                    &mut out
                ),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_packetize(p, frame.as_ptr(), 3, default_opts(), core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            // null avcc with a nonzero len.
            assert_eq!(
                aisd_packetize(p, core::ptr::null(), 3, default_opts(), &mut out),
                AISD_ERR_NULL
            );
            // null avcc with len 0 is allowed (empty frame).
            assert_eq!(
                aisd_packetize(p, core::ptr::null(), 0, default_opts(), &mut out),
                AISD_OK
            );
            assert_eq!(out.count, 1);
            crate::aisd_bytes_array_free(&mut out);
            aisd_video_packetizer_free(p);
        }
    }
}
