//! Pure refcount + channel→window bookkeeping for the window-parking manager.
//!
//! The canonical `WindowParkingLedger` logic; the native Swift shell keeps a copy
//! (`Sources/AislopdeskVideoHost/WindowParkingLedger.swift`, macOS feature #1) that tracks this.
//!
//! NO AX, NO IPC, NO geometry math — only the DECISIONS: when to AX-move a window onto the
//! virtual display (first park), when to REUSE an already-parked window (another lane, or a
//! hello retransmit), and which window to RESTORE when its last lane releases it. `VideoRect`/
//! `VideoSize` are carried verbatim as opaque data; this module never inspects or transforms
//! their geometry.
//!
//! Register `pub mod window_parking_ledger;` in `lib.rs` (alphabetical, after `video_control`,
//! before `window_geometry`). The Swift shell copy is internal + `macOS`-only; this core is
//! unconditional (the platform `#if os(macOS)` guard is irrelevant to a portable crate).

use crate::geometry::{VideoRect, VideoSize};
use std::collections::BTreeMap;

/// A `CGWindowID` (Swift `UInt32`).
pub type WindowId = u32;
/// A mux/lane channel id (Swift `UInt32`).
pub type ChannelId = u32;
/// A `pid_t` (Swift `Int32`).
pub type Pid = i32;

/// A window parked on the VD: the frame to restore to, the achieved on-VD size to capture at,
/// and how many lanes currently hold it. The Swift shell's `Parked` mirrors this (value type → `Copy`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Parked {
    /// Owning process (`pid_t`).
    pub pid: Pid,
    /// Original `CGRect` frame to AX-restore to. Stored verbatim (no standardization).
    pub original_frame: VideoRect,
    /// Achieved on-VD `CGSize` to capture at. Stored verbatim.
    pub achieved_size: VideoSize,
    /// Swift `Int` refcount → `i64` (matches Swift `Int` width; never realistically overflows).
    pub refcount: i64,
}

/// A window that must be AX-restored (its last lane released it, or a drain). The Swift shell's
/// `RestoreTarget` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RestoreTarget {
    /// The `CGWindowID` to restore.
    pub window_id: WindowId,
    /// Owning process (`pid_t`).
    pub pid: Pid,
    /// Original `CGRect` frame to AX-restore to. Stored verbatim.
    pub original_frame: VideoRect,
}

/// The outcome of a [`park`](WindowParkingLedger::park) request. The Swift shell's `ParkDecision` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ParkDecision {
    /// Already parked — refcount bumped (or unchanged for a same-lane retransmit); the caller
    /// just captures at this `CGSize`, no AX move.
    Reuse(VideoSize),
    /// First park of this window — caller AX-moves it, then commits via
    /// [`record_move`](WindowParkingLedger::record_move).
    NeedsMove,
}

/// Pure refcount ledger. `Default` gives the empty ledger (Swift's `= [:]` field initializers).
///
/// `BTreeMap<u32,_>` (not `HashMap`): the lookup/insert/remove/equality LOGIC is identical to a
/// Swift `Dictionary`, but `BTreeMap` gives this core a DETERMINISTIC (sorted-by-key)
/// [`drain_all`](Self::drain_all) order across runs (a `HashMap` with `RandomState` would
/// randomize it, breaking reproducible unit tests). See [`drain_all`](Self::drain_all) for the
/// cross-language ordering caveat.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WindowParkingLedger {
    parked: BTreeMap<WindowId, Parked>,
    channel_window: BTreeMap<ChannelId, WindowId>,
}

impl WindowParkingLedger {
    /// The empty ledger.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Read-only view of the parked map (the Swift shell exposes this as `private(set) var parked`).
    #[must_use]
    pub const fn parked(&self) -> &BTreeMap<WindowId, Parked> {
        &self.parked
    }

    /// Read-only view of the channel→window bindings (the Swift shell exposes this as `private(set) var channelWindow`).
    #[must_use]
    pub const fn channel_window(&self) -> &BTreeMap<ChannelId, WindowId> {
        &self.channel_window
    }

