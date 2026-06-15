//! Burst-resilient transmission-order interleaver — the canonical `FragmentInterleaver`
//! logic (the Swift shell mirrors it).
//!
//! [`ReedSolomonFec`](crate::fec::ReedSolomonFec) recovers up to `m` lost fragments per
//! group of `group_size` CONSECUTIVE data fragments (`m == 1` is the XOR-equivalent
//! production wire). Sending fragments in that same consecutive order means an adjacent
//! datagram burst lands multiple losses in one group → past `m` it is unrecoverable →
//! visible flicker. This reorders TRANSMISSION (not the fragments' `frag_index`, which
//! are untouched) into column-major "one-per-group" order so consecutive datagrams belong
//! to DIFFERENT FEC groups; a burst of up to `num_groups` adjacent losses then spreads
//! across distinct groups, each recoverable.
//!
//! ## m-awareness
//!
//! For `m` parity shards per group the FEC emits parity in group-major-then-rank order
//! (`[g0p0, g0p1, … , g1p0, …]`). The data section is always column-major across groups.
//! The parity section is column-major across groups too — parity rank 0 of every group,
//! then rank 1 of every group, … — so an adjacent-loss burst that lands inside the parity
//! section also spreads across distinct groups (each group then loses ≤1 parity shard).
//! With `m == 1` every group has exactly one parity shard, so the column-major parity walk
//! reduces to the original "append parity in group order, LAST" → **byte-identical send
//! order to the pre-m-aware wire**. `m` is recovered from the parity count and the number
//! of data groups, so the caller passes only the data `group_size`.
//!
//! Host-only, NO wire change: the client reassembler keys by header fields and is
//! reorder-tolerant by design, so it reconstructs identically regardless of send order.

use crate::fragment::{Flags, FrameFragment};

