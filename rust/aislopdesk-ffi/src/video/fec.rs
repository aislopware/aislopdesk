//! `fec`: the Reed-Solomon erasure codec over the C ABI, backed by the NEON [`NeonGf`] region
//! kernel on Apple Silicon (scalar fallback elsewhere).
//!
//! The codec is an OPAQUE handle ([`AisdFecCodec`]) wrapping a
//! [`ReedSolomonFec<NeonGf>`](aislopdesk_core::fec::ReedSolomonFec): `*_new(k, m)` builds it,
//! `*_free` destroys it. [`aisd_fec_parity`] produces the per-group parity shards as an owned
//! [`AisdBytesArray`]; [`aisd_fec_recover`] fills recoverable data holes in place. Both are
//! per-frame on the realtime media path, so they go through the same Rust core every client runs.
//!
//! ## Hole vs empty shard
//!
//! A data shard can legitimately be zero-length (an empty payload), which is NOT the same as a
//! *lost* shard. The recover path therefore takes an explicit `present` mask (`1` = the shard's
//! bytes are valid, `0` = it is a hole to repair) rather than overloading "empty `AisdBytes`" to
//! mean "missing" — that would make an empty-but-present shard indistinguishable from a hole.
//!
//! ## Ownership
//!
//! * `aisd_fec_parity` returns owned shards in an [`AisdBytesArray`]; release the whole array with
//!   [`crate::aisd_bytes_array_free`].
//! * `aisd_fec_recover` writes a fresh Rust-owned [`AisdBytes`] into each `data[i]` slot it fills;
//!   the caller frees each recovered shard with [`crate::aisd_bytes_free`] (the input data buffers
//!   are borrowed and never freed by Rust).
//! * Every boundary function validates its arguments and degrades (null / `!ok` / leave-the-hole)
//!   on hostile input; none ever panics.

use crate::gf_neon::NeonGf;
use crate::{
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdBytesArray, AisdStatus,
    bytes_from_vec, bytes_vec_into_raw, copy_in, free_handle, into_handle, slice_in,
};
use aislopdesk_core::fec::{FecScheme, ReedSolomonFec};

/// Opaque NEON-backed Reed-Solomon FEC codec.
///
/// Create with [`aisd_fec_codec_new`], compute parity with [`aisd_fec_parity`], repair losses with
/// [`aisd_fec_recover`], destroy with [`aisd_fec_codec_free`]. Holds `k` (data shards per group)
/// and `m` (parity shards per group); a group recovers up to `m` losses. Not thread-safe in the
/// sense of shared mutation, but the codec is immutable after construction, so it may be shared
/// read-only across the encode/decode call sites.
pub struct AisdFecCodec {
    inner: ReedSolomonFec<NeonGf>,
    /// Parity shards per group (`m`) — cached so recover can size the per-group parity window.
    parity_count: usize,
}

/// Builds a NEON-backed Reed-Solomon codec with `k` data + `m` parity shards per group.
///
/// Returns null (NOT a panic/abort across the boundary) for an invalid configuration: `k < 1`,
/// `m < 1`, or `k + m > 255` (the Cauchy index sets must fit GF(2^8)). Destroy a non-null result
/// with [`aisd_fec_codec_free`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_fec_codec_new(k: usize, m: usize) -> *mut AisdFecCodec {
    // Validate here so the core's construction-time asserts are never tripped across FFI.
    if k < 1 || m < 1 || k.saturating_add(m) > 255 {
        return core::ptr::null_mut();
    }
    into_handle(AisdFecCodec {
        inner: ReedSolomonFec::with_backend(k, m, NeonGf),
        parity_count: m,
    })
}

/// Destroys a codec created by [`aisd_fec_codec_new`]. No-op on null.
///
/// # Safety
/// `codec` must be a pointer from [`aisd_fec_codec_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_fec_codec_free(codec: *mut AisdFecCodec) {
    // SAFETY: per the contract, `codec` is an unfreed handle from `aisd_fec_codec_new`.
    unsafe { free_handle(codec) }
}

