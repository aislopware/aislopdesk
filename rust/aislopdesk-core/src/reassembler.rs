//! Frame reassembly with loss detection and FEC — the canonical `FrameReassembler` logic (the Swift shell mirrors it).
//!
//! The stream is plain UDP, so fragments may be lost or reordered. A frame is declared
//! lost (`Dropped`) only once it cannot complete — i.e. a NEWER frame's fragments arrive
//! while this one is still missing data FEC cannot fill. That edge triggers
//! request-recovery.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::adaptive_fec;
use crate::fec::FecScheme;
use crate::fragment::{Flags, FrameFragment};
use crate::seq::distance_wrapped;

/// A fully reassembled frame, ready to feed the decoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReassembledFrame {
    /// The frame's id.
    pub frame_id: u32,
    /// Whether this is a keyframe (IDR).
    pub keyframe: bool,
    /// Whether this is a crisp static refresh.
    pub crisp: bool,
    /// The AVCC byte buffer (length-prefixed NAL units), restored directly or via FEC.
    pub avcc: Vec<u8>,
    /// True when a data hole existed and FEC parity filled it to complete the frame.
    pub recovered_via_fec: bool,
    /// WF-8: this is a Long-Term-Reference frame; on a successful decode the client must
    /// reply `ack(frame_id)` so the host learns the client holds this LTR.
    pub is_ltr: bool,
    /// Bit 7 — this frame was encoded via `ForceLTRRefresh` (references only acked LTRs).
    pub acked_anchored: bool,
}

/// The outcome of feeding one datagram to the reassembler.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReassemblyResult {
    /// More fragments are still needed for this frame; nothing to emit yet.
    Incomplete,
    /// The frame is complete and reassembled (possibly via FEC recovery).
    Completed(ReassembledFrame),
    /// The frame was abandoned: a fragment is missing and FEC could not recover it, so
    /// the caller must drop the frame and signal recovery. Carries the lost `frame_id`.
    Dropped {
        /// The lost frame's id.
        frame_id: u32,
    },
    /// The datagram belonged to a frame already completed or dropped — ignored.
    Stale,
}

#[derive(Debug, Default)]
struct Pending {
    frag_count: u16,
    keyframe: bool,
    crisp: bool,
    is_ltr: bool,
    acked_anchored: bool,
    /// FEC tier PINNED from the first fragment seen for this frame.
    fec_tier: u8,
    /// Data-fragment payloads by `frag_index` (the data range is `0 .. data_count`).
    data: HashMap<u16, Vec<u8>>,
    /// Parity-fragment payloads keyed by GROUP ORDER (0-based among parity frags), NOT by
    /// raw `frag_index`, so a lost group-0 parity never shifts the boundary.
    parity: HashMap<usize, Vec<u8>>,
    /// The observed parity boundary (lowest parity `frag_index` seen). Authoritative only
    /// in the no-FEC fallback; with FEC the boundary comes from the fragCount inversion.
    data_count: Option<usize>,
}

/// Reassembles fragmented frames by `frame_id`, detects loss, and applies FEC.
///
/// Owns mutable per-frame buffers; lives inside the single client receive loop (one
/// reassembler per video stream).
pub struct FrameReassembler {
    fec: Option<Box<dyn FecScheme>>,
    pending: HashMap<u32, Pending>,
    highest_retired_frame_id: Option<u32>,
    highest_seen_frame_id: Option<u32>,
    retired: HashSet<u32>,
    dropped_queue: VecDeque<u32>,
    fec_reorder_grace: i32,
    /// NACK / selective-ARQ: frame-ids past the frontier a FEC-unrecoverable frame is HELD pending
    /// (instead of Dropped at `fec_reorder_grace`) so a host retransmit can still fill it within the
    /// client's playout buffer. `0` = retransmit OFF (legacy drop behaviour). Set by
    /// [`enable_retransmit`](Self::enable_retransmit).
    retransmit_grace: i32,
    /// Frames already surfaced via [`next_needs_retransmit`](Self::next_needs_retransmit) (so each
    /// retransmit is requested once). Cleared on retire; bounded like `retired`.
    nacked: HashSet<u32>,
    /// `(frame_id, missing data-fragment indices)` the client should NACK, FIFO.
    needs_retransmit_queue: VecDeque<(u32, Vec<u16>)>,
    /// Only NACK a loss of at most this many DATA fragments — a SMALL loss (a keystroke / tiny frame)
    /// is cheap and stutter-free to retransmit, but a BIG loss (a scroll frame) is wasteful to
    /// re-send into a burst and is better served by an LTR-refresh skip-to-current. Above this the
    /// frame is left to Drop (the LTR-refresh fallback). Clamped to the wire cap
    /// [`MAX_NACK_FRAGMENTS`](crate::recovery::RecoveryMessage::MAX_NACK_FRAGMENTS) by `enable_retransmit`.
    nack_max_frags: usize,
}

impl FrameReassembler {
    /// Upper bound on a frame's declared fragment count (hostile-input guard). A real
    /// frame is at most a few thousand fragments; a larger value can only be hostile, so
    /// it is rejected before any per-frame buffer is allocated.
    pub const MAX_FRAGMENTS_PER_FRAME: usize = 8192;

    /// Builds a reassembler. `fec_reorder_grace` is how many frame-ids past the loss
    /// frontier a frame stays eligible for FEC while only awaiting (recoverable) parity
    /// that the packetizer emits last; floored at 0.
    ///
    /// TODO (WF6 LOW #2 — gated for a future `m > 1` activation, NOT active today): when the
    /// tier→`m` table ([`adaptive_fec::parity_count`]) gains `m > 1` values, the per-tier
    /// `group_size` ([`adaptive_fec::group_size`]) the recover path groups by MUST equal the
    /// configured Reed-Solomon codec's `k` for every tier that maps to `m > 1` — a systematic
    /// `[k + m, k]` code's parity is only valid over groups of EXACTLY `k` data shards, so a tier
    /// whose `group_size != k` would feed `recover` a window the matrix was never built for and
    /// silently fail to repair. With the production codec (`m == 1`, no matrix) the per-call
    /// `group_size` is honoured EXACTLY regardless of `k`, so today this is moot and every tier is
    /// safe. The reconciliation (assert/clamp `group_size == k` for `m > 1` tiers) belongs in the
    /// later workflow that chooses the `m > 1` table values — it is intentionally NOT done here so
    /// the m == 1 wire stays byte-identical.
    #[must_use]
    pub fn new(fec: Option<Box<dyn FecScheme>>, fec_reorder_grace: i32) -> Self {
        Self {
            fec,
            pending: HashMap::new(),
            highest_retired_frame_id: None,
            highest_seen_frame_id: None,
            retired: HashSet::new(),
            dropped_queue: VecDeque::new(),
            fec_reorder_grace: fec_reorder_grace.max(0),
            retransmit_grace: 0,
            nacked: HashSet::new(),
            needs_retransmit_queue: VecDeque::new(),
            nack_max_frags: 0,
        }
    }

