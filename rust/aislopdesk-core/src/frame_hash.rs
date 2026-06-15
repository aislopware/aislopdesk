//! A strong, SIMD-friendly 64-bit hash of an NV12 video frame, used by the host to detect a
//! pixel-identical re-delivery and skip re-encoding it (static-frame suppression).
//!
//! ## Why this exists
//!
//! `ScreenCaptureKit` occasionally re-delivers a `.complete` frame whose pixels are byte-identical
//! to the previous one (idle-skip + HEVC catch most static content, but not these). Encoding such
//! a frame wastes the encoder slot and the link. Hashing the captured planes and comparing to the
//! last submitted frame's hash lets the host drop the duplicate before it ever reaches the encoder.
//!
//! ## Stride safety (resolution stability)
//!
//! A `CVPixelBuffer` plane's `bytes_per_row` (stride) can exceed its visible `width` (row padding
//! for alignment). The hash reads ONLY the first `width` bytes of each `stride`-spaced row, so two
//! captures of the same image hash identically regardless of how the allocator padded the rows —
//! and a one-pixel change anywhere inside the visible area always changes the hash.
//!
//! ## Strength
//!
//! A collision wrongly suppresses a genuinely-new frame, freezing the client on stale content
//! until the next forced keyframe — so the hash must be strong (collision probability ≈ 2⁻⁶⁴ for
//! unrelated inputs, and *every* single-byte flip must change it). The construction below is an
//! xxHash64-style multiply/rotate fold over four parallel 64-bit lanes, finished with an avalanche
//! mix. It is deliberately expressible with the 16-bytes-per-iteration NEON lane ops so the FFI
//! crate can provide a byte-identical vector kernel (`aislopdesk_ffi::frame_hash`), proven equal by
//! a differential test.
//!
//! Forbid-unsafe, zero-dependency: the scalar reference here is the single source of truth; the
//! NEON kernel must match it bit-for-bit.

/// The first xxHash64 lane prime (a large odd constant).
///
/// The five primes are distinct so each lane mixes differently and the per-lane streams do not
/// collapse into one another. `PRIME64_1`/`PRIME64_2` are `pub` so the FFI crate's NEON kernel folds
/// with the identical multipliers; the rest stay crate-private.
pub const PRIME64_1: u64 = 0x9E37_79B1_85EB_CA87;
/// See [`PRIME64_1`].
pub const PRIME64_2: u64 = 0xC2B2_AE3D_27D4_EB4F;
const PRIME64_3: u64 = 0x1656_67B1_9E37_79F9;
const PRIME64_4: u64 = 0x85EB_CA77_C2B2_AE63;
const PRIME64_5: u64 = 0x2752_5BA1_84B2_3A5D;

/// Seeds the four accumulator lanes from a base seed, exactly as xxHash64 does.
///
/// The lane offsets `+P1+P2`, `+P2`, `0`, `-P1` give four distinct starting states. Shared by the
/// scalar reference and the NEON kernel so both begin identically.
#[inline]
#[must_use]
pub const fn seed_lanes(seed: u64) -> [u64; 4] {
    [
        seed.wrapping_add(PRIME64_1).wrapping_add(PRIME64_2),
        seed.wrapping_add(PRIME64_2),
        seed,
        seed.wrapping_sub(PRIME64_1),
    ]
}

/// One xxHash64 round: `acc = rotl(acc + lane * P2, 31) * P1`.
///
/// The single per-lane fold step, applied identically by both backends so they stay byte-for-byte
/// equal.
#[inline]
#[must_use]
pub const fn round(acc: u64, lane: u64) -> u64 {
    acc.wrapping_add(lane.wrapping_mul(PRIME64_2))
        .rotate_left(31)
        .wrapping_mul(PRIME64_1)
}

/// Merges one finished lane accumulator into the running 64-bit hash (xxHash64's `mergeRound`).
#[inline]
#[must_use]
const fn merge_round(hash: u64, acc: u64) -> u64 {
    let hash = hash ^ round(0, acc);
    hash.wrapping_mul(PRIME64_1).wrapping_add(PRIME64_4)
}