/// Borrows a caller-supplied `AisdBytes` array as a slice of `&[u8]`, copying nothing.
///
/// # Safety
/// If `count != 0` and `data` is non-null, `data` must point to `count` readable [`AisdBytes`],
/// each whose non-empty `(ptr, len)` covers `len` readable bytes for the duration of the call.
unsafe fn borrow_shards<'a>(data: *const AisdBytes, count: usize) -> Vec<&'a [u8]> {
    if count == 0 || data.is_null() {
        return Vec::new();
    }
    // SAFETY: per the contract, `data` covers `count` readable `AisdBytes`.
    let items = unsafe { core::slice::from_raw_parts(data, count) };
    items
        .iter()
        .map(|b| {
            // SAFETY: per the contract, each non-empty `(ptr, len)` covers `len` readable bytes;
            // `slice_in` yields an empty slice for `len == 0` (even on a null ptr).
            unsafe { slice_in(b.ptr, b.len) }
        })
        .collect()
}

/// Computes the parity shards for `data`, grouping by `group_size`.
///
/// On [`AISD_OK`], `*out_parity` receives an owned [`AisdBytesArray`] of
/// `ceil(data_count / group_size) * m` shards in group-major-then-rank order (release with
/// [`crate::aisd_bytes_array_free`]). Each `data[i]` is borrowed (its bytes are read, never freed).
/// Returns [`AISD_ERR_NULL`] for a null `codec` / `out_parity` (or a null `data` with a nonzero
/// `data_count`); [`AISD_ERR_INVALID_ARGUMENT`] for `group_size == 0`. An empty `data` yields the
/// empty array. Never panics.
///
/// # Safety
/// `out_parity` must be writable; if `data_count != 0`, `data` must point to `data_count` readable
/// [`AisdBytes`], each with a valid `(ptr, len)`. On a non-[`AISD_OK`] return `*out_parity` is left
/// untouched; on [`AISD_OK`] it is overwritten as raw output WITHOUT freeing prior contents.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_fec_parity(
    codec: *const AisdFecCodec,
    data: *const AisdBytes,
    data_count: usize,
    group_size: usize,
    out_parity: *mut AisdBytesArray,
) -> AisdStatus {
    if codec.is_null() || out_parity.is_null() || (data.is_null() && data_count != 0) {
        return AISD_ERR_NULL;
    }
    if group_size == 0 {
        return AISD_ERR_INVALID_ARGUMENT;
    }
    // SAFETY: `codec` is non-null per the check above and a live handle per the contract.
    let codec = unsafe { &*codec };
    // SAFETY: per the contract, `data` covers `data_count` readable `AisdBytes`, each valid.
    let shards = unsafe { borrow_shards(data, data_count) };
    let parities = codec.inner.parity(&shards, group_size);
    let items: Vec<AisdBytes> = parities.into_iter().map(bytes_from_vec).collect();
    let (ptr, count) = bytes_vec_into_raw(items);
    // SAFETY: `out_parity` is non-null per the check above and writable per the contract.
    unsafe { out_parity.write(AisdBytesArray { items: ptr, count }) };
    AISD_OK
}

/// Builds the `Vec<Option<Vec<u8>>>` the core recover wants from a borrowed shard array + present
/// mask: a present shard contributes `Some(copied bytes)`; a hole (`present[i] == 0`) is `None`.
///
/// # Safety
/// `data` must cover `count` readable [`AisdBytes`] (each valid) and `present` `count` readable
/// bytes, both when `count != 0`.
unsafe fn shards_with_mask(
    data: *const AisdBytes,
    present: *const u8,
    count: usize,
) -> Vec<Option<Vec<u8>>> {
    if count == 0 {
        return Vec::new();
    }
    // SAFETY: per the contract, both arrays cover `count` readable elements.
    let (items, mask) = unsafe {
        (
            core::slice::from_raw_parts(data, count),
            core::slice::from_raw_parts(present, count),
        )
    };
    items
        .iter()
        .zip(mask.iter())
        .map(|(b, &p)| {
            if p == 0 {
                None
            } else {
                // SAFETY: a present shard's non-empty `(ptr, len)` covers `len` readable bytes.
                Some(unsafe { copy_in(*b) })
            }
        })
        .collect()
}

