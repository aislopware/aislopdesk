//! A NEON-accelerated NV12 frame hash, byte-identical to the scalar reference in
//! [`aislopdesk_core::frame_hash`].
//!
//! [`aislopdesk_core`] keeps a portable, 100%-safe scalar hasher (the single source of truth and
//! the Android default). On Apple Silicon — our only shipping host — an ~8-megapixel luma plane is
//! hashed every frame on the `userInteractive` capture queue at up to 60 fps, so a scalar byte-at-a-
//! time fold is too slow. This crate (the one place `unsafe` is allowed) provides a vector kernel
//! that folds the xxHash64 32-byte main loop **four 64-bit lanes at a time** with NEON, producing
//! the *exact same* 64-bit hash as the scalar reference (a differential test pins them equal over
//! random planes, widths, heights, strides, and sub-16 row tails).
//!
//! ## Technique
//!
//! The scalar hasher's hot step is one xxHash64 round per 8-byte lane:
//! `acc = rotl(acc + k·P2, 31)·P1`, applied to the four lanes of each 32-byte block. NEON holds the
//! four lanes as two `uint64x2_t` registers and applies the round to both in parallel:
//!
//! * the `+ k·P2` and `·P1` 64-bit lane multiplies use [`neon::vmulq_u64`] — NEON has no 64-bit
//!   lane multiply instruction, so it is synthesised from the three 32-bit partial products
//!   (`vmull_u32` = `umull`, `vmlal_u32`, a `shl #32`, and `add.2d`), the textbook schoolbook trick;
//! * `rotl(·, 31)` is `(x << 31) | (x >> 33)` via `vshlq_n_u64` / `vshrq_n_u64` + `vorrq_u64`.
//!
//! The plane walk, the cross-row buffering, the `< 32`-byte tail, and the finish all stay in the
//! safe scalar [`aislopdesk_core::frame_hash::StreamHasher`]; only the full-32-byte-block fold is
//! vectorised, and it calls exactly the same `round` arithmetic, so the result is bit-identical.
//!
//! ## Safety
//!
//! All `unsafe` is confined to [`neon`], whose `// SAFETY` blocks document why the intrinsics are
//! sound: every `vld1q_u8` reads exactly the 16 in-bounds bytes of an owned `&[u8; 16]`, and every
//! other op is a pure register transform with no memory access. The tail and the entire
//! non-`aarch64` build go through the safe core.

use aislopdesk_core::frame_hash::{self, StreamHasher};

/// NEON NV12 frame hash. A unit struct so the boundary and the differential test can name a backend.
///
/// On any non-`aarch64` host it transparently forwards to the scalar core, so this crate still
/// builds and stays correct everywhere; only Apple Silicon takes the vector path.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NeonFrameHash;

impl NeonFrameHash {
    /// Hashes an NV12 frame's luma + interleaved-chroma planes into one 64-bit value.
    ///
    /// Byte-identical to [`frame_hash::hash_nv12`]; see that function for the plane / stride /
    /// degenerate-input contract — this only changes *how* the 32-byte blocks are folded, never the
    /// result.
    #[must_use]
    pub fn hash_nv12(
        y: &[u8],
        y_stride: usize,
        width: usize,
        height: usize,
        cbcr: &[u8],
        cbcr_stride: usize,
    ) -> u64 {
        let mut hasher = StreamHasher::new(frame_hash::FRAME_HASH_SEED);
        Self::hash_plane(&mut hasher, y, y_stride, width, height);
        let chroma_width = (width / 2) * 2;
        Self::hash_plane(&mut hasher, cbcr, cbcr_stride, chroma_width, height / 2);
        hasher.finish()
    }

    /// Folds the visible `width × height` region of one `stride`-spaced plane into `hasher`,
    /// vectorising the per-row main loop on `aarch64`. Identical row-selection and bounds-guarding
    /// to the scalar [`frame_hash`] plane walk (only the first `width` bytes of each row are read,
    /// padding is never touched, a truncated plane stops early).
    fn hash_plane(
        hasher: &mut StreamHasher,
        plane: &[u8],
        stride: usize,
        width: usize,
        height: usize,
    ) {
        if width == 0 || height == 0 || stride < width {
            return;
        }
        for row in 0..height {
            let start = row * stride;
            let end = start + width;
            if end > plane.len() {
                break;
            }
            update(hasher, &plane[start..end]);
        }
    }
}