/// Combines the four lane accumulators into a single 64-bit value (xxHash64's long-input fold).
///
/// `rotl(a1,1)+rotl(a2,7)+rotl(a3,12)+rotl(a4,18)`, then four merges. Exposed so the NEON kernel
/// folds its four lanes through the identical sequence.
#[inline]
#[must_use]
pub const fn merge_lanes(lanes: [u64; 4]) -> u64 {
    let [a1, a2, a3, a4] = lanes;
    let mut hash = a1
        .rotate_left(1)
        .wrapping_add(a2.rotate_left(7))
        .wrapping_add(a3.rotate_left(12))
        .wrapping_add(a4.rotate_left(18));
    hash = merge_round(hash, a1);
    hash = merge_round(hash, a2);
    hash = merge_round(hash, a3);
    hash = merge_round(hash, a4);
    hash
}

/// xxHash64's final avalanche: scrambles every bit of the folded value.
///
/// Any single input-byte change cascades across the full 64 bits, so the output looks random.
/// Exposed for the NEON finish.
#[inline]
#[must_use]
pub const fn avalanche(mut h: u64) -> u64 {
    h ^= h >> 33;
    h = h.wrapping_mul(PRIME64_2);
    h ^= h >> 29;
    h = h.wrapping_mul(PRIME64_3);
    h ^= h >> 32;
    h
}

/// Reads 8 little-endian bytes of `buf` starting at `off` as a `u64`, panic-free.
///
/// Bytes that fall past the end of `buf` read as 0. Callers only invoke it with `off + 8 <=
/// buf.len()` (so no padding ever occurs on a live path), but the zero-fill keeps it total — no
/// `expect`, no `# Panics`.
#[inline]
fn le_u64(buf: &[u8], off: usize) -> u64 {
    let mut bytes = [0u8; 8];
    let end = (off + 8).min(buf.len());
    if off < end {
        bytes[..end - off].copy_from_slice(&buf[off..end]);
    }
    u64::from_le_bytes(bytes)
}

/// Reads 4 little-endian bytes of `buf` starting at `off` as a `u32`, panic-free (over-read ⇒ 0).
#[inline]
fn le_u32(buf: &[u8], off: usize) -> u32 {
    let mut bytes = [0u8; 4];
    let end = (off + 4).min(buf.len());
    if off < end {
        bytes[..end - off].copy_from_slice(&buf[off..end]);
    }
    u32::from_le_bytes(bytes)
}

/// Folds a sub-32-byte tail (plus the total length) into the hash, reproducing xxHash64's tail loop.
///
/// 8-byte groups, then a 4-byte group, then single bytes. The scalar plane hasher and the NEON
/// kernel both delegate their tails here, so the tail is handled in ONE place and trivially matches.
/// Panic-free: the group reads go through [`le_u64`] / [`le_u32`].
#[inline]
#[must_use]
pub fn finalize_tail(mut hash: u64, tail: &[u8], total_len: u64) -> u64 {
    hash = hash.wrapping_add(total_len);
    let mut off = 0usize;
    // 8-byte groups.
    while tail.len() - off >= 8 {
        let k = round(0, le_u64(tail, off));
        hash ^= k;
        hash = hash
            .rotate_left(27)
            .wrapping_mul(PRIME64_1)
            .wrapping_add(PRIME64_4);
        off += 8;
    }
    // One 4-byte group.
    if tail.len() - off >= 4 {
        let k = u64::from(le_u32(tail, off));
        hash ^= k.wrapping_mul(PRIME64_1);
        hash = hash
            .rotate_left(23)
            .wrapping_mul(PRIME64_2)
            .wrapping_add(PRIME64_3);
        off += 4;
    }
    // Remaining single bytes.
    for &b in &tail[off..] {
        hash ^= u64::from(b).wrapping_mul(PRIME64_5);
        hash = hash.rotate_left(11).wrapping_mul(PRIME64_1);
    }
    avalanche(hash)
}