    /// Enables NACK / selective ARQ. A FEC-unrecoverable frame is then HELD pending for `grace`
    /// frame-ids past the loss frontier (instead of being Dropped at `fec_reorder_grace`), and its
    /// missing DATA fragment indices are surfaced once via
    /// [`next_needs_retransmit`](Self::next_needs_retransmit) — giving a host retransmit time to
    /// arrive inside the client's playout buffer (no stutter). If the retransmit never lands the
    /// frame is Dropped once `grace` elapses (the LTR-refresh fallback then fires as before).
    ///
    /// Only losses of at most `max_frags` DATA fragments get a retransmit request (a SMALL loss — cheap +
    /// stutter-free to re-send); a BIGGER loss (e.g. a scroll frame) is left to Drop → LTR-refresh
    /// skip-to-current, which is smoother and far cheaper than re-sending a stale frame into a burst.
    /// `max_frags` is clamped to the wire cap
    /// [`MAX_NACK_FRAGMENTS`](crate::recovery::RecoveryMessage::MAX_NACK_FRAGMENTS). `grace == 0` (the
    /// default) disables retransmit entirely — byte-identical legacy drop behaviour.
    pub fn enable_retransmit(&mut self, grace: i32, max_frags: usize) {
        self.retransmit_grace = grace.max(0);
        self.nack_max_frags = max_frags.min(crate::recovery::RecoveryMessage::MAX_NACK_FRAGMENTS);
    }

    /// Pops the next `(frame_id, missing data-fragment indices)` the client should NACK, or `None`.
    /// Drained by the client after each ingest (alongside [`next_dropped_frame`](Self::next_dropped_frame)).
    pub fn next_needs_retransmit(&mut self) -> Option<(u32, Vec<u16>)> {
        self.needs_retransmit_queue.pop_front()
    }

    /// Pops the next unrecoverably-lost `frame_id` detected during prior `ingest` calls,
    /// or `None`. The client drains this after each ingest and issues a recovery signal
    /// for each.
    pub fn next_dropped_frame(&mut self) -> Option<u32> {
        self.dropped_queue.pop_front()
    }

    /// Feeds one parsed fragment, returning the outcome FOR THE INGESTED FRAGMENT'S
    /// frame. Drops of older, now-hopeless frames are surfaced separately via
    /// [`next_dropped_frame`](Self::next_dropped_frame). As a convenience, when the
    /// ingested fragment is incomplete but its own frame became hopeless, `Dropped` is
    /// returned directly.
    pub fn ingest(&mut self, fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header;
        let frame_id = header.frame_id;

        // Hostile-input guard (UDP video has no auth beyond the mesh): reject an
        // implausible header BEFORE allocating any per-frame buffer.
        if !(header.frag_count > 0
            && usize::from(header.frag_count) <= Self::MAX_FRAGMENTS_PER_FRAME
            && header.frag_index < header.frag_count)
        {
            return ReassemblyResult::Stale;
        }

        if self.retired.contains(&frame_id) {
            return ReassemblyResult::Stale;
        }
        if let Some(retired_high) = self.highest_retired_frame_id
            && distance_wrapped(frame_id, retired_high) <= 0
            && !self.pending.contains_key(&frame_id)
        {
            return ReassemblyResult::Stale;
        }

        // Advance the loss frontier.
        match self.highest_seen_frame_id {
            Some(seen) if distance_wrapped(frame_id, seen) > 0 => {
                self.highest_seen_frame_id = Some(frame_id);
            }
            None => self.highest_seen_frame_id = Some(frame_id),
            Some(_) => {}
        }

        let entry = self.pending.entry(frame_id).or_insert_with(|| Pending {
            frag_count: header.frag_count,
            fec_tier: header.flags.fec_tier(),
            ..Pending::default()
        });
        entry.frag_count = header.frag_count;
        if header.flags.contains(Flags::KEYFRAME) {
            entry.keyframe = true;
        }
        if header.flags.contains(Flags::CRISP) {
            entry.crisp = true;
        }
        if header.flags.contains(Flags::IS_LTR) {
            entry.is_ltr = true;
        }
        if header.flags.contains(Flags::ACKED_ANCHORED) {
            entry.acked_anchored = true;
        }

        if header.flags.contains(Flags::PARITY) {
            let p_index = usize::from(header.frag_index);
            // group size + m both need `self.fec` (disjoint field) + this entry's pinned tier.
            let fec = self.fec.as_deref();
            let g_opt = fec.and_then(|f| adaptive_fec::group_size(entry.fec_tier, f.group_size()));
            let m = {
                let default_m = fec.map_or(1, FecScheme::parity_count_per_group);
                adaptive_fec::parity_count(entry.fec_tier, default_m).max(1)
            };
            let total = usize::from(entry.frag_count);
            // m-aware boundary; on no solution fall back to the TOTAL frag_count — identical to
            // [`resolved_data_count`]'s `.unwrap_or(total)`, so the boundary the parity is keyed
            // against and the boundary `assemble`/`can_eventually_complete` use never disagree.
            // (WF6 LOW #1: the old `.unwrap_or(p_index)` here keyed parity against a DIFFERENT
            // boundary than the one resolved_data_count derives, which on a no-solution header
            // mis-mapped surviving parity. `total` is the consistent, byte-identical choice for the
            // m == 1 wire — a real frame always solves, so this only changes the corrupt-header
            // degenerate path, and changes it to AGREE with resolved_data_count.) The OFF/no-FEC
            // case (`g_opt == None`) keeps the observed parity index `p_index`.
            let data_boundary =
                g_opt.map_or(p_index, |g| invert_data_count(total, g, m).unwrap_or(total));
            entry.data_count = Some(entry.data_count.unwrap_or(p_index).min(p_index));
            // Parity is laid out group-major then parity-rank AFTER the data fragments, so
            // `frag_index - data_boundary` IS the flat layout index `group_index * m + rank`
            // (see `parity_index`). For m == 1 this collapses to the group order — byte-identical.
            let parity_slot = p_index.saturating_sub(data_boundary);
            entry.parity.insert(parity_slot, fragment.payload);
        } else {
            entry.data.insert(header.frag_index, fragment.payload);
        }

        // Try to complete THIS frame.
        let result = self.try_complete(frame_id);

        // Sweep ALL pending frames strictly older than the frontier that can no longer
        // complete; queue them as drops (runs regardless of `result`, so completing a
        // newer frame never hides an older, hopeless one).
        self.sweep_hopeless_frames();

        if matches!(result, ReassemblyResult::Completed(_)) {
            return result;
        }

        // The ingested frame itself may have just been declared hopeless by the sweep.
        if !self.pending.contains_key(&frame_id) && self.dropped_queue.contains(&frame_id) {
            self.dropped_queue.retain(|&f| f != frame_id);
            return ReassemblyResult::Dropped { frame_id };
        }
        ReassemblyResult::Incomplete
    }