    /// Decide a park request, applying refcount bookkeeping for the REUSE cases. A fresh window
    /// returns [`NeedsMove`](ParkDecision::NeedsMove) and DOES NOT mutate state (a failed AX move
    /// thus leaves no orphan).
    #[must_use]
    pub fn park(&mut self, channel_id: ChannelId, window_id: WindowId) -> ParkDecision {
        // 1) Same lane re-parking the same window (hello retransmit / re-mint) — never double-count.
        //    Requires BOTH the binding to match AND the window to still be parked.
        if self.channel_window.get(&channel_id) == Some(&window_id) {
            if let Some(p) = self.parked.get(&window_id) {
                return ParkDecision::Reuse(p.achieved_size);
            }
        }
        // 2) Another lane already parked this window — share it (one move, refcounted restore).
        if let Some(p) = self.parked.get_mut(&window_id) {
            p.refcount += 1;
            let size = p.achieved_size;
            self.channel_window.insert(channel_id, window_id);
            return ParkDecision::Reuse(size);
        }
        // 3) Fresh window.
        ParkDecision::NeedsMove
    }

    /// Commit a successful first move (after [`park`](Self::park) returned
    /// [`NeedsMove`](ParkDecision::NeedsMove)). NOTE: this is a plain dictionary assignment — it
    /// OVERWRITES any existing `parked[window_id]`, RESETTING refcount to 1 (it does NOT
    /// accumulate). The Swift shell matches this exactly.
    pub fn record_move(
        &mut self,
        channel_id: ChannelId,
        window_id: WindowId,
        pid: Pid,
        original_frame: VideoRect,
        achieved_size: VideoSize,
    ) {
        self.parked.insert(
            window_id,
            Parked {
                pid,
                original_frame,
                achieved_size,
                refcount: 1,
            },
        );
        self.channel_window.insert(channel_id, window_id);
    }

    /// Release `channel_id`'s hold; returns the window to RESTORE iff its last lane just released
    /// it. The channel binding is removed UNCONDITIONALLY FIRST (Swift `removeValue` in the guard
    /// head), THEN `parked` is consulted — so an unknown channel, or a channel whose window is no
    /// longer parked, both return `None` with the binding already gone. Idempotent.
    #[must_use]
    pub fn unpark(&mut self, channel_id: ChannelId) -> Option<RestoreTarget> {
        let window_id = self.channel_window.remove(&channel_id)?; // unconditional removal first
        let p = self.parked.get_mut(&window_id)?; // missing → None (binding already removed)
        p.refcount -= 1;
        if p.refcount <= 0 {
            // `<= 0` defensive; the Swift shell uses the same guard; NLL ends the `p` borrow at the condition above.
            let removed = self.parked.remove(&window_id)?;
            Some(RestoreTarget {
                window_id,
                pid: removed.pid,
                original_frame: removed.original_frame,
            })
        } else {
            None
        }
    }

    /// Drain ALL parked windows (shutdown / VD termination): one [`RestoreTarget`] per DISTINCT
    /// parked window (a window held by N lanes yields ONE target, not N), then clears both maps.
    /// Idempotent (a second drain returns `vec![]`).
    ///
    /// ORDER CAVEAT: The Swift shell returns these in `Dictionary`'s unspecified (hash-seed-randomized)
    /// order; this core (`BTreeMap`) returns them sorted ascending by `window_id`. NEITHER order is
    /// load-bearing (the caller AX-restores each independently), so the golden-parity test MUST
    /// compare the two as a set / sorted-by-`window_id` projection, never positionally.
    #[must_use]
    pub fn drain_all(&mut self) -> Vec<RestoreTarget> {
        let targets: Vec<RestoreTarget> = self
            .parked
            .iter()
            .map(|(&window_id, p)| RestoreTarget {
                window_id,
                pid: p.pid,
                original_frame: p.original_frame,
            })
            .collect();
        self.parked.clear();
        self.channel_window.clear();
        targets
    }