/// Appends `data` to `hasher`, folding full 32-byte blocks with NEON.
///
/// The partial-block buffering and the sub-32-byte remainder go to the safe core, so the result
/// equals the scalar hasher byte-for-byte. On `aarch64` it tops off any in-flight partial block via
/// the core (which fires `round` on the
/// completed block), consumes the bulk 32-byte run with [`neon::fold_blocks`], then hands the
/// trailing `< 32` bytes back to the core. Because [`StreamHasher`] exposes its lane state through
/// [`StreamHasher::take_lanes`] / [`StreamHasher::put_lanes`], the NEON fold operates on the exact
/// same accumulators the core would, just 32 bytes per iteration in vector registers.
#[cfg(target_arch = "aarch64")]
fn update(hasher: &mut StreamHasher, data: &[u8]) {
    // If the core is mid-block (has buffered bytes), let it absorb up to a block boundary first —
    // this keeps the 32-byte alignment the NEON loop needs and reuses the core's exact buffering.
    let mut input = data;
    if hasher.is_buffering() {
        let consumed = hasher.fill_to_block_boundary(input);
        input = &input[consumed..];
        if hasher.is_buffering() {
            return; // still didn't complete a block; nothing aligned to vectorise yet
        }
    }

    // Bulk NEON fold of the aligned 32-byte blocks.
    let block_bytes = input.len() & !31;
    if block_bytes >= 32 {
        let mut lanes = hasher.take_lanes();
        // SAFETY: `block_bytes` is a multiple of 32 and `<= input.len()`, so `fold_blocks` reads
        // only in-bounds bytes of `input` (it slices each 16-byte half from a live `&[u8; 32]`).
        unsafe { neon::fold_blocks(&mut lanes, &input[..block_bytes]) };
        hasher.put_lanes(lanes, block_bytes);
        input = &input[block_bytes..];
    }

    // The sub-32-byte remainder (and the total-length bookkeeping) go back through the core.
    if !input.is_empty() {
        hasher.update(input);
    }
}

/// Off `aarch64`, the NEON path does not exist — forward straight to the scalar core.
#[cfg(not(target_arch = "aarch64"))]
#[inline]
fn update(hasher: &mut StreamHasher, data: &[u8]) {
    hasher.update(data);
}

/// The NEON intrinsic kernel — the crate's only `unsafe` for the frame-hash path.
#[cfg(target_arch = "aarch64")]
mod neon {
    use aislopdesk_core::frame_hash::{PRIME64_1, PRIME64_2};
    use core::arch::aarch64::{
        uint32x2_t, uint64x2_t, vaddq_u64, vdupq_n_u64, vld1q_u8, vld1q_u64, vmlal_u32, vmovn_u64,
        vmull_u32, vorrq_u64, vreinterpretq_u32_u64, vreinterpretq_u64_u8, vshlq_n_u64,
        vshrn_n_u64, vshrq_n_u64, vst1q_u64, vuzp1_u32, vuzp2_u32,
    };

    /// 64-bit lane multiply `a * b` for a pair of lanes.
    ///
    /// NEON has no 64×64 lane multiply, so it is synthesised from the three 32-bit partial products
    /// of `a = aₕ·2³² + aₗ`, `b = bₕ·2³² + bₗ`:
    ///
    /// ```text
    /// a·b = aₗ·bₗ + (aₗ·bₕ + aₕ·bₗ)·2³² + (aₕ·bₕ)·2⁶⁴   (mod 2⁶⁴)
    ///     = aₗ·bₗ + ((aₗ·bₕ + aₕ·bₗ) << 32)            // the 2⁶⁴ term vanishes mod 2⁶⁴
    /// ```
    ///
    /// `aₗ·bₗ` is a full `vmull_u32` (widening, the `umull` instruction); the cross term only needs
    /// its low 32 bits before the `<< 32` (its high bits would land past bit 63 and drop), so it is
    /// computed with two `vmull_u32`s narrowed (`vmovn`/`xtn`) and added in 32-bit lanes. This
    /// reproduces `u64::wrapping_mul` exactly.
    ///
    /// # Safety
    /// Pure register transform — no memory access; the intrinsics are the mandatory aarch64 baseline.
    #[inline]
    unsafe fn vmulq_u64(a: uint64x2_t, b: uint64x2_t) -> uint64x2_t {
        // SAFETY: every op below is register-only (no loads/stores); NEON is always available on
        // aarch64.
        unsafe {
            // Deinterleave each 128-bit register's four 32-bit words into the low/high halves of its
            // two 64-bit lanes: a32=[a0ₗ a0ₕ a1ₗ a1ₕ] ⇒ a_lo=[a0ₗ a1ₗ], a_hi=[a0ₕ a1ₕ].
            let a32 = vreinterpretq_u32_u64(a);
            let b32 = vreinterpretq_u32_u64(b);
            let a_lo: uint32x2_t = vuzp1_u32(low2(a32), high2(a32));
            let a_hi: uint32x2_t = vuzp2_u32(low2(a32), high2(a32));
            let b_lo: uint32x2_t = vuzp1_u32(low2(b32), high2(b32));
            let b_hi: uint32x2_t = vuzp2_u32(low2(b32), high2(b32));

            // lo·lo widened to two 64-bit lanes (the `umull` partial product).
            let lolo = vmull_u32(a_lo, b_lo);
            // cross = aₗ·bₕ + aₕ·bₗ, only the low 32 bits per lane matter (narrowed via `xtn`).
            let cross = {
                let alo_bhi = vmovn_u64(vmull_u32(a_lo, b_hi));
                let ahi_blo = vmovn_u64(vmull_u32(a_hi, b_lo));
                core::arch::aarch64::vadd_u32(alo_bhi, ahi_blo)
            };
            // lolo + (cross << 32): widen cross to 64-bit lanes, shift, add (high bits drop on wrap).
            let cross64 = vshlq_n_u64::<32>(core::arch::aarch64::vmovl_u32(cross));
            vaddq_u64(lolo, cross64)
        }
    }