    fn try_complete(&mut self, frame_id: u32) -> ReassemblyResult {
        let fec = self.fec.as_deref();
        let Some(entry) = self.pending.get(&frame_id) else {
            return ReassemblyResult::Stale;
        };
        // CHEAP completeness precheck before the expensive [`assemble`] (which clones every
        // present fragment payload and runs the FEC recovery pass). `can_eventually_complete`
        // is OUTCOME-EQUIVALENT to "assemble would succeed now" — it returns true iff every
        // group is either hole-free or has enough ALREADY-PRESENT parity to cover its erasures
        // (the exact precondition under which the systematic RS/XOR recover fills all holes) —
        // but it uses only HashMap presence lookups, no per-fragment payload clone and no GF
        // recovery work. Without this gate, `try_complete` ran the full clone + FEC-recover on
        // EVERY fragment ingest of an in-flight frame, so a frame of N fragments arriving one
        // at a time paid O(N^2) payload-clone churn plus N redundant recovery attempts. The
        // Completed/Incomplete decision is unchanged (golden_parity + the reassembler suite
        // pin it); only the wasted work on not-yet-completable ingests is removed.
        if !can_eventually_complete(fec, entry) {
            return ReassemblyResult::Incomplete;
        }
        let Some((avcc, recovered_via_fec)) = assemble(fec, entry) else {
            return ReassemblyResult::Incomplete;
        };
        let frame = ReassembledFrame {
            frame_id,
            keyframe: entry.keyframe,
            crisp: entry.crisp,
            avcc,
            recovered_via_fec,
            is_ltr: entry.is_ltr,
            acked_anchored: entry.acked_anchored,
        };
        self.retire(frame_id);
        ReassemblyResult::Completed(frame)
    }

    fn sweep_hopeless_frames(&mut self) {
        let Some(frontier) = self.highest_seen_frame_id else {
            return;
        };
        let fec = self.fec.as_deref();
        let grace = self.fec_reorder_grace;
        let rgrace = self.retransmit_grace;
        let mut hopeless: Vec<u32> = Vec::new();
        // NACK candidates found this sweep (FEC-unrecoverable, not yet nacked, still inside the
        // retransmit window). Collected under the immutable `pending` borrow, applied after.
        let mut nack: Vec<(u32, Vec<u16>)> = Vec::new();
        for (&fid, entry) in &self.pending {
            // fid strictly OLDER than the frontier: frontier - fid > 0.
            let age = distance_wrapped(frontier, fid);
            if age <= 0 || can_eventually_complete(fec, entry) {
                continue; // newer than the frontier, or completable now — not hopeless.
            }
            // Hole(s) only fillable by not-yet-arrived parity → keep within the grace window so
            // reordered parity (emitted last) still has a chance to land.
            if awaiting_recoverable_parity(fec, entry) && age <= grace {
                continue;
            }
            // FEC cannot recover this frame from what is here. With NACK enabled (`rgrace > 0`) and
            // the loss SMALL enough to retransmit, HOLD it for the retransmit-grace window so a host
            // re-send can fill it inside the client's playout buffer, and surface the request once.
            // A loss too BIG to NACK (or an already-requested one short of its window) is NOT held
            // uselessly: it falls straight through to the prompt Drop → LTR-refresh skip-to-current
            // (holding it would stall the in-order client for the whole grace with no retransmit
            // coming — the late-frame regression this guard fixes).
            if rgrace > 0 && age <= rgrace {
                if self.nacked.contains(&fid) {
                    continue; // already requested → hold for its retransmit.
                }
                if let Some(missing) = missing_data_frags(fec, entry, self.nack_max_frags) {
                    nack.push((fid, missing));
                    continue; // small loss → request + hold for the retransmit.
                }
                // else: too big to NACK → fall through to the prompt drop below (no useless hold).
            }
            // Past every grace window → genuinely hopeless (the LTR-refresh fallback then fires).
            hopeless.push(fid);
        }
        for (fid, missing) in nack {
            self.nacked.insert(fid);
            self.needs_retransmit_queue.push_back((fid, missing));
        }
        // Drop oldest-first for deterministic recovery-signal ordering.
        hopeless.sort_by(|&a, &b| distance_wrapped(a, b).cmp(&0));
        for fid in hopeless {
            self.retire(fid);
            self.dropped_queue.push_back(fid);
        }
    }

    fn retire(&mut self, frame_id: u32) {
        self.pending.remove(&frame_id);
        // Drop any NACK bookkeeping: a retired frame (completed OR genuinely dropped) is no longer
        // a retransmit candidate, so the once-per-frame guard can forget it.
        self.nacked.remove(&frame_id);
        self.retired.insert(frame_id);
        match self.highest_retired_frame_id {
            Some(high) if distance_wrapped(frame_id, high) > 0 => {
                self.highest_retired_frame_id = Some(frame_id);
            }
            None => self.highest_retired_frame_id = Some(frame_id),
            Some(_) => {}
        }
        // Bound the retired set so a long session doesn't grow it unboundedly.
        if self.retired.len() > 512
            && let Some(high) = self.highest_retired_frame_id
        {
            self.retired.retain(|&x| distance_wrapped(high, x) <= 256);
        }
    }
}

/// The PER-FRAME FEC group size for `entry`: `None` for a no-FEC client OR an OFF-tier
/// frame, in which case the frame is treated as no-parity.
fn parity_group_size(fec: Option<&dyn FecScheme>, entry: &Pending) -> Option<usize> {
    fec.and_then(|f| adaptive_fec::group_size(entry.fec_tier, f.group_size()))
}

