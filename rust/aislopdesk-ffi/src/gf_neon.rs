//! A NEON-accelerated [`GfRegion`] backend for the Reed-Solomon erasure code.
//!
//! [`aislopdesk_core`] keeps a portable, 100%-safe [`ScalarGf`] (table-driven, one byte at a
//! time). On Apple Silicon — our only shipping host for the realtime media path — the inner
//! `mul_add` loop is the hottest CPU work in the codec, so this crate (the one place `unsafe`
//! is allowed) provides a vectorised drop-in that processes **16 field bytes per iteration**.
//!
//! ## Technique — the split-table / `vtbl` multiply (ISA-L, Leopard, …)
//!
//! A GF(2^8) multiply by a fixed coefficient `c` is a function `b ↦ mul(c, b)`, i.e. a 256-entry
//! lookup. NEON's table instruction (`vqtbl1q_u8` = `tbl v.16b`) does **16 parallel** lookups but
//! only into a *16*-entry table. The trick is to split each byte into its two nibbles and exploit
//! distributivity of the field multiply over XOR (`b == (b & 0x0f) ^ (b & 0xf0)`):
//!
//! ```text
//! mul(c, b) == mul(c, b_lo) ^ mul(c, b_hi)        // b_lo = b & 0x0f, b_hi = b & 0xf0
//! ```
//!
//! So two 16-entry tables suffice, both precomputed per call with the scalar [`gf256::mul`]:
//!
//! ```text
//! LO[i] = mul(c, i)         for i in 0..16   // products of the low nibble (0x00..0x0f)
//! HI[i] = mul(c, i << 4)    for i in 0..16   // products of the high nibble (0x00,0x10,..0xf0)
//! ```
//!
//! Per 16-byte chunk: split into low nibbles (`and #0x0f`) and high nibbles (`ushr #4`), do one
//! `tbl` into each table, `eor` the two product vectors, then `eor` into the destination — exactly
//! `dst ^= mul(c, src)` for 16 lanes at once. This is **byte-identical** to [`ScalarGf`] because
//! the tables are filled by the same `gf256::mul`; the only difference is the lane count.
//!
//! ## Safety
//!
//! All `unsafe` is confined to one `#[inline(never)]` helper, [`neon::mul_add_kernel`], whose
//! `// SAFETY` block documents why the NEON intrinsics (`vld1q_u8`/`vqtbl1q_u8`/`veorq_u8`/
//! `vst1q_u8`) are sound: they operate on register lanes copied from slices the *safe* caller has
//! already split into exact 16-byte chunks (so every load/store is in-bounds, the chunks do not
//! alias, and the tables are owned 16-byte stack arrays). The tail (`len % 16`) and the entire
//! non-`aarch64` build go through the safe [`ScalarGf`].

use aislopdesk_core::gf256::{self, GfRegion, ScalarGf};

/// NEON split-table [`GfRegion`] for `aarch64`.
///
/// On any other architecture it is a transparent wrapper that forwards to [`ScalarGf`], so the
/// FFI crate still builds (and stays correct) everywhere; only Apple Silicon takes the vector
/// path.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NeonGf;