/// A streaming xxHash64 over a byte stream presented in pieces.
///
/// Folds each plane's visible (un-padded) rows into one hash without ever materialising a
/// contiguous copy. The host feeds it `width` bytes per `stride`-spaced row; the accumulator carries
/// the partial
/// 32-byte block across rows so the result is identical to hashing the concatenation of all the
/// visible rows. The 32-byte main loop is the part the NEON kernel accelerates.
#[derive(Debug, Clone)]
pub struct StreamHasher {
    /// The four 64-bit lane accumulators (xxHash64 state) once ≥32 bytes have been seen.
    lanes: [u64; 4],
    /// The seed (used directly as the hash base for a <32-byte total — xxHash64's short path).
    seed: u64,
    /// Total bytes consumed so far (folded into the finish, and selects the short vs long path).
    total: u64,
    /// Bytes buffered toward the next full 32-byte block (0..32).
    buf: [u8; 32],
    buf_len: usize,
    /// Whether the 32-byte main loop has ever run (⇒ use `lanes`, not the seed short path).
    started: bool,
}

impl StreamHasher {
    /// A fresh hasher seeded with `seed` (the host passes a fixed seed so a given plane image always
    /// hashes to the same value).
    #[inline]
    #[must_use]
    pub const fn new(seed: u64) -> Self {
        Self {
            lanes: seed_lanes(seed),
            seed,
            total: 0,
            buf: [0; 32],
            buf_len: 0,
            started: false,
        }
    }

    /// Folds one full 32-byte block (four little-endian u64 lanes) into the accumulators.
    ///
    /// The hot inner step the NEON kernel mirrors with `ld1`/`mul`/`add`/lane-rotate ops. The lane
    /// reads use [`le_u64`] (a panic-free fixed-offset decode), so this never panics.
    #[inline]
    fn consume_block(&mut self, block: &[u8; 32]) {
        for (i, lane) in self.lanes.iter_mut().enumerate() {
            *lane = round(*lane, le_u64(block, i * 8));
        }
        self.started = true;
    }

    /// Appends `data` to the stream. Buffers across calls so row-by-row feeding is exact.
    pub fn update(&mut self, data: &[u8]) {
        self.total = self.total.wrapping_add(data.len() as u64);
        let mut input = data;

        // Top off a partially-filled buffer first.
        if self.buf_len > 0 {
            let need = 32 - self.buf_len;
            let take = need.min(input.len());
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&input[..take]);
            self.buf_len += take;
            input = &input[take..];
            if self.buf_len == 32 {
                let block = self.buf;
                self.consume_block(&block);
                self.buf_len = 0;
            } else {
                return; // still didn't fill a block
            }
        }

        // Consume full 32-byte blocks straight out of `input`; `chunks_exact` yields exact-length
        // slices (no panicking `try_into`) and hands back the sub-block tail via `remainder()`.
        let mut blocks = input.chunks_exact(32);
        for block in blocks.by_ref() {
            let mut buf = [0u8; 32];
            buf.copy_from_slice(block);
            self.consume_block(&buf);
        }

