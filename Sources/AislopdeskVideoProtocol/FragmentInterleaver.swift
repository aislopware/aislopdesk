import Foundation

/// PURE transmission-order interleaver for a frame's fragments (2026-06-08 — flicker fix).
///
/// WHY: ``XORParityFEC`` recovers exactly ONE lost fragment per group of `groupSize` CONSECUTIVE
/// data fragments (group g = data[g·k … g·k+k−1]). The host previously transmitted fragments in
/// that same consecutive order (`onEncodedFrame`'s tight send loop), so a burst that drops just 2
/// ADJACENT datagrams lands two losses in the SAME group → unrecoverable → a corrupt/partial decode
/// that the next frame only half-fixes → visible FLICKER on fast scroll. Raising the bitrate for the
/// 2× HiDPI display made each frame ~4× more fragments → ~4× more adjacent-loss chances → the flicker
/// the user reported.
///
/// WHAT: reorder TRANSMISSION (not the fragments' `fragIndex` — those are untouched) into column-major
/// "one-per-group" order, so consecutive datagrams on the wire belong to DIFFERENT FEC groups. A burst
/// of up to `numGroups` adjacent losses then spreads to distinct groups, each losing ≤1 → ALL
/// recoverable by single-loss XOR. The data section still precedes the parity section (doc 17 §3.6:
/// a lossless client decodes without waiting for parity; parity still arrives LAST, preserving the
/// reassembler's `fecReorderGrace`).
///
/// HOST-ONLY, NO WIRE/PROTOCOL CHANGE: the client's ``FrameReassembler`` keys data by `fragIndex` and
/// parity by `fragIndex - invertedDataCount(fragCount)` — purely header-derived, reorder-tolerant by
/// design (UDP already reorders) — so the receiver reconstructs identically regardless of send order.
///
/// The reorder law lives in the Rust core (`aislopdesk_core::interleaver`), driven over the
/// `aisd_interleave` C ABI — the SINGLE SOURCE OF TRUTH (m-aware: data column-major across FEC
/// groups, then parity column-major across groups; `m == 1` is byte-identical to the prior "parity
/// LAST"). The previous native Swift reorder is DELETED; this is a thin Rust-backed shell that keeps
/// the public API. NO wire change — only the send order differs.
public enum FragmentInterleaver {
    /// Returns `fragments` reordered for burst-resilient transmission, m-aware, in the Rust core. A
    /// no-op (byte-for-byte pass-through) when there is ≤1 group or `groupSize <= 1`. The returned
    /// array is a permutation of the input — same set of fragments, every `fragIndex` preserved.
    public static func interleave(_ fragments: [FrameFragment], groupSize: Int) -> [FrameFragment] {
        RustVideoFFI.interleave(fragments, groupSize: groupSize)
    }
}