/// Recovers recoverable data holes in place, using the parity shards.
///
/// `data` is the caller's array of `data_count` shards; `data_present[i]` is `1` if `data[i]`
/// holds valid bytes and `0` if it is a hole to repair (this is how a hole is told apart from a
/// legitimately-empty shard). `parity` / `parity_present` describe the `parity_count` parity shards
/// the same way. Grouping is by `group_size`.
///
/// For every hole this call can repair, it writes a fresh Rust-owned [`AisdBytes`] into `data[i]`
/// and sets `out_recovered[i] = 1`; unrecoverable holes are left as the caller passed them
/// (`out_recovered[i]` set to `0`). The caller frees each recovered `data[i]` with
/// [`crate::aisd_bytes_free`]. `out_recovered` is fully written (length `data_count`).
///
/// Returns [`AISD_ERR_NULL`] for a null `codec` / `data` / `data_present` / `out_recovered`
/// (with a nonzero `data_count`), or a null `parity` / `parity_present` with a nonzero
/// `parity_count`. NEVER panics on hostile input (wrong counts, all holes, more than `m` holes,
/// corrupt shards) — it validates and degrades, leaving unrepairable holes untouched.
///
/// # Safety
/// When `data_count != 0`: `data` must point to `data_count` writable [`AisdBytes`], and
/// `data_present` / `out_recovered` to `data_count` readable / writable bytes. When
/// `parity_count != 0`: `parity` must point to `parity_count` readable [`AisdBytes`] and
/// `parity_present` to `parity_count` readable bytes. Each present shard's `(ptr, len)` must cover
/// `len` readable bytes.
#[must_use]
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)] // the recover surface is inherently wide (data + parity + masks).
pub unsafe extern "C" fn aisd_fec_recover(
    codec: *const AisdFecCodec,
    data: *mut AisdBytes,
    data_present: *const u8,
    data_count: usize,
    parity: *const AisdBytes,
    parity_present: *const u8,
    parity_count: usize,
    group_size: usize,
    out_recovered: *mut u8,
) -> AisdStatus {
    if codec.is_null()
        || (data_count != 0
            && (data.is_null() || data_present.is_null() || out_recovered.is_null()))
        || (parity_count != 0 && (parity.is_null() || parity_present.is_null()))
    {
        return AISD_ERR_NULL;
    }
    if group_size == 0 {
        return AISD_ERR_INVALID_ARGUMENT;
    }
    // SAFETY: `codec` is non-null per the check above and a live handle per the contract.
    let codec = unsafe { &*codec };

    // Snapshot the present mask so we can detect, post-recover, which holes were filled. (A slot is
    // a hole iff its mask byte was 0; a filled hole becomes `Some` after `recover` runs.)
    // SAFETY: per the contract, `data` / `data_present` cover `data_count` readable elements.
    let mut shards = unsafe { shards_with_mask(data, data_present, data_count) };
    // SAFETY: per the contract, `parity` / `parity_present` cover `parity_count` readable elements.
    let parity_opt = unsafe { shards_with_mask(parity, parity_present, parity_count) };

    // The core recover indexes `parity[group * m .. + m]`. If the caller passed fewer parity shards
    // than the layout implies, the missing slots simply read as absent (the `Option` is `None` for
    // out-of-range indices via `.get`), so a short parity array degrades to "leave the hole".
    let _ = codec.parity_count; // documents that `m` is fixed by the codec, not the call.
    codec.inner.recover(&mut shards, &parity_opt, group_size);

    // Write back any filled holes (slot was a hole AND is now `Some`) as fresh owned buffers, and
    // populate `out_recovered`. Slots that stayed holes get `out_recovered = 0` and are untouched.
    if data_count != 0 {
        // SAFETY: per the contract, `out_recovered` covers `data_count` writable bytes and `data`
        // `data_count` writable `AisdBytes`; `data_present` `data_count` readable bytes.
        let (mask, out_flags, data_slice) = unsafe {
            (
                core::slice::from_raw_parts(data_present, data_count),
                core::slice::from_raw_parts_mut(out_recovered, data_count),
                core::slice::from_raw_parts_mut(data, data_count),
            )
        };
        for i in 0..data_count {
            // Only a slot that WAS a hole and is NOW filled is a recovery we own + report.
            if mask[i] == 0 {
                if let Some(bytes) = shards[i].take() {
                    data_slice[i] = bytes_from_vec(bytes);
                    out_flags[i] = 1;
                } else {
                    out_flags[i] = 0;
                }
            } else {
                out_flags[i] = 0; // a present shard is never "recovered" by this call.
            }
        }
    }
    AISD_OK
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` / `&x` -> `*mut` / `*const` coercions.
    #![allow(clippy::borrow_as_ptr)]
    use super::*;

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

    /// Borrows a slice as an input `AisdBytes` (read-only; never freed by the call).
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
    fn codec_new_rejects_invalid_config() {
        // k<1, m<1, k+m>255 all return null (no panic across FFI).
        assert!(aisd_fec_codec_new(0, 2).is_null());
        assert!(aisd_fec_codec_new(4, 0).is_null());
        assert!(aisd_fec_codec_new(200, 56).is_null()); // 256 > 255
        let ok = aisd_fec_codec_new(4, 2);
        assert!(!ok.is_null());
        unsafe { aisd_fec_codec_free(ok) };
        unsafe { aisd_fec_codec_free(core::ptr::null_mut()) }; // no-op
    }

    #[test]
    fn parity_count_and_layout() {
        unsafe {
            let codec = aisd_fec_codec_new(4, 2);
            // 10 shards, group_size 4 => ceil(10/4)=3 groups * 2 = 6 parity shards.
            let owned: Vec<Vec<u8>> = (0..10u8).map(|i| vec![i; 5]).collect();
            let shards: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut out = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_fec_parity(codec, shards.as_ptr(), shards.len(), 4, &mut out),
                AISD_OK
            );
            assert_eq!(out.count, 6);
            crate::aisd_bytes_array_free(&mut out);
            crate::aisd_bytes_array_free(&mut out); // idempotent
            assert!(out.items.is_null() && out.count == 0);
            aisd_fec_codec_free(codec);
        }
    }

    #[test]
    fn multi_loss_recover_round_trip() {
        unsafe {
            // k=4 m=2: lose two data shards in the single group, recover both byte-exact.
            let codec = aisd_fec_codec_new(4, 2);
            let owned: Vec<Vec<u8>> = (0..4u8)
                .map(|i| vec![i, i ^ 0x5A, i.wrapping_mul(3)])
                .collect();
            let shards: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut par = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_fec_parity(codec, shards.as_ptr(), shards.len(), 4, &mut par),
                AISD_OK
            );
            assert_eq!(par.count, 2);

            // Build the recover input: erase shards 1 and 3 (present=0; their bytes are a hole).
            let mut data: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut present = [1u8; 4];
            present[1] = 0;
            present[3] = 0;
            data[1] = AisdBytes::EMPTY; // a hole carries no bytes
            data[3] = AisdBytes::EMPTY;
            let parity_present = vec![1u8; par.count];
            let mut recovered = [0u8; 4];

            assert_eq!(
                aisd_fec_recover(
                    codec,
                    data.as_mut_ptr(),
                    present.as_ptr(),
                    4,
                    par.items,
                    parity_present.as_ptr(),
                    par.count,
                    4,
                    recovered.as_mut_ptr(),
                ),
                AISD_OK
            );
            assert_eq!(recovered, [0, 1, 0, 1], "only the two holes were filled");
            assert_eq!(view(data[1]), owned[1], "shard 1 recovered byte-exact");
            assert_eq!(view(data[3]), owned[3], "shard 3 recovered byte-exact");
            // Free the two recovered shards (Rust-owned), then the parity array.
            crate::aisd_bytes_free(data[1]);
            crate::aisd_bytes_free(data[3]);
            crate::aisd_bytes_array_free(&mut par);
            aisd_fec_codec_free(codec);
        }
    }

    #[test]
    fn unrecoverable_more_holes_than_parity_leaves_holes() {
        unsafe {
            // k=6 m=2 but 3 holes in one group => unrecoverable; no panic, holes stay holes.
            let codec = aisd_fec_codec_new(6, 2);
            let owned: Vec<Vec<u8>> = (0..6u8).map(|i| vec![i; 4]).collect();
            let shards: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut par = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_fec_parity(codec, shards.as_ptr(), shards.len(), 6, &mut par),
                AISD_OK
            );

            let mut data: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut present = [1u8; 6];
            for h in [0usize, 2, 5] {
                present[h] = 0;
                data[h] = AisdBytes::EMPTY;
            }
            let parity_present = vec![1u8; par.count];
            let mut recovered = [9u8; 6];
            assert_eq!(
                aisd_fec_recover(
                    codec,
                    data.as_mut_ptr(),
                    present.as_ptr(),
                    6,
                    par.items,
                    parity_present.as_ptr(),
                    par.count,
                    6,
                    recovered.as_mut_ptr(),
                ),
                AISD_OK
            );
            assert_eq!(recovered, [0; 6], "no hole was recovered (3 > m=2)");
            // The holes are still empty (no Rust buffer written) — nothing to free for them.
            assert!(data[0].ptr.is_null() && data[2].ptr.is_null() && data[5].ptr.is_null());
            crate::aisd_bytes_array_free(&mut par);
            aisd_fec_codec_free(codec);
        }
    }

    #[test]
    fn null_guards_and_empty_inputs() {
        unsafe {
            let codec = aisd_fec_codec_new(4, 2);
            let mut out = AisdBytesArray::EMPTY;
            // Null codec / out / data(with count).
            assert_eq!(
                aisd_fec_parity(core::ptr::null(), core::ptr::null(), 0, 4, &mut out),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_fec_parity(codec, core::ptr::null(), 0, 4, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_fec_parity(codec, core::ptr::null(), 3, 4, &mut out),
                AISD_ERR_NULL,
                "null data with nonzero count"
            );
            // group_size 0 is rejected.
            assert_eq!(
                aisd_fec_parity(codec, core::ptr::null(), 0, 0, &mut out),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Empty data => empty array, OK.
            assert_eq!(
                aisd_fec_parity(codec, core::ptr::null(), 0, 4, &mut out),
                AISD_OK
            );
            assert_eq!(out.count, 0);
            assert!(out.items.is_null());
            crate::aisd_bytes_array_free(&mut out); // no-op on empty

            // recover null guards.
            let mut recovered = [0u8; 1];
            let mut d = [AisdBytes::EMPTY];
            let present = [0u8; 1];
            assert_eq!(
                aisd_fec_recover(
                    core::ptr::null(),
                    d.as_mut_ptr(),
                    present.as_ptr(),
                    1,
                    core::ptr::null(),
                    core::ptr::null(),
                    0,
                    4,
                    recovered.as_mut_ptr(),
                ),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_fec_recover(
                    codec,
                    core::ptr::null_mut(),
                    present.as_ptr(),
                    1, // null data with count
                    core::ptr::null(),
                    core::ptr::null(),
                    0,
                    4,
                    recovered.as_mut_ptr(),
                ),
                AISD_ERR_NULL
            );
            // group_size 0 on recover.
            assert_eq!(
                aisd_fec_recover(
                    codec,
                    core::ptr::null_mut(),
                    core::ptr::null(),
                    0,
                    core::ptr::null(),
                    core::ptr::null(),
                    0,
                    0,
                    core::ptr::null_mut(),
                ),
                AISD_ERR_INVALID_ARGUMENT
            );
            aisd_fec_codec_free(codec);
        }
    }

    #[test]
    fn empty_present_shard_is_not_a_hole() {
        unsafe {
            // A present-but-empty data shard (len 0, present=1) must round-trip, NOT be treated as a
            // hole. Lose a different shard and recover it; the empty shard stays empty.
            let codec = aisd_fec_codec_new(3, 2);
            let owned: Vec<Vec<u8>> = vec![Vec::new(), vec![0xAA; 3], vec![0xBB; 2]];
            let shards: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut par = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_fec_parity(codec, shards.as_ptr(), shards.len(), 3, &mut par),
                AISD_OK
            );

            let mut data: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let present = [1u8, 0, 1]; // shard 0 present (empty), shard 1 is the hole
            data[1] = AisdBytes::EMPTY;
            let parity_present = vec![1u8; par.count];
            let mut recovered = [0u8; 3];
            assert_eq!(
                aisd_fec_recover(
                    codec,
                    data.as_mut_ptr(),
                    present.as_ptr(),
                    3,
                    par.items,
                    parity_present.as_ptr(),
                    par.count,
                    3,
                    recovered.as_mut_ptr(),
                ),
                AISD_OK
            );
            assert_eq!(recovered, [0, 1, 0]);
            assert_eq!(view(data[1]), owned[1], "the real hole recovered");
            assert!(
                data[0].ptr.is_null(),
                "the empty present shard stayed empty/untouched"
            );
            crate::aisd_bytes_free(data[1]);
            crate::aisd_bytes_array_free(&mut par);
            aisd_fec_codec_free(codec);
        }
    }

    #[test]
    fn m1_parity_round_trips_through_neon_backend() {
        unsafe {
            // m=1 single-parity (the XOR-identity path, now routed through NeonGf). Lose one shard
            // per group, recover both groups.
            let codec = aisd_fec_codec_new(2, 1);
            let owned: Vec<Vec<u8>> = vec![vec![10, 20], vec![30], vec![40, 50, 60], vec![70]];
            let shards: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let mut par = AisdBytesArray::EMPTY;
            assert_eq!(
                aisd_fec_parity(codec, shards.as_ptr(), shards.len(), 2, &mut par),
                AISD_OK
            );
            assert_eq!(par.count, 2, "ceil(4/2) groups * m=1");

            let mut data: Vec<AisdBytes> = owned.iter().map(|v| borrow(v)).collect();
            let present = [1u8, 0, 0, 1]; // one hole in each of the two groups
            data[1] = AisdBytes::EMPTY;
            data[2] = AisdBytes::EMPTY;
            let parity_present = vec![1u8; par.count];
            let mut recovered = [0u8; 4];
            assert_eq!(
                aisd_fec_recover(
                    codec,
                    data.as_mut_ptr(),
                    present.as_ptr(),
                    4,
                    par.items,
                    parity_present.as_ptr(),
                    par.count,
                    2,
                    recovered.as_mut_ptr(),
                ),
                AISD_OK
            );
            assert_eq!(recovered, [0, 1, 1, 0]);
            assert_eq!(view(data[1]), owned[1]);
            assert_eq!(view(data[2]), owned[2]);
            crate::aisd_bytes_free(data[1]);
            crate::aisd_bytes_free(data[2]);
            crate::aisd_bytes_array_free(&mut par);
            aisd_fec_codec_free(codec);
        }
    }
}