#[cfg(target_arch = "aarch64")]
impl GfRegion for NeonGf {
    #[inline]
    fn mul_add(&self, coeff: u8, src: &[u8], dst: &mut [u8]) {
        debug_assert!(dst.len() >= src.len(), "mul_add dst shorter than src");
        // `coeff == 0` contributes nothing; `coeff == 1` is a plain region XOR.
        if coeff == 0 {
            return;
        }
        if coeff == 1 {
            self.xor_add(src, dst);
            return;
        }

        // Precompute the two 16-entry nibble tables with the SAME scalar multiply the core uses,
        // so the vector result is byte-identical to `ScalarGf`. `mul` is `const`, branch-light.
        let mut lo = [0u8; 16];
        let mut hi = [0u8; 16];
        for i in 0..16u8 {
            lo[i as usize] = gf256::mul(coeff, i);
            hi[i as usize] = gf256::mul(coeff, i << 4);
        }

        // Process full 16-byte chunks on the NEON path; the safe iterators guarantee each pair of
        // chunks is exactly 16 bytes and in-bounds. `dst` is sliced to `src.len()` first so the
        // `dst`-chunk iterator stops with the `src`-chunk iterator (trailing dst stays untouched).
        let n = src.len();
        let dst = &mut dst[..n];
        let mut src_chunks = src.chunks_exact(16);
        let mut dst_chunks = dst.chunks_exact_mut(16);
        for (s, d) in src_chunks.by_ref().zip(dst_chunks.by_ref()) {
            let s: &[u8; 16] = s.try_into().expect("chunks_exact(16) yields 16 bytes");
            let d: &mut [u8; 16] = d.try_into().expect("chunks_exact_mut(16) yields 16 bytes");
            // SAFETY: `s` and `d` are owned `&[u8; 16]` / `&mut [u8; 16]`, so the kernel's
            // `vld1q_u8`/`vst1q_u8` read and write exactly the 16 in-bounds bytes they point at;
            // `&lo`/`&hi` are 16-byte stack arrays. NEON is a mandatory baseline on aarch64, so the
            // intrinsics are always available (no runtime feature gate needed). See the kernel doc.
            unsafe { neon::mul_add_kernel(s, d, &lo, &hi) };
        }

        // Tail (`n % 16` bytes): delegate the remainders to the safe scalar backend so any length
        // — including a pure-tail `n < 16` — is handled identically. `remainder()` borrows the
        // leftover slices the chunk iterators did not consume.
        ScalarGf.mul_add(coeff, src_chunks.remainder(), dst_chunks.into_remainder());
    }

    #[inline]
    fn xor_add(&self, src: &[u8], dst: &mut [u8]) {
        debug_assert!(dst.len() >= src.len(), "xor_add dst shorter than src");
        let n = src.len();
        let dst = &mut dst[..n];
        let mut src_chunks = src.chunks_exact(16);
        let mut dst_chunks = dst.chunks_exact_mut(16);
        for (s, d) in src_chunks.by_ref().zip(dst_chunks.by_ref()) {
            let s: &[u8; 16] = s.try_into().expect("chunks_exact(16) yields 16 bytes");
            let d: &mut [u8; 16] = d.try_into().expect("chunks_exact_mut(16) yields 16 bytes");
            // SAFETY: same contract as `mul_add` above — owned 16-byte array refs, so the load /
            // `eor` / store touch exactly 16 in-bounds, non-aliasing bytes.
            unsafe { neon::xor_add_kernel(s, d) };
        }
        ScalarGf.xor_add(src_chunks.remainder(), dst_chunks.into_remainder());
    }
}

/// The NEON intrinsic kernels — the crate's only floating block of `unsafe` for the GF path.
///
/// Each function takes already-bounded 16-byte array references from a safe caller, so the
/// `unsafe` is purely "these intrinsics are `unsafe fn`s", not any pointer/bounds reasoning.
#[cfg(target_arch = "aarch64")]
mod neon {
    use core::arch::aarch64::{
        uint8x16_t, vandq_u8, vdupq_n_u8, veorq_u8, vld1q_u8, vqtbl1q_u8, vshrq_n_u8, vst1q_u8,
    };

