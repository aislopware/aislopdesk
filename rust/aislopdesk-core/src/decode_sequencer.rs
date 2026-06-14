//! In-order decode admission — the canonical `DecodeSequencer` logic (the Swift shell mirrors it).
//!
//! The reassembler completes frames in arrival/recovery order, not frame-id order (frame N−1
//! waits for late parity while small frame N completes first). Feeding completion-order straight
//! to the decoder makes the out-of-order frame N reference a not-yet-decoded N−1 → `VideoToolbox`
//! -12909 → session teardown → forced IDR (~150 ms freeze) for a frame that was about to complete
//! anyway.
//!
//! This releases frames to the decoder strictly in frame-id order. A frame ahead of the
//! expectation is HELD (bounded); the gap closes when the missing frame completes or is declared
//! LOST. Keyframes bypass ordering (they reference nothing); held frames older than a keyframe are
//! obsolete and dropped. Overflow valves (`max_held` count, `max_gap` id-span) flush everything
//! held in ascending order rather than stalling the pane. Pure value type — wrap-aware
//! ([`distance_wrapped`](crate::seq::distance_wrapped)), no clock, no transport.

use crate::reassembler::ReassembledFrame;
use crate::seq::distance_wrapped;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

/// Default held-count overflow valve.
pub const DEFAULT_MAX_HELD: usize = 4;
/// Default id-span overflow valve.
pub const DEFAULT_MAX_GAP: usize = 6;

/// Releases reassembler completions to the decoder strictly in frame-id order.
#[derive(Debug, Clone)]
pub struct DecodeSequencer {
    next_expected: Option<u32>,
    held: HashMap<u32, ReassembledFrame>,
    lost_ahead: HashSet<u32>,
    max_held: usize,
    max_gap: usize,
}

impl Default for DecodeSequencer {
    /// The shipped overflow valves: hold ≤4 frames or ≤6 ids of span before flushing.
    fn default() -> Self {
        Self::new(DEFAULT_MAX_HELD, DEFAULT_MAX_GAP)
    }
}

impl DecodeSequencer {
    /// Builds a sequencer with the given overflow valves (each floored to 1).
    #[must_use]
    pub fn new(max_held: usize, max_gap: usize) -> Self {
        Self {
            next_expected: None,
            held: HashMap::new(),
            lost_ahead: HashSet::new(),
            max_held: max_held.max(1),
            max_gap: max_gap.max(1),
        }
    }

    /// The next frame id the decoder should see (`None` until the first release).
    #[must_use]
    pub const fn next_expected(&self) -> Option<u32> {
        self.next_expected
    }

    /// Folds one reassembler completion. Returns the frames now releasable to the decoder, in
    /// frame-id order (possibly empty — the frame was held; possibly several — it closed a gap).
    pub fn note_completed(&mut self, frame: ReassembledFrame) -> Vec<ReassembledFrame> {
        let frame_id = frame.frame_id;
        let keyframe = frame.keyframe;

        // First frame of the session anchors the expectation.
        let Some(expected) = self.next_expected else {
            self.next_expected = Some(frame_id.wrapping_add(1));
            return vec![frame];
        };

        if keyframe {
            // Keyframes reference nothing — release NOW. Held frames older than it are obsolete.
            if distance_wrapped(frame_id, expected) >= 0 {
                self.held.retain(|k, _| distance_wrapped(*k, frame_id) > 0);
                self.lost_ahead
                    .retain(|id| distance_wrapped(*id, frame_id) > 0);
                self.next_expected = Some(frame_id.wrapping_add(1));
                let mut out = vec![frame];
                out.extend(self.drain_contiguous());
                return out;
            }
            return vec![frame];
        }

        let dist = distance_wrapped(frame_id, expected);
        if dist < 0 {
            // Older than the expectation (late straggler): release immediately; never regress.
            return vec![frame];
        }
        if dist == 0 {
            self.next_expected = Some(expected.wrapping_add(1));
            let mut out = vec![frame];
            out.extend(self.drain_contiguous());
            return out;
        }
        // Ahead of a gap: hold, then check the overflow valves.
        self.held.insert(frame_id, frame);
        if self.held.len() > self.max_held || i64::from(dist) > self.max_gap as i64 {
            return self.flush_all();
        }
        Vec::new()
    }

    /// Folds one reassembler loss declaration: the hole at `frame_id` will never complete — skip
    /// it. Returns frames released by the gap closing (in order).
    pub fn note_lost(&mut self, frame_id: u32) -> Vec<ReassembledFrame> {
        let Some(expected) = self.next_expected else {
            return Vec::new();
        };
        let dist = distance_wrapped(frame_id, expected);
        if dist < 0 {
            return Vec::new(); // already behind the expectation
        }
        if dist == 0 {
            self.next_expected = Some(expected.wrapping_add(1));
            return self.drain_contiguous();
        }
        self.lost_ahead.insert(frame_id);
        // A loss can also trip the span valve (the gap is now known-unfillable up to it).
        if self.lost_ahead.len() + self.held.len() > self.max_held + self.max_gap {
            return self.flush_all();
        }
        Vec::new()
    }