    /// The low 64 bits of a 128-bit u32 vector as a 2-lane u32 ([w0 w1]).
    #[inline]
    unsafe fn low2(v: core::arch::aarch64::uint32x4_t) -> uint32x2_t {
        // SAFETY: register-only extract of the low half.
        unsafe { core::arch::aarch64::vget_low_u32(v) }
    }

    /// The high 64 bits of a 128-bit u32 vector as a 2-lane u32 ([w2 w3]).
    #[inline]
    unsafe fn high2(v: core::arch::aarch64::uint32x4_t) -> uint32x2_t {
        // SAFETY: register-only extract of the high half.
        unsafe { core::arch::aarch64::vget_high_u32(v) }
    }

    /// Rotate-left each 64-bit lane by 31: `(x << 31) | (x >> 33)`.
    #[inline]
    unsafe fn rotl31(x: uint64x2_t) -> uint64x2_t {
        // SAFETY: register-only shifts + or.
        unsafe { vorrq_u64(vshlq_n_u64::<31>(x), vshrq_n_u64::<33>(x)) }
    }

    /// One xxHash64 round on a pair of lanes: `acc = rotl(acc + k·P2, 31)·P1`.
    #[inline]
    unsafe fn round_pair(acc: uint64x2_t, k: uint64x2_t) -> uint64x2_t {
        // SAFETY: composed of the register-only ops above.
        unsafe {
            let p2 = vdupq_n_u64(PRIME64_2);
            let p1 = vdupq_n_u64(PRIME64_1);
            let added = vaddq_u64(acc, vmulq_u64(k, p2));
            vmulq_u64(rotl31(added), p1)
        }
    }

    /// Interpret 16 bytes as two little-endian u64 lanes [k0 k1].
    #[inline]
    unsafe fn le_u64x2(bytes: &[u8; 16]) -> uint64x2_t {
        // SAFETY: `vld1q_u8` reads exactly the 16 in-bounds bytes of the owned array; on aarch64
        // (little-endian) reinterpreting that byte vector as u64 lanes is the same decode as the
        // scalar `u64::from_le_bytes`.
        unsafe { vreinterpretq_u64_u8(vld1q_u8(bytes.as_ptr())) }
    }

    /// Folds `blocks.len() / 32` full 32-byte blocks into the four lane accumulators.
    ///
    /// Applies the xxHash64 round to all four lanes per block (two `uint64x2_t` registers, [a0 a1]
    /// and [a2 a3]).
    ///
    /// # Safety
    /// `blocks.len()` must be a multiple of 32; every byte read is in-bounds (each 16-byte load
    /// comes from a 32-byte sub-slice of `blocks`). `lanes` is a live `&mut [u64; 4]`.
    #[inline(never)]
    pub(super) unsafe fn fold_blocks(lanes: &mut [u64; 4], blocks: &[u8]) {
        // SAFETY: `blocks.len()` is a multiple of 32 (caller contract), so each loop turn reads
        // exactly 32 in-bounds bytes via two 16-byte `vld1q_u8` loads of owned `&[u8; 16]` halves;
        // the lane load/store touch the four in-bounds u64s of `lanes`.
        unsafe {
            let mut acc01 = vld1q_u64(lanes.as_ptr());
            let mut acc23 = vld1q_u64(lanes.as_ptr().add(2));
            let mut off = 0usize;
            while off + 32 <= blocks.len() {
                let lo: &[u8; 16] = blocks[off..off + 16].try_into().expect("16-byte half");
                let hi: &[u8; 16] = blocks[off + 16..off + 32].try_into().expect("16-byte half");
                acc01 = round_pair(acc01, le_u64x2(lo));
                acc23 = round_pair(acc23, le_u64x2(hi));
                off += 32;
            }
            vst1q_u64(lanes.as_mut_ptr(), acc01);
            vst1q_u64(lanes.as_mut_ptr().add(2), acc23);
        }
    }