/// The missing DATA fragment indices for `entry` (those in `0..data_count` not yet received),
/// for a NACK / selective-ARQ request — or `None` when there are none to request, the count exceeds
/// `max_frags` (a BIG loss: re-sending a stale frame into a burst is wasteful, so the client lets it
/// Drop → LTR-refresh skip-to-current instead), or the data count is unknown. Parity fragments are
/// NOT requested — the host's retransmit ring holds the original data datagrams, and once enough
/// DATA arrives the frame completes (with FEC for any residual hole).
fn missing_data_frags(
    fec: Option<&dyn FecScheme>,
    entry: &Pending,
    max_frags: usize,
) -> Option<Vec<u16>> {
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        return None;
    }
    let missing: Vec<u16> = (0..data_count)
        .filter(|&i| !entry.data.contains_key(&(i as u16)))
        .map(|i| i as u16)
        .collect();
    if missing.is_empty() || missing.len() > max_frags {
        None
    } else {
        Some(missing)
    }
}

/// The PER-FRAME parity-shards-per-group count (`m`) for `entry`, derived from the frame's
/// pinned FEC tier via [`adaptive_fec::parity_count`], floored to at least 1.
///
/// The tier's `default_m` is the configured scheme's own
/// [`parity_count_per_group`](FecScheme::parity_count_per_group) (`1` for the production XOR /
/// `m == 1` codec), so today this returns `1` for EVERY frame and the receive path is
/// byte-identical to the single-parity world. A no-FEC client has no parity, so `m` is `1`
/// (immaterial — no recovery is attempted). When the tier→m table later gains `m > 1` values,
/// this is the single point through which the reassembler learns the per-frame multiplicity.
fn parity_count(fec: Option<&dyn FecScheme>, entry: &Pending) -> usize {
    let default_m = fec.map_or(1, FecScheme::parity_count_per_group);
    adaptive_fec::parity_count(entry.fec_tier, default_m).max(1)
}

/// Resolves how many of a frame's fragments are DATA (vs FEC parity). With FEC, always
/// derive `data_count` from the unambiguous fragCount inversion (never the observed
/// parity boundary, which a lost group-0 parity would shift). With no FEC,
/// `data_count == frag_count`.
///
/// The inversion is m-aware: it solves `frag_count = data + m * ceil(data / g)` for the
/// per-frame `m` ([`parity_count`]). When no data count solves it (a corrupt header, or a
/// `frag_count` shaped for a different `m`) it falls back to `frag_count` — byte-identical to
/// the original `m == 1` fallback (which returned the total on no solution).
fn resolved_data_count(fec: Option<&dyn FecScheme>, entry: &Pending) -> usize {
    let total = usize::from(entry.frag_count);
    parity_group_size(fec, entry).map_or_else(
        || entry.data_count.unwrap_or(total),
        |g| invert_data_count(total, g, parity_count(fec, entry)).unwrap_or(total),
    )
}

/// Inverts `frag_count = data_count + m * ceil(data_count / group_size)` for `data_count`.
///
/// `m` is the parity-shards-per-group multiplicity (`m == 1` is the single-parity-per-group
/// case). The right-hand side is monotonic non-decreasing in `data_count`, so a descending
/// scan finds the (unique, when it exists) solution.
///
/// Returns `None` when no `data_count` solves the equation for the given `(group_size, m)` —
/// e.g. a `frag_count` that cannot be `data + m*groups` for any data count (a corrupt header,
/// or a `frag_count` shaped for a different `m`). The single-parity call sites recover the
/// pre-existing total-on-no-solution fallback via [`inverted_data_count`].
///
/// A non-positive `group_size` or `m` (defensive, off hostile input) yields `None`.
#[must_use]
pub const fn invert_data_count(frag_count: usize, group_size: usize, m: usize) -> Option<usize> {
    if group_size < 1 || m < 1 {
        return None;
    }
    let mut d = frag_count;
    while d > 0 {
        let parity = m * d.div_ceil(group_size);
        if d + parity == frag_count {
            return Some(d);
        }
        if d + parity < frag_count {
            // monotonic: every smaller `d` undershoots even more — no solution exists.
            return None;
        }
        d -= 1;
    }
    // d == 0: a frame with zero data fragments has zero parity, so frag_count must be 0.
    if frag_count == 0 { Some(0) } else { None }
}

/// Whether a group is unrecoverable: it lost more data fragments than its budget `m` repairs.
///
/// With `m == 1` this is the original `missing >= 2` test; an `[k + m, k]` code recovers up
/// to `m` erasures per group, so `missing > m` is terminal.
#[must_use]
pub const fn group_is_hopeless(missing_in_group: usize, m: usize) -> bool {
    missing_in_group > m
}

/// The flat index, within a frame's group-major/parity-rank parity array, of the parity
/// shard at `rank` (`0..m`) of group `group_index`: `group_index * m + rank`.
///
/// Mirrors the [`crate::fec::FecScheme`] parity layout (group 0's rank-0..(m-1), then group
/// 1's, …). For `m == 1` this collapses to `group_index` — byte-identical to the v1 layout
/// where parity is keyed by group order alone.
#[must_use]
pub const fn parity_index(group_index: usize, rank: usize, m: usize) -> usize {
    group_index * m + rank
}

/// Whether a group with `missing_in_group` lost data fragments can be repaired GIVEN the
/// count of that group's parity shards that have actually survived (arrived).
///
/// A group is repairable iff it lost at least one fragment, the loss is within the code's
/// per-group budget `m` ([`group_is_hopeless`] is false), AND enough of its `m` parity
/// shards survived to cover the erasures (`surviving_parity >= missing_in_group`). An `[k +
/// m, k]` MDS code needs exactly `missing` independent parity shards to solve `missing`
/// erasures. With `m == 1` this is "one hole AND that group's single parity is present" —
/// the original single-parity condition.
#[must_use]
pub const fn group_is_recoverable(
    missing_in_group: usize,
    surviving_parity: usize,
    m: usize,
) -> bool {
    missing_in_group >= 1
        && !group_is_hopeless(missing_in_group, m)
        && surviving_parity >= missing_in_group
}