    /// `dst ^= mul(coeff, src)` for one 16-byte chunk via the split-nibble `tbl` multiply.
    ///
    /// `lo`/`hi` are the per-coefficient nibble tables (`lo[i] = mul(c, i)`, `hi[i] = mul(c,
    /// i<<4)`). Kept `#[inline(never)]` so the emitted symbol is greppable in the release asm
    /// (the `tbl`/`eor.16b`/`ldr q`/`str q` proof) and never silently scalarised by inlining.
    ///
    /// # Safety
    /// Sound for any inputs: `src`/`dst` are `&[u8; 16]` / `&mut [u8; 16]`, so `vld1q_u8` reads
    /// and `vst1q_u8` writes exactly the 16 bytes each points at (in-bounds, non-aliasing — `dst`
    /// is a unique `&mut`). The `tbl` lookups index a 16-byte table with 4-bit indices (`& 0x0f`
    /// / `>> 4`), always in range. NEON is the mandatory `aarch64` baseline, so the intrinsics are
    /// always legal here. No pointer arithmetic, no lifetime extension — pure register ops on
    /// copied lanes.
    #[inline(never)]
    pub(super) unsafe fn mul_add_kernel(
        src: &[u8; 16],
        dst: &mut [u8; 16],
        lo: &[u8; 16],
        hi: &[u8; 16],
    ) {
        // SAFETY: every pointer below is `.as_ptr()`/`.as_mut_ptr()` of a live 16-byte array, so
        // each `vld1q_u8` reads 16 valid bytes and the final `vst1q_u8` writes 16 valid bytes; the
        // table lookups are masked to 0..16. All other ops are pure register transforms.
        unsafe {
            let v: uint8x16_t = vld1q_u8(src.as_ptr());
            let table_lo: uint8x16_t = vld1q_u8(lo.as_ptr());
            let table_hi: uint8x16_t = vld1q_u8(hi.as_ptr());

            // Split each byte into its two nibbles.
            let low_nibbles = vandq_u8(v, vdupq_n_u8(0x0f));
            let high_nibbles = vshrq_n_u8::<4>(v);

            // 16 parallel table lookups into each nibble table, then XOR the partial products:
            // mul(c, b) == mul(c, b_lo) ^ mul(c, b_hi).
            let prod_lo = vqtbl1q_u8(table_lo, low_nibbles);
            let prod_hi = vqtbl1q_u8(table_hi, high_nibbles);
            let product = veorq_u8(prod_lo, prod_hi);

            // Accumulate into the destination: dst ^= product.
            let acc = vld1q_u8(dst.as_ptr());
            vst1q_u8(dst.as_mut_ptr(), veorq_u8(acc, product));
        }
    }

    /// `dst ^= src` for one 16-byte chunk (the `coeff == 1` region-add fast path).
    ///
    /// # Safety
    /// Sound for any inputs: `src`/`dst` are 16-byte array refs, so both `vld1q_u8`s and the
    /// `vst1q_u8` touch exactly their 16 in-bounds, non-aliasing bytes.
    #[inline(never)]
    pub(super) unsafe fn xor_add_kernel(src: &[u8; 16], dst: &mut [u8; 16]) {
        // SAFETY: `src`/`dst` are live 16-byte arrays; the two loads read 16 valid bytes each and
        // the store writes 16 valid bytes to the unique `&mut`.
        unsafe {
            let s = vld1q_u8(src.as_ptr());
            let d = vld1q_u8(dst.as_ptr());
            vst1q_u8(dst.as_mut_ptr(), veorq_u8(s, d));
        }
    }
}

// On a non-aarch64 host the NEON path does not exist; forward the whole trait to the safe scalar
// backend so this crate still builds and behaves identically off Apple Silicon.
#[cfg(not(target_arch = "aarch64"))]
impl GfRegion for NeonGf {
    #[inline]
    fn mul_add(&self, coeff: u8, src: &[u8], dst: &mut [u8]) {
        ScalarGf.mul_add(coeff, src, dst);
    }

    #[inline]
    fn xor_add(&self, src: &[u8], dst: &mut [u8]) {
        ScalarGf.xor_add(src, dst);
    }
}

#[cfg(test)]
mod tests {
    use super::NeonGf;
    use aislopdesk_core::gf256::{GfRegion, ScalarGf};

    /// Deterministic, dependency-free PRNG (`SplitMix64`) so the differential test is reproducible.
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