/// Returns `fragments` reordered for burst-resilient transmission: data fragments emitted
/// column-major across FEC groups, then parity emitted column-major across groups too.
///
/// A no-op (returns the input unchanged, original order) when `group_size <= 1`, there is
/// ≤1 data group, or there are no more fragments than one group. The result is a
/// permutation of the input — same set of fragments, every `frag_index` preserved.
///
/// m-aware: `m` (parity shards per group) is derived as `parity_count / num_groups`. With
/// `m == 1` the parity walk is identical to appending parity in group order, so the send
/// order is byte-identical to the single-parity wire.
#[must_use]
pub fn interleave(fragments: Vec<FrameFragment>, group_size: usize) -> Vec<FrameFragment> {
    if group_size <= 1 || fragments.len() <= group_size {
        return fragments;
    }
    // Single data group → no interleave benefit (any 2 losses in it are unrecoverable
    // regardless). Count without consuming so the fallback preserves the original order.
    let data_count = fragments
        .iter()
        .filter(|f| !f.header.flags.contains(Flags::PARITY))
        .count();
    if data_count <= group_size {
        return fragments;
    }

    let mut data: Vec<Option<FrameFragment>> = Vec::with_capacity(data_count);
    let mut parity: Vec<Option<FrameFragment>> = Vec::new();
    for f in fragments {
        if f.header.flags.contains(Flags::PARITY) {
            parity.push(Some(f));
        } else {
            data.push(Some(f));
        }
    }

    let num_groups = data_count.div_ceil(group_size);
    let mut ordered: Vec<FrameFragment> = Vec::with_capacity(data.len() + parity.len());
    // DATA column-major: rank 0 of every group, then rank 1 of every group, … Consecutive
    // emissions are thus from distinct groups. Each (rank, group) index is visited
    // exactly once across the whole loop, so `take` never sees an already-moved slot.
    for rank in 0..group_size {
        for group in 0..num_groups {
            let idx = group * group_size + rank;
            if idx < data.len()
                && let Some(fragment) = data[idx].take()
            {
                ordered.push(fragment);
            }
        }
    }
    // PARITY column-major: the FEC lays parity group-major-then-rank as `[g*m + rank]`, so
    // the same rank-outer / group-inner walk spreads the parity section across groups too.
    // `m` is the parity shards per group; `m == 1` makes this the original group-order
    // append (parity LAST, byte-identical). A short / non-uniform parity array (so the
    // division does not divide evenly) degrades safely: any slot left unmoved by the
    // strided walk is swept up in original order afterwards, so the output stays a
    // permutation of the input no matter the count.
    let m = parity.len().checked_div(num_groups).unwrap_or(0);
    for rank in 0..m {
        for group in 0..num_groups {
            let idx = group * m + rank;
            if idx < parity.len()
                && let Some(fragment) = parity[idx].take()
            {
                ordered.push(fragment);
            }
        }
    }
    // Sweep up any parity not covered by the strided walk (m == 0, or a ragged count),
    // preserving original order — guarantees the result is always a full permutation.
    ordered.extend(parity.into_iter().flatten());
    ordered
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fec::{ReedSolomonFec, XorParityFec};
    use crate::fragment::{FrameFragmentHeader, VideoPacketizer};

    fn fids(frags: &[FrameFragment]) -> Vec<u16> {
        frags.iter().map(|f| f.header.frag_index).collect()
    }

    #[test]
    fn small_frame_is_unchanged() {
        let mut p = VideoPacketizer::new(None);
        let frags = p.packetize(&[1, 2, 3], crate::fragment::PacketizeOptions::default());
        let before = fids(&frags);
        let after = interleave(frags, 5);
        assert_eq!(fids(&after), before);
    }

    #[test]
    fn group_size_one_is_noop() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![0u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
        let frags = p.packetize(&frame, crate::fragment::PacketizeOptions::default());
        let before = fids(&frags);
        let after = interleave(frags, 1);
        assert_eq!(fids(&after), before);
    }

    #[test]
    fn column_major_spreads_groups_and_preserves_set() {
        // 7 data fragments, group size 3 → groups [0,1,2][3,4,5][6]. num_groups=3.
        // Column-major: rank0: 0,3,6 ; rank1: 1,4 ; rank2: 2,5 → [0,3,6,1,4,2,5].
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(3))));
        let frame = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 7];
        let frags = p.packetize(&frame, crate::fragment::PacketizeOptions::default());
        let data_count = frags
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .count();
        assert_eq!(data_count, 7);
        let before: std::collections::BTreeSet<u16> = fids(&frags).into_iter().collect();

        let after = interleave(frags, 3);
        let after_data: Vec<u16> = after
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .map(|f| f.header.frag_index)
            .collect();
        assert_eq!(after_data, vec![0, 3, 6, 1, 4, 2, 5]);
        // parity stays last
        assert!(
            after
                .iter()
                .skip(7)
                .all(|f| f.header.flags.contains(Flags::PARITY))
        );
        // permutation: same set of frag_index values
        let after_set: std::collections::BTreeSet<u16> =
            after.iter().map(|f| f.header.frag_index).collect();
        assert_eq!(after_set, before);
        let _ = FrameFragmentHeader::SIZE;
    }

    #[test]
    fn m2_parity_is_spread_column_major_and_permutation_preserved() {
        // 5 data fragments, group_size 2, m=2 → data groups [0,1][2,3][4]. num_groups=3.
        // Parity laid group-major-then-rank: g0p0,g0p1, g1p0,g1p1, g2p0,g2p1 → frag_index
        // 5..=10. m = parity_count(6) / num_groups(3) = 2.
        // DATA column-major: rank0: 0,2,4 ; rank1: 1,3 → [0,2,4,1,3].
        // PARITY column-major: rank0: g0p0(5),g1p0(7),g2p0(9) ; rank1: g0p1(6),g1p1(8),g2p1(10)
        //   → [5,7,9,6,8,10].
        let mut p = VideoPacketizer::new(Some(Box::new(ReedSolomonFec::new(2, 2))));
        let frame = vec![4u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5];
        let frags = p.packetize(&frame, crate::fragment::PacketizeOptions::default());
        let data_count = frags
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .count();
        assert_eq!(data_count, 5);
        let parity_count = frags
            .iter()
            .filter(|f| f.header.flags.contains(Flags::PARITY))
            .count();
        assert_eq!(parity_count, 6, "ceil(5/2)=3 groups * m=2");
        let before: std::collections::BTreeSet<u16> = fids(&frags).into_iter().collect();

        let after = interleave(frags, 2);
        let after_idx = fids(&after);
        assert_eq!(after_idx, vec![0, 2, 4, 1, 3, 5, 7, 9, 6, 8, 10]);
        // every fragment preserved (full permutation)
        let after_set: std::collections::BTreeSet<u16> = after_idx.into_iter().collect();
        assert_eq!(after_set, before);
    }
}