        // Stash the remainder for next time.
        let rest = blocks.remainder();
        if !rest.is_empty() {
            self.buf[..rest.len()].copy_from_slice(rest);
            self.buf_len = rest.len();
        }
    }

    /// Whether bytes are buffered toward an incomplete 32-byte block (so an external 32-byte-block
    /// fold — e.g. the NEON kernel — must first top the buffer off to a boundary). Used by the FFI
    /// NEON backend to share this hasher's exact buffering.
    #[inline]
    #[must_use]
    pub const fn is_buffering(&self) -> bool {
        self.buf_len > 0
    }

    /// Tops the internal partial block off with the start of `data`, consuming and folding a full
    /// block if one completes. Returns how many bytes of `data` were consumed (and counts them
    /// toward the total). Lets an external block-oriented backend reuse the core's cross-row
    /// buffering verbatim before taking over the aligned bulk run.
    pub fn fill_to_block_boundary(&mut self, data: &[u8]) -> usize {
        if self.buf_len == 0 {
            return 0;
        }
        let need = 32 - self.buf_len;
        let take = need.min(data.len());
        self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&data[..take]);
        self.buf_len += take;
        self.total = self.total.wrapping_add(take as u64);
        if self.buf_len == 32 {
            let block = self.buf;
            self.consume_block(&block);
            self.buf_len = 0;
        }
        take
    }

    /// Borrows out the four lane accumulators so an external backend can fold aligned 32-byte blocks
    /// into them and hand them back with [`StreamHasher::put_lanes`]. Only valid when not mid-buffer
    /// (the caller aligns first via [`StreamHasher::fill_to_block_boundary`]).
    #[inline]
    #[must_use]
    pub const fn take_lanes(&self) -> [u64; 4] {
        self.lanes
    }

    /// Writes back lane accumulators produced by an external aligned-block fold of `len` bytes,
    /// marking the main loop as started (so [`StreamHasher::finish`] merges the lanes rather than
    /// the short path) and counting those `len` bytes toward the total (the external fold does not
    /// touch the running length, which the finish folds in).
    #[inline]
    pub const fn put_lanes(&mut self, lanes: [u64; 4], len: usize) {
        self.lanes = lanes;
        self.started = true;
        self.total = self.total.wrapping_add(len as u64);
    }

    /// Consumes the hasher and returns the final 64-bit hash.
    #[inline]
    #[must_use]
    pub fn finish(self) -> u64 {
        let hash = if self.started {
            merge_lanes(self.lanes)
        } else {
            // Short input (< 32 bytes total): xxHash64 starts from `seed + PRIME5`.
            self.seed.wrapping_add(PRIME64_5)
        };
        finalize_tail(hash, &self.buf[..self.buf_len], self.total)
    }
}

/// The fixed seed for the NV12 frame hash. A constant (not env-tunable) so the host and the NEON
/// kernel — and any future Android consumer — agree on the exact value for a given frame.
pub const FRAME_HASH_SEED: u64 = 0x4149_534C_4F50_4445; // "AISLOPDE"

/// Hashes an NV12 frame's two planes into one 64-bit value.
///
/// * `y` / `y_stride`: the luma plane and its byte stride (≥ `width`). Only the first `width` bytes
///   of each of the `height` rows are read.
/// * `cbcr` / `cbcr_stride`: the interleaved chroma plane (one Cb,Cr pair per 2×2 luma block ⇒
///   `height / 2` rows of `width` bytes each, since each chroma row holds `width / 2` interleaved
///   Cb,Cr pairs = `width` bytes). Pass an empty slice for a luma-only hash.
///
/// Reading only the visible `width` bytes per row makes the hash independent of row padding, so a
/// re-delivery of the identical image always produces the identical hash regardless of stride.
///
/// Degenerate inputs are safe: a zero `width` or `height`, or a stride/length too small to cover a
/// row, simply contribute nothing for that plane (no panic, no out-of-bounds read).
#[must_use]
pub fn hash_nv12(
    y: &[u8],
    y_stride: usize,
    width: usize,
    height: usize,
    cbcr: &[u8],
    cbcr_stride: usize,
) -> u64 {
    let mut hasher = StreamHasher::new(FRAME_HASH_SEED);
    hash_plane(&mut hasher, y, y_stride, width, height);
    // NV12 chroma: half the luma height, and each row carries `width / 2` interleaved Cb,Cr pairs
    // ⇒ `2 * (width / 2)` = `width` (even) bytes of visible chroma per row.
    let chroma_width = (width / 2) * 2;
    hash_plane(&mut hasher, cbcr, cbcr_stride, chroma_width, height / 2);
    hasher.finish()
}

/// Folds the visible (un-padded) `width × height` region of one `stride`-spaced plane into `hasher`.
///
/// Each row contributes exactly its first `width` bytes; any per-row padding (`stride - width`) and
/// any trailing bytes past the last visible row are never read. Rows whose bytes are not fully
/// present in `plane` (a too-short buffer) are skipped rather than read out of bounds.
fn hash_plane(hasher: &mut StreamHasher, plane: &[u8], stride: usize, width: usize, height: usize) {
    if width == 0 || height == 0 || stride < width {
        return;
    }
    for row in 0..height {
        let start = row * stride;
        let end = start + width;
        // Bounds-guard: a truncated plane stops contributing rather than reading past its end.
        if end > plane.len() {
            break;
        }
        hasher.update(&plane[start..end]);
    }
}