    /// Releases the contiguous run now available at the expectation: held frames release,
    /// declared-lost ids are skipped, the first true hole stops the run.
    fn drain_contiguous(&mut self) -> Vec<ReassembledFrame> {
        let mut out = Vec::new();
        while let Some(expected) = self.next_expected {
            if let Some(f) = self.held.remove(&expected) {
                out.push(f);
                self.next_expected = Some(expected.wrapping_add(1));
            } else if self.lost_ahead.remove(&expected) {
                self.next_expected = Some(expected.wrapping_add(1));
            } else {
                break;
            }
        }
        out
    }

    /// Overflow valve: release EVERYTHING held in ascending frame-id order and jump the
    /// expectation past it all.
    fn flush_all(&mut self) -> Vec<ReassembledFrame> {
        let mut out: Vec<ReassembledFrame> = self.held.drain().map(|(_, v)| v).collect();
        out.sort_by(|a, b| {
            if distance_wrapped(a.frame_id, b.frame_id) < 0 {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        });
        if let Some(last) = out.last() {
            let past_held = last.frame_id.wrapping_add(1);
            let past_lost = self.newest_lost_ahead().map(|id| id.wrapping_add(1));
            if let Some(past_lost) = past_lost {
                if distance_wrapped(past_lost, past_held) > 0 {
                    self.next_expected = Some(past_lost);
                } else {
                    self.next_expected = Some(past_held);
                }
            } else {
                self.next_expected = Some(past_held);
            }
        } else if let Some(max_lost) = self.newest_lost_ahead() {
            self.next_expected = Some(max_lost.wrapping_add(1));
        }
        self.held.clear();
        self.lost_ahead.clear();
        out
    }

    /// The newest (wrap-aware) frame id in `lost_ahead`, if any.
    fn newest_lost_ahead(&self) -> Option<u32> {
        self.lost_ahead.iter().copied().max_by(|a, b| {
            if distance_wrapped(*a, *b) < 0 {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(id: u32, kf: bool) -> ReassembledFrame {
        ReassembledFrame {
            frame_id: id,
            keyframe: kf,
            crisp: false,
            avcc: vec![0x1],
            recovered_via_fec: false,
            is_ltr: false,
            acked_anchored: false,
        }
    }

    fn ids(frames: &[ReassembledFrame]) -> Vec<u32> {
        frames.iter().map(|f| f.frame_id).collect()
    }

    #[test]
    fn in_order_completions_release_immediately() {
        let mut sq = DecodeSequencer::default();
        assert_eq!(ids(&sq.note_completed(frame(10, true))), vec![10]);
        assert_eq!(ids(&sq.note_completed(frame(11, false))), vec![11]);
        assert_eq!(ids(&sq.note_completed(frame(12, false))), vec![12]);
        assert_eq!(sq.next_expected(), Some(13));
    }

    #[test]
    fn out_of_order_held_then_released_in_order() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(12, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(11, false))), vec![11, 12]);
        assert_eq!(sq.next_expected(), Some(13));
    }

    #[test]
    fn declared_loss_skips_the_hole() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(12, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(13, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_lost(11)), vec![12, 13]);
        assert_eq!(sq.next_expected(), Some(14));
    }

    #[test]
    fn loss_ahead_remembers_out_of_order_declarations() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_lost(12)), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(13, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_lost(11)), vec![13]);
        assert_eq!(sq.next_expected(), Some(14));
    }

    #[test]
    fn keyframe_bypasses_gap_and_drops_obsolete_held() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(12, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(20, true))), vec![20]);
        assert_eq!(sq.next_expected(), Some(21));
        assert_eq!(ids(&sq.note_completed(frame(21, false))), vec![21]);
    }

    #[test]
    fn keyframe_keeps_newer_held_frames() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(16, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(15, true))), vec![15, 16]);
        assert_eq!(sq.next_expected(), Some(17));
    }

    #[test]
    fn overflow_valve_flushes_in_order() {
        let mut sq = DecodeSequencer::new(2, 6);
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(13, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(12, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(14, false))), vec![12, 13, 14]);
        assert_eq!(sq.next_expected(), Some(15));
    }

    #[test]
    fn gap_span_valve_flushes() {
        let mut sq = DecodeSequencer::new(8, 3);
        let _ = sq.note_completed(frame(10, true));
        assert_eq!(ids(&sq.note_completed(frame(15, false))), vec![15]);
        assert_eq!(sq.next_expected(), Some(16));
    }

    #[test]
    fn late_straggler_releases_without_regressing_expectation() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        let _ = sq.note_completed(frame(11, false));
        assert_eq!(ids(&sq.note_completed(frame(9, false))), vec![9]);
        assert_eq!(sq.next_expected(), Some(12));
    }

    #[test]
    fn wrap_aware_ordering() {
        let mut sq = DecodeSequencer::default();
        let last = u32::MAX;
        let _ = sq.note_completed(frame(last - 1, true));
        assert_eq!(ids(&sq.note_completed(frame(0, false))), Vec::<u32>::new());
        assert_eq!(ids(&sq.note_completed(frame(last, false))), vec![last, 0]);
        assert_eq!(sq.next_expected(), Some(1));
    }

    #[test]
    fn lost_behind_expectation_is_no_op() {
        let mut sq = DecodeSequencer::default();
        let _ = sq.note_completed(frame(10, true));
        let _ = sq.note_completed(frame(11, false));
        assert_eq!(ids(&sq.note_lost(5)), Vec::<u32>::new());
        assert_eq!(sq.next_expected(), Some(12));
    }
}