    // Imports referenced only inside the kernel above; named here so a stray edit that drops a use
    // surfaces as an error rather than silently scalarising.
    #[allow(unused_imports)]
    use {vld1q_u8 as _b, vld1q_u64 as _a, vmlal_u32 as _c, vmovn_u64 as _d, vshrn_n_u64 as _e};
}

#[cfg(test)]
mod tests {
    use super::NeonFrameHash;
    use aislopdesk_core::frame_hash;

    /// Deterministic dependency-free PRNG (`SplitMix64`) so the differential test is reproducible.
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

    /// Widths chosen to exercise empty, sub-32 row tails, exact blocks, and block+tail combinations,
    /// plus odd widths and strides that pad past the visible region.
    const DIMS: &[(usize, usize)] = &[
        (0, 0),
        (1, 1),
        (7, 3),
        (16, 9),
        (31, 5),
        (32, 8),
        (33, 8),
        (64, 16),
        (100, 50),
        (127, 17),
        (128, 72),
        (255, 33),
    ];

    #[test]
    fn neon_hash_matches_scalar_over_many_planes() {
        let mut rng = SplitMix64::new(0xF00D_BABE_C0DE_1234);
        for &(w, h) in DIMS {
            // Several strides per (w,h): tight, +1, +15 (sub-16 tail in the padding), +37.
            for pad in [0usize, 1, 7, 15, 37] {
                let y_stride = w + pad;
                let cbcr_stride = w + pad;
                let mut y = vec![0u8; y_stride * h];
                let mut cbcr = vec![0u8; cbcr_stride * (h / 2)];
                rng.fill(&mut y);
                rng.fill(&mut cbcr);

                let scalar = frame_hash::hash_nv12(&y, y_stride, w, h, &cbcr, cbcr_stride);
                let neon = NeonFrameHash::hash_nv12(&y, y_stride, w, h, &cbcr, cbcr_stride);
                assert_eq!(scalar, neon, "diverged at w={w} h={h} pad={pad}");

                // Luma-only path too.
                let scalar_y = frame_hash::hash_nv12(&y, y_stride, w, h, &[], 0);
                let neon_y = NeonFrameHash::hash_nv12(&y, y_stride, w, h, &[], 0);
                assert_eq!(
                    scalar_y, neon_y,
                    "luma-only diverged at w={w} h={h} pad={pad}"
                );
            }
        }
    }

    #[test]
    fn neon_hash_matches_scalar_on_single_byte_flips() {
        // The differential equality must hold even under a one-byte perturbation anywhere — this is
        // the case that matters (a missed difference is a wrongly-suppressed real frame).
        let mut rng = SplitMix64::new(0x1357_9BDF_2468_ACE0);
        let (w, h) = (48usize, 40usize);
        let stride = w + 11;
        let mut y = vec![0u8; stride * h];
        rng.fill(&mut y);
        for i in (0..y.len()).step_by(13) {
            y[i] ^= 0x5A;
            assert_eq!(
                frame_hash::hash_nv12(&y, stride, w, h, &[], 0),
                NeonFrameHash::hash_nv12(&y, stride, w, h, &[], 0),
                "neon != scalar after flipping byte {i}"
            );
            y[i] ^= 0x5A;
        }
    }

    #[test]
    fn neon_hash_matches_scalar_for_large_realistic_frame() {
        // A ~1080p luma plane with a typical 64-byte-aligned stride, to exercise the bulk loop hard.
        let mut rng = SplitMix64::new(0xDEAD_BEEF_FEED_FACE);
        let (w, h) = (1920usize, 1080usize);
        let y_stride = (w + 63) & !63; // 1920 already 64-aligned; cover the general case anyway
        let cbcr_stride = y_stride;
        let mut y = vec![0u8; y_stride * h];
        let mut cbcr = vec![0u8; cbcr_stride * (h / 2)];
        rng.fill(&mut y);
        rng.fill(&mut cbcr);
        assert_eq!(
            frame_hash::hash_nv12(&y, y_stride, w, h, &cbcr, cbcr_stride),
            NeonFrameHash::hash_nv12(&y, y_stride, w, h, &cbcr, cbcr_stride),
            "neon != scalar on a 1080p frame"
        );
    }
}