#[cfg(test)]
mod tests {
    // `w`/`h` (width/height) and `a`/`b` (two hashes to compare) are the clearest names in these
    // image-shaped tests; the pedantic single-char-names lint adds nothing here.
    #![allow(clippy::many_single_char_names)]
    use super::*;

    /// Deterministic, dependency-free PRNG so the tests are reproducible.
    struct SplitMix64(u64);
    impl SplitMix64 {
        const fn new(seed: u64) -> Self {
            Self(seed)
        }
        fn next_u64(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        fn fill(&mut self, buf: &mut [u8]) {
            for b in buf.iter_mut() {
                *b = (self.next_u64() & 0xff) as u8;
            }
        }
    }

    /// Builds a `stride`-padded plane (`width × height` visible, `stride - width` padding/row) whose
    /// visible bytes are `fill` and whose padding bytes are a contrasting `pad` value.
    fn padded_plane(width: usize, height: usize, stride: usize, fill: &[u8], pad: u8) -> Vec<u8> {
        assert!(stride >= width);
        assert_eq!(fill.len(), width * height);
        let mut plane = vec![pad; stride * height];
        for row in 0..height {
            plane[row * stride..row * stride + width]
                .copy_from_slice(&fill[row * width..row * width + width]);
        }
        plane
    }

    #[test]
    fn identical_planes_hash_identically() {
        let mut rng = SplitMix64::new(1);
        let (w, h) = (320usize, 180usize);
        let mut y = vec![0u8; w * h];
        let mut cbcr = vec![0u8; w * (h / 2)];
        rng.fill(&mut y);
        rng.fill(&mut cbcr);
        let a = hash_nv12(&y, w, w, h, &cbcr, w);
        let b = hash_nv12(&y, w, w, h, &cbcr, w);
        assert_eq!(a, b, "the same image must hash identically");
    }

    #[test]
    fn one_byte_flip_anywhere_changes_the_hash() {
        let mut rng = SplitMix64::new(2);
        let (w, h) = (64usize, 48usize);
        let mut y = vec![0u8; w * h];
        let cbcr = vec![0u8; w * (h / 2)];
        rng.fill(&mut y);
        let base = hash_nv12(&y, w, w, h, &cbcr, w);
        // Flip every byte of the luma plane in turn — each must perturb the hash.
        for i in 0..y.len() {
            let mut flipped = y.clone();
            flipped[i] ^= 0x01;
            assert_ne!(
                hash_nv12(&flipped, w, w, h, &cbcr, w),
                base,
                "flipping luma byte {i} did not change the hash"
            );
        }
        // And a chroma-plane flip must matter too (flip in place — `base` is already captured).
        let mut cbcr = cbcr;
        cbcr[10] ^= 0x80;
        assert_ne!(
            hash_nv12(&y, w, w, h, &cbcr, w),
            base,
            "a chroma change must change the hash"
        );
    }

    #[test]
    fn stride_padding_does_not_affect_the_hash() {
        let mut rng = SplitMix64::new(3);
        let (w, h) = (100usize, 70usize);
        let mut y = vec![0u8; w * h];
        let mut cbcr = vec![0u8; w * (h / 2)];
        rng.fill(&mut y);
        rng.fill(&mut cbcr);
        // Tight stride == width.
        let tight = hash_nv12(&y, w, w, h, &cbcr, w);
        // Padded strides with DIFFERENT padding bytes must hash to the SAME value.
        let y_pad = padded_plane(w, h, w + 37, &y, 0xAB);
        let cbcr_pad = padded_plane(w, h / 2, w + 37, &cbcr, 0xCD);
        let padded = hash_nv12(&y_pad, w + 37, w, h, &cbcr_pad, w + 37);
        assert_eq!(tight, padded, "row padding must not influence the hash");
        // A different padding byte still hashes the same (padding truly ignored).
        let y_pad2 = padded_plane(w, h, w + 37, &y, 0x00);
        let cbcr_pad2 = padded_plane(w, h / 2, w + 37, &cbcr, 0xFF);
        let padded2 = hash_nv12(&y_pad2, w + 37, w, h, &cbcr_pad2, w + 37);
        assert_eq!(tight, padded2, "the padding VALUE must be irrelevant");
    }