    /// Number of DISTINCT windows currently parked (Swift `parked.count`; channel count is
    /// irrelevant). Swift `Int` → `usize` via `.len()`.
    #[must_use]
    pub fn parked_count(&self) -> usize {
        self.parked.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::{VideoRect, VideoSize};

    // ---- Test fixtures (the Swift `WindowParkingLedgerTests` suite uses the same values) ----
    fn frame_a() -> VideoRect {
        VideoRect::xywh(100.0, 200.0, 1600.0, 1000.0)
    }
    fn size_a() -> VideoSize {
        VideoSize::new(1600.0, 1000.0)
    }

    // Assert two VideoRects are bit-for-bit equal (no float blur in the carry-through proof).
    fn assert_rect_bits(a: VideoRect, b: VideoRect) {
        assert_eq!(a.origin.x.to_bits(), b.origin.x.to_bits(), "origin.x bits");
        assert_eq!(a.origin.y.to_bits(), b.origin.y.to_bits(), "origin.y bits");
        assert_eq!(
            a.size.width.to_bits(),
            b.size.width.to_bits(),
            "size.width bits"
        );
        assert_eq!(
            a.size.height.to_bits(),
            b.size.height.to_bits(),
            "size.height bits"
        );
    }

    fn assert_size_bits(a: VideoSize, b: VideoSize) {
        assert_eq!(a.width.to_bits(), b.width.to_bits(), "width bits");
        assert_eq!(a.height.to_bits(), b.height.to_bits(), "height bits");
    }

    // ===== Core behavior cases (the Swift `WindowParkingLedgerTests` XCTest suite cross-checks the same) =====

    // First park of a window → needsMove; after recordMove it is counted.
    #[test]
    fn first_park_needs_move_then_recorded() {
        let mut l = WindowParkingLedger::new();
        assert_eq!(l.park(1, 42), ParkDecision::NeedsMove);
        assert_eq!(
            l.parked_count(),
            0,
            "needsMove alone does not record (the AX move may still fail)"
        );
        l.record_move(1, 42, 7, frame_a(), size_a());
        assert_eq!(l.parked_count(), 1);
    }

    // A failed move (recordMove never called) leaves NO orphan record.
    #[test]
    fn failed_move_leaves_no_record() {
        let mut l = WindowParkingLedger::new();
        let _ = l.park(1, 42); // NeedsMove, caller's AX move then "fails" → no record_move
        assert_eq!(l.parked_count(), 0);
        assert_eq!(
            l.unpark(1),
            None,
            "an un-recorded channel has nothing to restore"
        );
    }

    // Same lane re-parking the same window (hello retransmit) reuses WITHOUT bumping the refcount.
    #[test]
    fn retransmit_does_not_double_count() {
        let mut l = WindowParkingLedger::new();
        let _ = l.park(1, 42);
        l.record_move(1, 42, 7, frame_a(), size_a());
        assert_eq!(l.park(1, 42), ParkDecision::Reuse(size_a()));
        // One unpark fully releases (refcount stayed 1 despite the retransmit) → restore target.
        let t = l.unpark(1);
        assert_eq!(
            t,
            Some(RestoreTarget {
                window_id: 42,
                pid: 7,
                original_frame: frame_a(),
            })
        );
        assert_eq!(l.parked_count(), 0);
    }

    // Two lanes naming the SAME window: moved once, restored once (last release).
    #[test]
    fn two_lanes_share_one_window() {
        let mut l = WindowParkingLedger::new();
        let _ = l.park(1, 42);
        l.record_move(1, 42, 7, frame_a(), size_a());
        assert_eq!(
            l.park(2, 42),
            ParkDecision::Reuse(size_a()),
            "second lane reuses, no move"
        );
        assert_eq!(l.parked_count(), 1);
        // First lane releasing does NOT restore (still held by lane 2).
        assert_eq!(l.unpark(1), None);
        assert_eq!(l.parked_count(), 1);
        // Last lane releasing restores.
        assert_eq!(l.unpark(2).map(|t| t.window_id), Some(42));
        assert_eq!(l.parked_count(), 0);
    }

    // Double-unpark of one channel restores exactly ONCE (idempotent).
    #[test]
    fn double_unpark_restores_once() {
        let mut l = WindowParkingLedger::new();
        let _ = l.park(1, 42);
        l.record_move(1, 42, 7, frame_a(), size_a());
        assert!(l.unpark(1).is_some(), "first unpark restores");
        assert!(l.unpark(1).is_none(), "second unpark is a no-op");
        assert_eq!(l.parked_count(), 0);
    }

    // unpark of an unknown channel is a harmless no-op.
    #[test]
    fn unpark_unknown_channel() {
        let mut l = WindowParkingLedger::new();
        assert_eq!(l.unpark(99), None);
    }

    // drainAll returns every parked window once and clears state; a second drain is empty.
    #[test]
    fn drain_all() {
        let mut l = WindowParkingLedger::new();
        let _ = l.park(1, 42);
        l.record_move(1, 42, 7, frame_a(), size_a());
        let _ = l.park(2, 43);
        l.record_move(
            2,
            43,
            8,
            VideoRect::xywh(0.0, 0.0, 800.0, 600.0),
            VideoSize::new(800.0, 600.0),
        );
        let drained = l.drain_all();
        let ids: std::collections::BTreeSet<WindowId> =
            drained.iter().map(|t| t.window_id).collect();
        let expected: std::collections::BTreeSet<WindowId> = [42, 43].into_iter().collect();
        assert_eq!(ids, expected);
        assert_eq!(l.parked_count(), 0);
        assert!(l.drain_all().is_empty(), "second drain is empty");
        assert_eq!(l.unpark(1), None, "channel bindings cleared by drain");
    }

    // ===== Edge cases enumerated in the spec =====

    // Fresh park leaves BOTH maps untouched (no orphan after a failed AX move).
    #[test]
    fn fresh_park_mutates_nothing() {
        let mut l = WindowParkingLedger::new();
        assert_eq!(l.park(1, 100), ParkDecision::NeedsMove);
        assert!(l.parked().is_empty());
        assert!(l.channel_window().is_empty());
        assert_eq!(l.parked_count(), 0);
    }

    // park(ch,w2) where channel_window[ch]==w1 (w1!=w2) and w2 not parked → NeedsMove, no change.
    #[test]
    fn channel_maps_elsewhere_no_change() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            3,
            VideoRect::xywh(5.0, 5.0, 200.0, 200.0),
            VideoSize::new(200.0, 200.0),
        );
        // Channel 1 is bound to window 100; ask it to park a DIFFERENT, unparked window 200.
        assert_eq!(l.park(1, 200), ParkDecision::NeedsMove);
        // No mutation: channel 1 still bound to 100, window 100 record intact, 200 not parked.
        assert_eq!(l.channel_window().get(&1), Some(&100));
        assert_eq!(l.parked_count(), 1);
        assert!(l.parked().get(&200).is_none());
        // And the original binding still reuses cleanly.
        assert_eq!(
            l.park(1, 100),
            ParkDecision::Reuse(VideoSize::new(200.0, 200.0))
        );
        assert_eq!(
            l.parked().get(&100).unwrap().refcount,
            1,
            "reuse same-lane did not bump"
        );
    }

    // Second lane sharing bumps refcount to 2 and binds ch2.
    #[test]
    fn second_lane_sharing_bumps_refcount() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            7,
            VideoRect::xywh(0.0, 0.0, 640.0, 480.0),
            VideoSize::new(640.0, 480.0),
        );
        assert_eq!(
            l.park(2, 100),
            ParkDecision::Reuse(VideoSize::new(640.0, 480.0))
        );
        assert_eq!(l.parked().get(&100).unwrap().refcount, 2);
        assert_eq!(l.channel_window().get(&2), Some(&100));
    }

    // record_move OVERWRITE: a second record_move resets refcount to 1 and replaces pid/frame/size.
    #[test]
    fn record_move_overwrites_and_resets_refcount() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(1.0, 2.0, 3.0, 4.0),
            VideoSize::new(30.0, 40.0),
        );
        let _ = l.park(2, 100); // share → refcount 2
        assert_eq!(l.parked().get(&100).unwrap().refcount, 2);
        // OVERWRITE with new pid/frame/size: refcount RESET to 1 (does not accumulate).
        l.record_move(
            1,
            100,
            2,
            VideoRect::xywh(9.0, 9.0, 9.0, 9.0),
            VideoSize::new(90.0, 90.0),
        );
        let p = *l.parked().get(&100).unwrap();
        assert_eq!(p.refcount, 1);
        assert_eq!(p.pid, 2);
        assert_rect_bits(p.original_frame, VideoRect::xywh(9.0, 9.0, 9.0, 9.0));
        assert_size_bits(p.achieved_size, VideoSize::new(90.0, 90.0));
    }

    // unpark removes the channel binding UNCONDITIONALLY before consulting parked: a known channel
    // whose window is no longer parked returns None but the stale binding IS removed.
    #[test]
    fn unpark_removes_binding_even_when_window_gone() {
        let mut l = WindowParkingLedger::new();
        // record_move(ch1,w); park(ch2,w) (rc=2); record_move(ch1,w) again (rc RESET to 1, two
        // channels still point at w); unpark(ch1) → restore (rc 1→0, w removed); unpark(ch2) →
        // channel_window[ch2]==w present but parked[w] gone → None, binding removed.
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(1.0, 2.0, 3.0, 4.0),
            VideoSize::new(30.0, 40.0),
        );
        let _ = l.park(2, 100); // rc 2, ch2 bound to 100
        l.record_move(
            1,
            100,
            2,
            VideoRect::xywh(9.0, 9.0, 9.0, 9.0),
            VideoSize::new(90.0, 90.0),
        ); // rc RESET to 1
        assert_eq!(
            l.channel_window().get(&2),
            Some(&100),
            "ch2 still bound after overwrite"
        );
        // unpark ch1 → rc 1→0, window 100 removed and restored.
        let t = l.unpark(1).expect("ch1 restores");
        assert_eq!(t.window_id, 100);
        assert_eq!(t.pid, 2);
        assert_rect_bits(t.original_frame, VideoRect::xywh(9.0, 9.0, 9.0, 9.0));
        assert!(l.parked().get(&100).is_none());
        // unpark ch2: binding present, but parked[100] is gone → None AND the binding is removed.
        assert_eq!(l.unpark(2), None, "defensive missing-parked guard → None");
        assert!(
            l.channel_window().get(&2).is_none(),
            "stale binding removed"
        );
        assert_eq!(l.parked_count(), 0);
    }

    // First if-clause requires BOTH the binding match AND parked present: channel_window[ch]==w but
    // parked[w] absent → clause 1 fails, clause 2 also fails → NeedsMove, no mutation.
    #[test]
    fn park_with_binding_but_no_parked_record_needs_move() {
        let mut l = WindowParkingLedger::new();
        // Construct: ch2 bound to 100 with 100 NOT parked (via the overwrite+unpark path).
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(1.0, 2.0, 3.0, 4.0),
            VideoSize::new(30.0, 40.0),
        );
        let _ = l.park(2, 100);
        l.record_move(
            1,
            100,
            2,
            VideoRect::xywh(9.0, 9.0, 9.0, 9.0),
            VideoSize::new(90.0, 90.0),
        );
        let _ = l.unpark(1); // removes parked[100], leaves ch2→100 binding stale
        assert_eq!(l.channel_window().get(&2), Some(&100));
        assert!(l.parked().get(&100).is_none());
        // park(ch2,100): clause 1 (binding matches) BUT parked[100] absent → falls through to
        // clause 2 (also absent) → NeedsMove. The stale binding is left as-is (no mutation here).
        assert_eq!(l.park(2, 100), ParkDecision::NeedsMove);
        assert_eq!(
            l.channel_window().get(&2),
            Some(&100),
            "no mutation on NeedsMove"
        );
        assert_eq!(l.parked_count(), 0);
    }

    // unpark with refcount still > 0 updates the record and returns None (window stays parked).
    #[test]
    fn unpark_refcount_still_positive_returns_none() {
        let mut l = WindowParkingLedger::new();
        l.record_move(1, 100, 5, frame_a(), size_a());
        let _ = l.park(2, 100); // rc 2
        let _ = l.park(3, 100); // rc 3
        assert_eq!(l.unpark(1), None);
        assert_eq!(l.parked().get(&100).unwrap().refcount, 2);
        assert_eq!(l.unpark(2), None);
        assert_eq!(l.parked().get(&100).unwrap().refcount, 1);
        // Last lane → restore.
        assert!(l.unpark(3).is_some());
        assert_eq!(l.parked_count(), 0);
    }

    // drain_all returns ONE target per DISTINCT window (a window held by N lanes yields one), and
    // after drain channel_window is cleared so a follow-up park returns NeedsMove (not Reuse).
    #[test]
    fn drain_all_distinct_and_clears_channels() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(0.0, 0.0, 10.0, 10.0),
            VideoSize::new(10.0, 10.0),
        );
        let _ = l.park(3, 100); // w100 shared by ch1 & ch3, rc 2
        l.record_move(
            2,
            200,
            2,
            VideoRect::xywh(0.0, 0.0, 20.0, 20.0),
            VideoSize::new(20.0, 20.0),
        );
        assert_eq!(l.parked_count(), 2);
        let mut drained = l.drain_all();
        drained.sort_by_key(|t| t.window_id);
        assert_eq!(drained.len(), 2, "2 distinct windows, NOT 3 channels");
        assert_eq!(drained[0].window_id, 100);
        assert_eq!(drained[0].pid, 1);
        assert_rect_bits(
            drained[0].original_frame,
            VideoRect::xywh(0.0, 0.0, 10.0, 10.0),
        );
        assert_eq!(drained[1].window_id, 200);
        assert_eq!(drained[1].pid, 2);
        // Idempotent.
        assert!(l.drain_all().is_empty());
        assert_eq!(l.parked_count(), 0);
        // channel_window cleared → previously-shared window now NeedsMove, not Reuse.
        assert_eq!(l.park(1, 100), ParkDecision::NeedsMove);
    }

    // drain_all over multiple windows incl. a shared one → sorted distinct targets.
    #[test]
    fn drain_all_multi_with_shared() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(0.0, 0.0, 10.0, 10.0),
            VideoSize::new(10.0, 10.0),
        );
        let _ = l.park(4, 100); // w100 rc 2 via ch1 + ch4
        l.record_move(
            2,
            200,
            2,
            VideoRect::xywh(0.0, 0.0, 20.0, 20.0),
            VideoSize::new(20.0, 20.0),
        );
        l.record_move(
            3,
            300,
            3,
            VideoRect::xywh(0.0, 0.0, 30.0, 30.0),
            VideoSize::new(30.0, 30.0),
        );
        assert_eq!(l.parked_count(), 3);
        let drained = l.drain_all(); // BTreeMap → already sorted by window_id
        let ids: Vec<WindowId> = drained.iter().map(|t| t.window_id).collect();
        assert_eq!(ids, vec![100, 200, 300], "3 distinct windows, sorted");
        assert_eq!(l.parked_count(), 0);
    }

    // Empty ledger: park → NeedsMove, unpark → None, drain_all → [], parked_count == 0.
    #[test]
    fn empty_ledger_behaviour() {
        let mut l = WindowParkingLedger::new();
        assert_eq!(l.park(1, 1), ParkDecision::NeedsMove);
        // (park on empty mutates nothing for a fresh window — verify, then rebuild fresh.)
        let mut l = WindowParkingLedger::new();
        assert_eq!(l.unpark(1), None);
        assert!(l.drain_all().is_empty());
        assert_eq!(l.parked_count(), 0);
    }

    // Float carry-through: fractional / negative-origin / negative-size frames survive park-reuse,
    // unpark, and drain_all BIT-FOR-BIT (no standardization anywhere in this module).
    #[test]
    fn float_carry_through_bit_exact() {
        let mut l = WindowParkingLedger::new();
        let frame = VideoRect::xywh(100.5, -200.25, 800.75, 600.125);
        let size = VideoSize::new(1280.5, 800.25);
        l.record_move(1, 100, -5, frame, size);
        // park-reuse hands back the achieved size verbatim.
        match l.park(1, 100) {
            ParkDecision::Reuse(s) => assert_size_bits(s, size),
            ParkDecision::NeedsMove => panic!("expected Reuse, got NeedsMove"),
        }
        // unpark hands back the frame verbatim.
        let t = l.unpark(1).expect("restore");
        assert_eq!(t.pid, -5);
        assert_rect_bits(t.original_frame, frame);
    }

    // No standardization: a negative-size / zero-area frame is stored & returned verbatim — exactly
    // what CGRect Equatable compares (raw stored fields, NOT a standardized form).
    #[test]
    fn no_standardization_negative_and_zero() {
        let mut l = WindowParkingLedger::new();
        let frame = VideoRect::xywh(0.0, 0.0, -5.0, -7.0); // negative size
        let size = VideoSize::new(0.0, 0.0); // zero area
        l.record_move(1, 100, 0, frame, size);
        match l.park(1, 100) {
            ParkDecision::Reuse(s) => assert_size_bits(s, size),
            ParkDecision::NeedsMove => panic!("expected Reuse, got NeedsMove"),
        }
        let t = l.unpark(1).expect("restore");
        assert_rect_bits(t.original_frame, frame); // verbatim, no CGRect normalization
    }

    // parked_count counts DISTINCT windows, independent of how many channels hold them.
    #[test]
    fn parked_count_counts_distinct_windows() {
        let mut l = WindowParkingLedger::new();
        l.record_move(1, 100, 1, frame_a(), size_a());
        let _ = l.park(2, 100); // 2nd channel, same window
        let _ = l.park(3, 100); // 3rd channel, same window
        assert_eq!(l.parked_count(), 1, "3 channels, 1 distinct window");
        l.record_move(4, 200, 2, frame_a(), size_a());
        assert_eq!(l.parked_count(), 2);
    }

    // Full parity walk-through (spec CASE record_move_overwrite_and_missing_guard): exercises the
    // overwrite reset + the reachable defensive missing-parked guard end-to-end.
    #[test]
    fn parity_record_move_overwrite_and_missing_guard() {
        let mut l = WindowParkingLedger::new();
        l.record_move(
            1,
            100,
            1,
            VideoRect::xywh(1.0, 2.0, 3.0, 4.0),
            VideoSize::new(30.0, 40.0),
        );
        assert_eq!(
            l.park(2, 100),
            ParkDecision::Reuse(VideoSize::new(30.0, 40.0))
        ); // rc 2
        l.record_move(
            1,
            100,
            2,
            VideoRect::xywh(9.0, 9.0, 9.0, 9.0),
            VideoSize::new(90.0, 90.0),
        ); // OVERWRITE rc→1
        assert_eq!(
            l.park(1, 100),
            ParkDecision::Reuse(VideoSize::new(90.0, 90.0))
        );
        let t = l.unpark(1).expect("ch1 restores");
        assert_eq!(
            t,
            RestoreTarget {
                window_id: 100,
                pid: 2,
                original_frame: VideoRect::xywh(9.0, 9.0, 9.0, 9.0),
            }
        );
        assert_eq!(
            l.unpark(2),
            None,
            "ch2 binding present but parked[100] gone → None"
        );
        assert_eq!(l.parked_count(), 0);
    }
}