/// Returns the reassembled AVCC bytes if all data fragments are present (after FEC
/// recovery), else `None`. The bool is true when a hole existed and FEC filled it.
fn assemble(fec: Option<&dyn FecScheme>, entry: &Pending) -> Option<(Vec<u8>, bool)> {
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        // A zero-data frame: only valid if it is a single empty fragment at index 0.
        return entry.data.get(&0).map(|only| (only.clone(), false));
    }

    let mut data_fragments: Vec<Option<Vec<u8>>> = (0..data_count)
        .map(|i| entry.data.get(&(i as u16)).cloned())
        .collect();

    let had_hole = data_fragments.iter().any(Option::is_none);
    if had_hole && let (Some(fec), Some(g)) = (fec, parity_group_size(fec, entry)) {
        // The full flat parity array in group-major then parity-rank order
        // (`parity[group * m + rank]`) — exactly the layout `FecScheme::recover` indexes. A
        // lost parity shard leaves its slot `None`; the codec recovers up to `m` data losses
        // per group from the survivors. `m == 1` collapses to one parity per group (the v1
        // XOR layout), so this is byte-identical for every current frame.
        let parity_slots = usize::from(entry.frag_count).saturating_sub(data_count);
        let parity_fragments: Vec<Option<Vec<u8>>> = (0..parity_slots)
            .map(|i| entry.parity.get(&i).cloned())
            .collect();
        // ADAPTIVE-m: recover at the SAME per-frame m the host encoded with (derived from this
        // frame's pinned FEC tier), which sets both the parity-array stride (`group * m + rank`)
        // and the per-group recovery budget. For every legacy tier this is the codec's configured
        // m, so `recover_with_m` is byte-identical to `recover`.
        let m = parity_count(Some(fec), entry);
        fec.recover_with_m(&mut data_fragments, &parity_fragments, g, m);
    }

    if data_fragments.iter().any(Option::is_none) {
        return None;
    }
    // Pre-size to the exact assembled length so the concat never reallocates mid-loop (the
    // fragment lengths are already in cache from the recovery pass above).
    let total: usize = data_fragments.iter().flatten().map(Vec::len).sum();
    let mut avcc = Vec::with_capacity(total);
    for fragment in data_fragments {
        avcc.extend_from_slice(&fragment.expect("checked non-none above"));
    }
    Some((avcc, had_hole))
}

/// Whether a frame still has a chance to complete (all data present, or FEC could fill
/// the remaining holes from the parity it already holds).
///
/// m-aware: a group is hopeless when it lost more than its budget `m`
/// ([`group_is_hopeless`]); a group still missing data needs as many SURVIVING parity shards
/// as it has holes ([`group_is_recoverable`]). For `m == 1` this is the original "no group
/// with >=2 holes, and any single-hole group has its (one) parity present" — byte-identical.
fn can_eventually_complete(fec: Option<&dyn FecScheme>, entry: &Pending) -> bool {
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        return entry.data.contains_key(&0);
    }
    let Some(g) = parity_group_size(fec, entry) else {
        // No FEC (or OFF tier): ANY missing data fragment is terminal once "old".
        return !(0..data_count).any(|i| !entry.data.contains_key(&(i as u16)));
    };
    let m = parity_count(fec, entry);
    let mut index = 0;
    let mut group_index = 0;
    while index < data_count {
        let upper = (index + g).min(data_count);
        let missing = (index..upper)
            .filter(|&i| !entry.data.contains_key(&(i as u16)))
            .count();
        if group_is_hopeless(missing, m) {
            return false;
        }
        if missing >= 1 {
            // The group's parity shards already held (its `m` slots at group_index*m + rank).
            let surviving = (0..m)
                .filter(|&rank| {
                    entry
                        .parity
                        .contains_key(&parity_index(group_index, rank, m))
                })
                .count();
            if !group_is_recoverable(missing, surviving, m) {
                return false;
            }
        }
        index += g;
        group_index += 1;
    }
    true
}