    #[test]
    fn empty_and_degenerate_dimensions_are_safe() {
        // Zero dims / empty planes never panic and never read out of bounds.
        assert_eq!(
            hash_nv12(&[], 0, 0, 0, &[], 0),
            hash_nv12(&[], 0, 0, 0, &[], 0)
        );
        let _ = hash_nv12(&[1, 2, 3], 10, 5, 2, &[], 0); // stride > buffer ⇒ no rows fit, no panic
        let _ = hash_nv12(&[1, 2, 3], 1, 1, 100, &[], 0); // far more rows than bytes ⇒ truncated, no panic
        // Luma-only (empty chroma) is a valid call.
        let mut rng = SplitMix64::new(4);
        let mut y = vec![0u8; 16 * 16];
        rng.fill(&mut y);
        let luma_only = hash_nv12(&y, 16, 16, 16, &[], 0);
        assert_eq!(luma_only, hash_nv12(&y, 16, 16, 16, &[], 0));
    }

    #[test]
    fn odd_width_truncates_chroma_to_even() {
        // An odd width must not panic; chroma uses `(width/2)*2` bytes/row.
        let mut rng = SplitMix64::new(5);
        let (w, h) = (17usize, 10usize);
        let mut y = vec![0u8; w * h];
        let mut cbcr = vec![0u8; w * (h / 2)];
        rng.fill(&mut y);
        rng.fill(&mut cbcr);
        let a = hash_nv12(&y, w, w, h, &cbcr, w);
        let b = hash_nv12(&y, w, w, h, &cbcr, w);
        assert_eq!(a, b);
    }

    #[test]
    fn stream_hasher_is_split_invariant() {
        // Feeding the same bytes in different chunkings must yield the same hash (the row-by-row
        // feed relies on this).
        let mut rng = SplitMix64::new(6);
        let mut data = vec![0u8; 1000];
        rng.fill(&mut data);

        let mut whole = StreamHasher::new(FRAME_HASH_SEED);
        whole.update(&data);
        let whole = whole.finish();

        for chunk in [1usize, 7, 13, 31, 32, 33, 100] {
            let mut h = StreamHasher::new(FRAME_HASH_SEED);
            for piece in data.chunks(chunk) {
                h.update(piece);
            }
            assert_eq!(h.finish(), whole, "chunking by {chunk} diverged");
        }
    }

    #[test]
    fn distinct_visible_streams_do_not_alias() {
        // When the VISIBLE byte stream differs, the hash must differ. A wider stride than width
        // means the two interpretations below read DIFFERENT subsets of the buffer (one skips
        // padding columns the other reads), so they must not collide.
        let mut rng = SplitMix64::new(7);
        let mut y = vec![0u8; 32 * 20];
        rng.fill(&mut y);
        // stride 32, width 24 (8 padding cols/row skipped) vs width 30 (2 skipped) ⇒ different
        // visible bytes AND different total length.
        let a = hash_nv12(&y, 32, 24, 10, &[], 0);
        let b = hash_nv12(&y, 32, 30, 10, &[], 0);
        assert_ne!(a, b, "different visible streams should not collide");
    }

    #[test]
    fn same_visible_stream_hashes_equal_across_geometry() {
        // Conversely, two geometries that read the IDENTICAL contiguous visible bytes AND the same
        // total length hash the same — that is correct (the hash sees only the bytes + length, not
        // a row-shape it cannot observe). Documents the (rare, benign) reshape-aliasing boundary.
        let mut rng = SplitMix64::new(8);
        let mut y = vec![0u8; 240];
        rng.fill(&mut y);
        let a = hash_nv12(&y, 24, 24, 10, &[], 0);
        let b = hash_nv12(&y, 20, 20, 12, &[], 0);
        assert_eq!(a, b, "identical visible bytes + length ⇒ identical hash");
    }
}