    /// Widths exercising: empty, sub-16 tails (1,7,15), exact blocks (16,32,64), block+tail
    /// (17,31,33,63,100), and a long run with the max-byte odd length (255).
    const WIDTHS: &[usize] = &[
        0, 1, 7, 15, 16, 17, 31, 32, 33, 48, 63, 64, 65, 96, 100, 127, 128, 200, 255,
    ];

    #[test]
    fn neon_mul_add_matches_scalar_for_every_coeff_and_width() {
        let mut rng = SplitMix64::new(0xA15D_0DE5_C0DE_F00D);
        let neon = NeonGf;
        let scalar = ScalarGf;
        for coeff in 0u16..=255 {
            let coeff = coeff as u8;
            for &width in WIDTHS {
                let mut src = vec![0u8; width];
                rng.fill(&mut src);
                // Pre-fill dst with non-zero garbage so we exercise ACCUMULATION (`^=`), not a
                // bare store — the two backends must fold into identical pre-existing bytes.
                let mut dst_neon = vec![0u8; width];
                rng.fill(&mut dst_neon);
                let mut dst_scalar = dst_neon.clone();

                neon.mul_add(coeff, &src, &mut dst_neon);
                scalar.mul_add(coeff, &src, &mut dst_scalar);

                assert_eq!(
                    dst_neon, dst_scalar,
                    "mul_add diverged: coeff={coeff} width={width}"
                );
            }
        }
    }

    #[test]
    fn neon_xor_add_matches_scalar_for_every_width() {
        let mut rng = SplitMix64::new(0x0FF1_CE15_DEAD_BEEF);
        let neon = NeonGf;
        let scalar = ScalarGf;
        for &width in WIDTHS {
            let mut src = vec![0u8; width];
            rng.fill(&mut src);
            let mut dst_neon = vec![0u8; width];
            rng.fill(&mut dst_neon);
            let mut dst_scalar = dst_neon.clone();

            neon.xor_add(&src, &mut dst_neon);
            scalar.xor_add(&src, &mut dst_scalar);

            assert_eq!(dst_neon, dst_scalar, "xor_add diverged: width={width}");
        }
    }

    #[test]
    fn neon_mul_add_accumulates_across_repeated_calls() {
        // Two scaled shards folded into ONE accumulator (the RS encode pattern) must match the
        // scalar backend folded the same way — proves accumulation is correct across calls, not
        // just within one.
        let mut rng = SplitMix64::new(0xBADC_0FFE_E0DD_F00D);
        let neon = NeonGf;
        let scalar = ScalarGf;
        for width in [16usize, 17, 64, 100, 255] {
            let mut a = vec![0u8; width];
            let mut b = vec![0u8; width];
            rng.fill(&mut a);
            rng.fill(&mut b);
            let mut acc_neon = vec![0u8; width];
            let mut acc_scalar = acc_neon.clone();

            for (coeff_a, coeff_b) in [(0x53u8, 0x02u8), (0x01, 0xFF), (0x9D, 0x10)] {
                neon.mul_add(coeff_a, &a, &mut acc_neon);
                neon.mul_add(coeff_b, &b, &mut acc_neon);
                scalar.mul_add(coeff_a, &a, &mut acc_scalar);
                scalar.mul_add(coeff_b, &b, &mut acc_scalar);
            }
            assert_eq!(acc_neon, acc_scalar, "accumulation diverged: width={width}");
        }
    }

    #[test]
    fn neon_mul_add_leaves_trailing_dst_untouched() {
        // dst longer than src: the bytes past src.len() must stay exactly as they were (the
        // zero-pad / ragged-shard case in the codec).
        let neon = NeonGf;
        let src = [0x12u8, 0x34, 0x56];
        let mut dst = [0xAAu8; 20];
        neon.mul_add(0x07, &src, &mut dst);
        assert_eq!(
            &dst[3..],
            &[0xAAu8; 17],
            "bytes past src.len() were modified"
        );
    }
}