/// True when the only obstacle is FEC parity that has not yet arrived: every group with a
/// missing data fragment is still within its `m`-erasure budget but does not YET hold enough
/// surviving parity to repair it. Such a frame is not permanently hopeless — its late,
/// reordered parity could still complete it — so the sweep grants it the reorder grace.
///
/// m-aware: a group with `missing > m` is permanently hopeless ([`group_is_hopeless`]) → not
/// merely awaiting. A group already holding `surviving_parity >= missing`
/// ([`group_is_recoverable`]) is repairable NOW, not "awaiting". The frame is "awaiting" iff
/// at least one group is repairable-in-principle (`missing <= m`) but short of parity, and no
/// group is permanently hopeless. For `m == 1` this is the original "exactly one hole and its
/// single parity not yet ingested" — byte-identical.
fn awaiting_recoverable_parity(fec: Option<&dyn FecScheme>, entry: &Pending) -> bool {
    let Some(g) = parity_group_size(fec, entry) else {
        return false;
    };
    let data_count = resolved_data_count(fec, entry);
    if data_count == 0 {
        return false;
    }
    let m = parity_count(fec, entry);
    let mut index = 0;
    let mut group_index = 0;
    let mut saw_repairable_hole = false;
    while index < data_count {
        let upper = (index + g).min(data_count);
        let missing = (index..upper)
            .filter(|&i| !entry.data.contains_key(&(i as u16)))
            .count();
        if group_is_hopeless(missing, m) {
            return false; // beyond the m-erasure budget: permanently hopeless
        }
        if missing >= 1 {
            let surviving = (0..m)
                .filter(|&rank| {
                    entry
                        .parity
                        .contains_key(&parity_index(group_index, rank, m))
                })
                .count();
            if group_is_recoverable(missing, surviving, m) {
                return false; // enough parity already here → repairable now, not "awaiting"
            }
            saw_repairable_hole = true; // within budget but short of parity → awaiting more
        }
        index += g;
        group_index += 1;
    }
    saw_repairable_hole
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fec::XorParityFec;
    use crate::fragment::{PacketizeOptions, VideoPacketizer};

    fn keyframe_opts() -> PacketizeOptions {
        PacketizeOptions {
            keyframe: true,
            ..PacketizeOptions::default()
        }
    }

    #[test]
    fn whole_frame_completes_in_order() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![5u8; VideoPacketizer::MAX_PAYLOAD_SIZE + 100];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(None, 2);
        let mut completed = None;
        for f in frags {
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("frame should complete");
        assert_eq!(rf.avcc, frame);
        assert!(rf.keyframe);
        assert!(!rf.recovered_via_fec);
    }

    #[test]
    fn fec_recovers_single_dropped_fragment() {
        let fec_host = XorParityFec::new(5);
        let mut p = VideoPacketizer::new(Some(Box::new(fec_host)));
        let frame = vec![3u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 2);
        let mut completed = None;
        for (i, f) in frags.into_iter().enumerate() {
            if i == 1 {
                continue; // drop one data fragment; parity in the same group recovers it
            }
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("FEC should recover the frame");
        assert_eq!(rf.avcc, frame);
        assert!(rf.recovered_via_fec);
    }

    #[test]
    fn unrecoverable_loss_drops_when_newer_frame_arrives() {
        // No FEC: losing a data fragment of frame 0 is terminal once frame 1 appears.
        let mut p = VideoPacketizer::new(None);
        let frame0 = vec![1u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 3];
        let frame1 = vec![2u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
        let f0 = p.packetize(&frame0, keyframe_opts());
        let f1 = p.packetize(&frame1, keyframe_opts());

        let mut r = FrameReassembler::new(None, 2);
        // ingest only fragments 0 and 2 of frame 0 (fragment 1 lost)
        r.ingest(f0[0].clone());
        r.ingest(f0[2].clone());
        // frame 1 arrives, advancing the frontier → frame 0 is hopeless
        r.ingest(f1[0].clone());
        assert_eq!(r.next_dropped_frame(), Some(0));
        assert_eq!(r.next_dropped_frame(), None);
    }

    #[test]
    fn stale_fragment_for_retired_frame_is_ignored() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![9u8; 10];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(None, 2);
        assert!(matches!(
            r.ingest(frags[0].clone()),
            ReassemblyResult::Completed(_)
        ));
        // re-ingesting the same (now retired) frame's fragment is stale
        assert_eq!(r.ingest(frags[0].clone()), ReassemblyResult::Stale);
    }

    #[test]
    fn hostile_fragcount_rejected() {
        let mut frag = {
            let mut p = VideoPacketizer::new(None);
            p.packetize(&[1, 2, 3], keyframe_opts())[0].clone()
        };
        frag.header.frag_count = (FrameReassembler::MAX_FRAGMENTS_PER_FRAME + 1) as u16;
        let mut r = FrameReassembler::new(None, 2);
        assert_eq!(r.ingest(frag), ReassemblyResult::Stale);
    }

    // ----- pure m-aware receive-path helpers -----------------------------------------------

    /// The pre-existing single-parity (`m == 1`) boundary inversion the reassembler used
    /// BEFORE it became m-aware: `frag_count = data + ceil(data/g)`, descending scan, returns
    /// `total` when `group_size < 1` OR no data count solves it. The m-aware
    /// [`invert_data_count`] with `m == 1` (plus the `.unwrap_or(total)` the call sites apply)
    /// MUST reproduce this exactly — the byte-identity anchor for today's wire.
    fn legacy_inverted_data_count(total: usize, group_size: usize) -> usize {
        if group_size < 1 {
            return total;
        }
        let mut d = total;
        while d > 0 {
            let parity = d.div_ceil(group_size);
            if d + parity == total {
                return d;
            }
            if d + parity < total {
                break;
            }
            d -= 1;
        }
        total
    }

    #[test]
    fn invert_data_count_m1_matches_pre_existing_inversion() {
        // Across a WIDE range of (frag_count, group_size), the m-aware solver at m == 1 (with
        // the call-site total-fallback) equals the original inversion byte-for-byte — the
        // m == 1 == today guarantee for the data/parity boundary.
        for g in 1..=20usize {
            for total in 0..=400usize {
                let got = invert_data_count(total, g, 1).unwrap_or(total);
                assert_eq!(
                    got,
                    legacy_inverted_data_count(total, g),
                    "m=1 inversion mismatch total={total} g={g}"
                );
            }
        }
        // group_size 0 (defensive): None → call-site fallback to total, like the legacy guard.
        for total in 0..=8usize {
            assert_eq!(invert_data_count(total, 0, 1), None);
            assert_eq!(legacy_inverted_data_count(total, 0), total);
        }
    }

    #[test]
    fn invert_data_count_round_trips_forward_for_m1_m2_m3() {
        // For every (g, m, data), the forward shape frag_count = data + m*ceil(data/g) MUST
        // invert back to `data` exactly. This is the load-bearing generalization.
        for m in 1..=3usize {
            for g in 1..=12usize {
                for data in 1..=200usize {
                    let frag_count = data + m * data.div_ceil(g);
                    assert_eq!(
                        invert_data_count(frag_count, g, m),
                        Some(data),
                        "round-trip failed m={m} g={g} data={data} frag_count={frag_count}"
                    );
                }
                // data == 0 ⇒ zero parity ⇒ frag_count 0.
                assert_eq!(invert_data_count(0, g, m), Some(0), "zero-data m={m} g={g}");
            }
        }
    }

    #[test]
    fn invert_data_count_none_when_no_solution() {
        // A frag_count shaped for a different m has no solution for the wrong m.
        // data=10, g=5, m=2 ⇒ frag_count = 10 + 2*2 = 14. Solving 14 with m=1 has no answer:
        //   d + ceil(d/5) == 14 ⇒ d=12→12+3=15, d=11→11+3=14? 11+ceil(11/5)=11+3=14 ✓ — that
        // DOES solve, so pick a genuinely-unsolvable one: m=3, g=4. frag_count=2 has no d>=1
        // (d=1 ⇒ 1+3=4; d=0⇒0) and d=0 needs frag_count 0.
        assert_eq!(invert_data_count(2, 4, 3), None);
        assert_eq!(invert_data_count(3, 4, 3), None);
        // m or group_size below 1 ⇒ None (defensive).
        assert_eq!(invert_data_count(10, 0, 1), None);
        assert_eq!(invert_data_count(10, 5, 0), None);
    }

    #[test]
    fn group_is_hopeless_is_missing_greater_than_m() {
        for m in 1..=4usize {
            for missing in 0..=8usize {
                assert_eq!(
                    group_is_hopeless(missing, m),
                    missing > m,
                    "hopeless m={m} missing={missing}"
                );
            }
        }
        // m == 1 special-case: the original `missing >= 2` test.
        assert!(!group_is_hopeless(0, 1));
        assert!(!group_is_hopeless(1, 1));
        assert!(group_is_hopeless(2, 1));
    }

    #[test]
    fn parity_index_is_group_major_then_rank() {
        // m == 1 collapses to the group index (the v1 layout).
        for group in 0..5usize {
            assert_eq!(parity_index(group, 0, 1), group);
        }
        // m >= 2: group-major then rank.
        assert_eq!(parity_index(0, 0, 3), 0);
        assert_eq!(parity_index(0, 1, 3), 1);
        assert_eq!(parity_index(0, 2, 3), 2);
        assert_eq!(parity_index(1, 0, 3), 3);
        assert_eq!(parity_index(2, 1, 3), 7);
        // Every (group, rank) for m in 1..=3 maps to a unique, contiguous slot.
        for m in 1..=3usize {
            let mut expected = 0;
            for group in 0..4usize {
                for rank in 0..m {
                    assert_eq!(parity_index(group, rank, m), expected, "m={m}");
                    expected += 1;
                }
            }
        }
    }

    #[test]
    fn group_is_recoverable_needs_budget_and_enough_surviving_parity() {
        for m in 1..=3usize {
            for missing in 0..=m + 2 {
                for surviving in 0..=m {
                    let want = missing >= 1 && missing <= m && surviving >= missing;
                    assert_eq!(
                        group_is_recoverable(missing, surviving, m),
                        want,
                        "recoverable m={m} missing={missing} surviving={surviving}"
                    );
                }
            }
        }
        // m == 1: recoverable iff exactly one hole AND its single parity survived.
        assert!(!group_is_recoverable(0, 1, 1)); // no hole
        assert!(group_is_recoverable(1, 1, 1)); // one hole, parity present
        assert!(!group_is_recoverable(1, 0, 1)); // one hole, parity lost
        assert!(!group_is_recoverable(2, 1, 1)); // two holes > budget
    }

    // ----- m > 1 reachability through the EXISTING code path (test-only m=3 codec) ----------
    //
    // The production codec is m == 1, so adaptive_fec::parity_count maps every tier to m == 1
    // and nothing changes on the wire today. A test that wires an m > 1 ReedSolomonFec proves
    // the reassembler's m-awareness end-to-end WITHOUT touching the live tier→m table.

    #[test]
    fn rs_m3_reassembler_recovers_up_to_three_losses_per_group() {
        use crate::fec::ReedSolomonFec;
        // k=4 data + m=3 parity per group. default_m = parity_count_per_group() = 3, and
        // tier 0 → parity_count(0, 3) = 3, so the reassembler expects m=3 for this frame.
        let mut p = VideoPacketizer::new(Some(Box::new(ReedSolomonFec::new(4, 3))));
        // 4 data fragments ⇒ exactly one group of k=4 + 3 parity = 7 fragments.
        let frame = vec![7u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
        let frags = p.packetize(&frame, keyframe_opts());
        assert_eq!(frags.len(), 7, "4 data + 3 parity");

        // Drop THREE distinct data fragments (== m); RS must recover all three.
        let mut r = FrameReassembler::new(Some(Box::new(ReedSolomonFec::new(4, 3))), 4);
        let mut completed = None;
        for (i, f) in frags.into_iter().enumerate() {
            if i == 0 || i == 1 || i == 2 {
                continue; // three data holes in the single group (within the m=3 budget)
            }
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("RS m=3 should recover three losses in one group");
        assert_eq!(rf.avcc, frame);
        assert!(rf.recovered_via_fec);
    }

    #[test]
    fn rs_m3_reassembler_drops_when_losses_exceed_budget() {
        use crate::fec::ReedSolomonFec;
        // Same m=3 codec, but lose FOUR data fragments in the one group (> m=3) AND advance the
        // frontier with a newer frame so the hopeless sweep fires → the frame is dropped.
        let mut p = VideoPacketizer::new(Some(Box::new(ReedSolomonFec::new(5, 3))));
        let frame0 = vec![1u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5]; // one group of 5 + 3 parity
        let frame1 = vec![2u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
        let f0 = p.packetize(&frame0, keyframe_opts());
        let f1 = p.packetize(&frame1, keyframe_opts());

        let mut r = FrameReassembler::new(Some(Box::new(ReedSolomonFec::new(5, 3))), 0);
        // Deliver only data fragment 4 + all parity of frame 0 (drop data 0..3 = four holes > m).
        r.ingest(f0[4].clone());
        for f in &f0[5..] {
            r.ingest(f.clone());
        }
        // A newer frame advances the frontier → frame 0 swept as hopeless.
        r.ingest(f1[0].clone());
        assert_eq!(r.next_dropped_frame(), Some(0));
        assert_eq!(r.next_dropped_frame(), None);
    }

    // ----- ADAPTIVE-m: per-frame m signalled via the tier (tiers 5/6/7) -----------------------

    #[test]
    fn adaptive_m_tier_recovers_at_per_frame_m_beyond_codec_m() {
        use crate::adaptive_fec::{PARITY_TIER_BURST, PARITY_TIER_CLEAN};
        use crate::fec::ReedSolomonFec;
        // Production WAN codec: k=5, configured m=3 (FEC_M=3). The host escalates a frame to the
        // BURST tier (7 → m=5), so the packetizer emits 5 parity per group — MORE than the codec's
        // configured m — and the reassembler derives m=5 from the same tier. The m signalling rides
        // the existing 3-bit tier field: no wire-format change.
        let burst_opts = PacketizeOptions {
            keyframe: true,
            fec_tier: PARITY_TIER_BURST,
            ..PacketizeOptions::default()
        };
        let mut p = VideoPacketizer::new(Some(Box::new(ReedSolomonFec::new(5, 3))));
        let frame = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5]; // one group of k=5
        let frags = p.packetize(&frame, burst_opts);
        assert_eq!(
            frags.len(),
            10,
            "5 data + 5 parity (m=5 from the BURST tier)"
        );

        // Lose FIVE data fragments in the single group (== the per-frame m=5, but > the codec's
        // configured m=3) → RS recovers all five from the 5 parity shards.
        let mut r = FrameReassembler::new(Some(Box::new(ReedSolomonFec::new(5, 3))), 8);
        let mut completed = None;
        for (i, f) in frags.into_iter().enumerate() {
            if i < 5 {
                continue; // drop all five data fragments
            }
            if let ReassemblyResult::Completed(rf) = r.ingest(f) {
                completed = Some(rf);
            }
        }
        let rf = completed.expect("BURST tier m=5 recovers five losses in one group");
        assert_eq!(rf.avcc, frame);
        assert!(rf.recovered_via_fec);

        // CLEAN tier (5 → m=2): the SAME codec emits only 2 parity per group (less overhead on a
        // clean link), and the reassembler recovers within that smaller m=2 budget.
        let clean_opts = PacketizeOptions {
            keyframe: true,
            fec_tier: PARITY_TIER_CLEAN,
            ..PacketizeOptions::default()
        };
        let mut p2 = VideoPacketizer::new(Some(Box::new(ReedSolomonFec::new(5, 3))));
        let frags2 = p2.packetize(&frame, clean_opts);
        assert_eq!(
            frags2.len(),
            7,
            "5 data + 2 parity (m=2 from the CLEAN tier)"
        );
        let mut r2 = FrameReassembler::new(Some(Box::new(ReedSolomonFec::new(5, 3))), 8);
        let mut done2 = None;
        for (i, f) in frags2.into_iter().enumerate() {
            if i == 0 || i == 1 {
                continue; // 2 data holes, within the m=2 budget
            }
            if let ReassemblyResult::Completed(rf) = r2.ingest(f) {
                done2 = Some(rf);
            }
        }
        assert_eq!(
            done2.expect("CLEAN tier m=2 recovers two losses").avcc,
            frame
        );
    }

    #[test]
    fn precheck_completes_via_fec_exactly_when_parity_present() {
        use crate::fec::XorParityFec;
        // Discriminating test for the try_complete completeness precheck: a frame with a data
        // hole must stay Incomplete on every ingest UNTIL the parity that recovers it arrives,
        // then complete via FEC. If the precheck gated wrongly (false when recoverable) the
        // final completion would never fire; if it never gated, the outcome is unchanged but the
        // earlier ingests would do wasted clone+recover work (not observable here — outcome is).
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(5))));
        let frame = vec![3u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5]; // one group of 5 + 1 parity
        let frags = p.packetize(&frame, keyframe_opts());
        assert_eq!(frags.len(), 6, "5 data + 1 XOR parity");
        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 4);
        // Deliver the 4 surviving data fragments (drop index 2): a hole with no parity yet →
        // not recoverable → Incomplete each time (precheck returns false, no premature complete).
        for i in [0usize, 1, 3, 4] {
            assert!(
                matches!(r.ingest(frags[i].clone()), ReassemblyResult::Incomplete),
                "data-only with an open hole must stay Incomplete"
            );
        }
        // The parity (sent last) makes the single hole recoverable → completes via FEC NOW.
        match r.ingest(frags[5].clone()) {
            ReassemblyResult::Completed(f) => {
                assert_eq!(f.avcc, frame, "FEC-recovered bytes match the original");
                assert!(f.recovered_via_fec);
            }
            other => panic!("expected Completed via FEC once parity arrived, got {other:?}"),
        }
    }

    // ----- NACK / selective ARQ: retransmit-grace hold + needs-retransmit signal ---------------

    #[test]
    fn retransmit_holds_frame_emits_nack_once_then_completes() {
        use crate::fec::XorParityFec;
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(5))));
        let frame = vec![5u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5]; // 5 data + 1 XOR parity
        let frags = p.packetize(&frame, keyframe_opts());
        let frame1 = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
        let f1 = p.packetize(&frame1, keyframe_opts()); // advances the frontier

        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 4);
        r.enable_retransmit(8, 8);
        // Deliver frame-0 data 0,2,4 + parity — drop data 1 AND 3 (2 holes; m=1 can't recover both).
        for i in [0usize, 2, 4, 5] {
            assert!(matches!(
                r.ingest(frags[i].clone()),
                ReassemblyResult::Incomplete
            ));
        }
        // A newer frame advances the frontier → sweep runs → frame 0 is FEC-unrecoverable but HELD.
        r.ingest(f1[0].clone());
        assert_eq!(
            r.next_dropped_frame(),
            None,
            "held for retransmit, not dropped"
        );
        let (fid, missing) = r.next_needs_retransmit().expect("a NACK should be queued");
        assert_eq!(fid, 0);
        assert_eq!(missing, vec![1u16, 3u16], "the two missing DATA fragments");
        assert_eq!(r.next_needs_retransmit(), None, "NACK emitted exactly once");
        // The host retransmits a missing DATA fragment → with the parity, FEC fills the other hole
        // → the HELD frame completes (it was never retired, so the retransmit is not stale).
        match r.ingest(frags[1].clone()) {
            ReassemblyResult::Completed(rf) => assert_eq!(rf.avcc, frame),
            other => panic!("retransmitted fragment should complete the held frame, got {other:?}"),
        }
    }

    #[test]
    fn retransmit_grace_expiry_drops_as_fallback() {
        use crate::fec::XorParityFec;
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(5))));
        let frame = vec![5u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 2);
        r.enable_retransmit(3, 8); // small window
        for i in [0usize, 2, 4, 5] {
            r.ingest(frags[i].clone()); // 2 holes → FEC-unrecoverable
        }
        // Advance the frontier past the retransmit grace → frame 0 ages out and Drops (the
        // LTR-refresh fallback path fires on Dropped).
        for k in 1u8..=5 {
            let fk = p.packetize(&vec![k; VideoPacketizer::MAX_PAYLOAD_SIZE], keyframe_opts());
            r.ingest(fk[0].clone());
        }
        assert!(
            r.next_needs_retransmit().is_some(),
            "NACKed once while within the grace window"
        );
        assert_eq!(
            r.next_dropped_frame(),
            Some(0),
            "dropped once the retransmit grace elapses"
        );
    }

    #[test]
    fn big_loss_is_not_nacked_only_small_losses_are() {
        use crate::fec::XorParityFec;
        // max_frags = 2: a loss bigger than 2 fragments is NOT NACKed (re-sending a stale big frame
        // into a burst is wasteful → let it Drop → LTR-refresh skip-to-current). One group of k=5.
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(5))));
        let frame = vec![5u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 5];
        let frags = p.packetize(&frame, keyframe_opts());
        let mut r = FrameReassembler::new(Some(Box::new(XorParityFec::new(5))), 4);
        r.enable_retransmit(8, 2); // NACK only losses of ≤ 2 fragments
        // Deliver only data 4 + parity → 4 data holes (0,1,2,3) > max_frags=2.
        for i in [4usize, 5] {
            r.ingest(frags[i].clone());
        }
        // A SINGLE newer frame advances the frontier (age 1, WELL within the rgrace=8 window). A
        // big loss must NOT be held for the retransmit grace — it drops PROMPTLY to the LTR-refresh
        // fallback (holding it with no retransmit coming would stall the in-order client).
        let f1 = p.packetize(
            &vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE],
            keyframe_opts(),
        );
        r.ingest(f1[0].clone());
        assert!(
            r.next_needs_retransmit().is_none(),
            "a >max_frags loss must NOT be NACKed (it skips to the LTR-refresh fallback)"
        );
        assert_eq!(
            r.next_dropped_frame(),
            Some(0),
            "the big loss drops PROMPTLY (age 1, not held for the retransmit grace)"
        );
    }
}
