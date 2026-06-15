//! Pure, order-preserving pointer-motion coalescer (the input-latency fix).
//!
//! The canonical `InputMotionCoalescer` logic; the native Swift shell keeps a copy
//! (`AislopdeskVideoHost/VideoSessionLogic.swift`) that tracks this (golden parity).
//!
//! A remote pointer stream is ~99% motion: a real loopback trace was 1664 `mouseMove` +
//! 163 `mouseDrag` against only 11 `mouseDown` (≈150:1). The host injects every event
//! behind synchronous `WindowServer` IPC (`CGWarpMouseCursorPosition` +
//! `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`, three round-trips), so when
//! the serial inbound consumer falls behind a flood it replays every STALE intermediate
//! position in FIFO order — the cursor visibly crawls through old positions seconds behind
//! the user ("delay vài giây").
//!
//! This collapses each RUN of consecutive same-class motion events to its LATEST — the only
//! position that still matters, because a hover/drag target is absolute — while passing every
//! button / key / scroll / text event through UNCHANGED and NEVER reordering across one. It
//! is the same latest-position rule `TigerVNC` (`Viewport` deferred pointer flush) and noVNC
//! (`_handleMouseMove` + `_flushMouseMoveTimer`) use; here it is driven by drain-availability
//! (the actor batch-drains the inbound queue and coalesces what piled up) rather than a
//! wall-clock timer, so it is SELF-REGULATING: when the consumer keeps up the batches are
//! size ~1 and it is a no-op; only when it falls behind does a run collapse, bounding the lag
//! to roughly one injection regardless of flood. Pure ⇒ headlessly unit-testable beside the
//! sibling input deciders (no `CGEvent`, no socket).

use crate::input_event::InputEvent;

/// Pure, order-preserving pointer-motion coalescer. A stateless namespace (like the Swift
/// shell's `struct` with only `static` members); all behaviour lives in [`coalesce`](Self::coalesce).
#[derive(Debug, Clone, Copy, Default)]
pub struct InputMotionCoalescer;

/// The two coalescible motion classes. A hover-run and a drag-run NEVER merge: a class
/// change is a flush boundary, because a `.mouseDrag` carries a held button + clickState
/// the host posts as `*MouseDragged`, while a `.mouseMove` is a bare hover `*MouseMoved` —
/// collapsing across the boundary would drop the transition the target app needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MotionClass {
    /// A bare hover (`InputEvent::MouseMove`).
    Move,
    /// A drag with a held button (`InputEvent::MouseDrag`).
    Drag,
}

impl InputMotionCoalescer {
    /// The coalescible class of `event`, or `None` if it is a (barrier) non-motion event.
    const fn motion_class(event: &InputEvent) -> Option<MotionClass> {
        match event {
            InputEvent::MouseMove { .. } => Some(MotionClass::Move),
            InputEvent::MouseDrag { .. } => Some(MotionClass::Drag),
            InputEvent::MouseDown { .. }
            | InputEvent::MouseUp { .. }
            | InputEvent::Scroll { .. }
            | InputEvent::Key { .. }
            | InputEvent::Text { .. } => None,
        }
    }

    /// Collapse consecutive same-class motion runs in `batch` to their latest, preserving the
    /// relative order of every non-motion (barrier) event and of motion vs barriers.
    ///
    /// INVARIANT (the correctness the ordered consumer won must not regress): a
    /// `.mouseDown`/`.mouseUp`/`.key`/`.scroll`/`.text` is a hard barrier — any buffered motion
    /// flushes BEFORE it, so a move that physically preceded a click is never emitted after the
    /// click. That keeps down→drag→up framing, the button-balance bookkeeping, and the
    /// stateless-drag contract intact (every down/up still reaches the injector exactly once, in
    /// order).
    #[must_use]
    pub fn coalesce(batch: &[InputEvent]) -> Vec<InputEvent> {
        if batch.len() <= 1 {
            return batch.to_vec();
        }
        let mut output: Vec<InputEvent> = Vec::with_capacity(batch.len());
        let mut pending: Option<InputEvent> = None; // the latest buffered motion event in the current run
        let mut pending_class: Option<MotionClass> = None; // its class (None ⇔ pending is None)
        for event in batch {
            if let Some(cls) = Self::motion_class(event) {
                if Some(cls) == pending_class {
                    pending = Some(event.clone()); // same run: keep only the latest
                } else {
                    if let Some(p) = pending.take() {
                        output.push(p); // class change: flush the old run
                    }
                    pending = Some(event.clone());
                    pending_class = Some(cls);
                }
            } else {
                // Barrier: flush any buffered motion FIRST (order-preserving), then the barrier.
                if let Some(p) = pending.take() {
                    output.push(p);
                    pending_class = None;
                }
                output.push(event.clone());
            }
        }
        if let Some(p) = pending.take() {
            output.push(p); // trailing motion run
        }
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::VideoPoint;
    use crate::input_event::{InputModifiers, MouseButton};

    // --- event builders used by tests below (the Swift test helpers follow the same shape) ---
    // Distinct positions so we can assert WHICH motion survived (latest-wins). x == y == id.

    fn move_ev(id: f64) -> InputEvent {
        InputEvent::MouseMove {
            normalized: VideoPoint::new(id, id),
            tag: 0,
        }
    }

    fn drag(id: f64) -> InputEvent {
        drag_b(id, MouseButton::Left)
    }

    fn drag_b(id: f64, b: MouseButton) -> InputEvent {
        InputEvent::MouseDrag {
            button: b,
            normalized: VideoPoint::new(id, id),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn down() -> InputEvent {
        down_b(MouseButton::Left)
    }

    fn down_b(b: MouseButton) -> InputEvent {
        InputEvent::MouseDown {
            button: b,
            normalized: VideoPoint::new(0.0, 0.0),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn up() -> InputEvent {
        up_b(MouseButton::Left)
    }

    fn up_b(b: MouseButton) -> InputEvent {
        InputEvent::MouseUp {
            button: b,
            normalized: VideoPoint::new(0.0, 0.0),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn scroll(dy: f64) -> InputEvent {
        InputEvent::Scroll {
            dx: 0.0,
            dy,
            normalized: VideoPoint::new(0.0, 0.0),
            scroll_phase: 0,
            momentum_phase: 0,
            continuous: false,
            tag: 0,
        }
    }

    fn key(kc: u16) -> InputEvent {
        InputEvent::Key {
            key_code: kc,
            down: true,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn text(s: &str) -> InputEvent {
        InputEvent::Text {
            text: s.to_owned(),
            tag: 0,
        }
    }

    fn coalesce(b: &[InputEvent]) -> Vec<InputEvent> {
        InputMotionCoalescer::coalesce(b)
    }

    // --- Coalescer cases (the Swift `InputMotionCoalescerTests` suite cross-checks the same). ---

    #[test]
    fn collapses_consecutive_moves_to_latest() {
        assert_eq!(
            coalesce(&[move_ev(0.1), move_ev(0.2), move_ev(0.3)]),
            vec![move_ev(0.3)]
        );
    }

    #[test]
    fn collapses_consecutive_drags_to_latest() {
        assert_eq!(
            coalesce(&[drag(0.1), drag(0.2), drag(0.3)]),
            vec![drag(0.3)]
        );
    }

    /// A move that physically preceded a click must flush BEFORE the down, and the post-down
    /// move is a separate run; down/up order intact.
    #[test]
    fn never_reorders_across_mouse_down() {
        assert_eq!(
            coalesce(&[move_ev(0.1), move_ev(0.2), down(), move_ev(0.3), up()]),
            vec![move_ev(0.2), down(), move_ev(0.3), up()],
        );
    }

    /// Drags collapse to latest but stay strictly between down and up (clickState framing).
    #[test]
    fn down_drag_up_framing_preserved() {
        assert_eq!(
            coalesce(&[down(), drag(0.1), drag(0.2), drag(0.3), up()]),
            vec![down(), drag(0.3), up()],
        );
    }

    /// A hover-run and a drag-run never merge; a class change is a flush boundary.
    #[test]
    fn move_and_drag_are_separate_buckets() {
        let batch = vec![move_ev(0.1), drag(0.2), move_ev(0.3)];
        assert_eq!(
            coalesce(&batch),
            batch,
            "class changes are flush boundaries — nothing collapses"
        );
    }

    /// A batch ending in a motion run still emits the latest position.
    #[test]
    fn trailing_motion_run_flushed() {
        assert_eq!(
            coalesce(&[down(), move_ev(0.1), move_ev(0.2)]),
            vec![down(), move_ev(0.2)],
            "a batch ending in a motion run still emits the latest position",
        );
    }

    #[test]
    fn key_scroll_text_never_dropped() {
        let batch = vec![
            move_ev(0.1),
            key(10),
            move_ev(0.2),
            scroll(3.0),
            text("a"),
            move_ev(0.3),
            move_ev(0.4),
        ];
        assert_eq!(
            coalesce(&batch),
            vec![
                move_ev(0.1),
                key(10),
                move_ev(0.2),
                scroll(3.0),
                text("a"),
                move_ev(0.4),
            ]
        );
    }

    #[test]
    fn empty_and_single_event() {
        assert_eq!(coalesce(&[]), Vec::<InputEvent>::new());
        assert_eq!(
            coalesce(&[down()]),
            vec![down()],
            "identity for a single non-motion event"
        );
        assert_eq!(
            coalesce(&[move_ev(0.5)]),
            vec![move_ev(0.5)],
            "identity for a single motion event"
        );
    }

    #[test]
    fn idempotent_on_already_coalesced() {
        let batches: Vec<Vec<InputEvent>> = vec![
            vec![move_ev(0.1), move_ev(0.2), down(), move_ev(0.3), up()],
            vec![down(), drag(0.1), drag(0.2), up(), move_ev(0.9)],
            vec![key(1), scroll(2.0), text("z")],
        ];
        for b in &batches {
            let once = coalesce(b);
            assert_eq!(
                coalesce(&once),
                once,
                "coalesce(coalesce(x)) == coalesce(x)"
            );
        }
    }

    /// The two load-bearing invariants over many batches (hand-built + seeded-random):
    /// (a) the subsequence of NON-motion events is byte-identical in count + order, and
    /// (b) the output has no two ADJACENT same-class motion events. Together these prove
    /// "collapses N motion to 1 latest but never drops/reorders a button/key/scroll/text".
    #[test]
    fn invariants_over_many_batches() {
        let mut rng = SeededRng::new(0x00C0_FFEE);
        for _ in 0..400 {
            let len = rng.next_in(21); // 0..=20
            let batch: Vec<InputEvent> = (0..len).map(|_| random_event(&mut rng)).collect();
            let out = coalesce(&batch);
            assert_eq!(
                non_motion(&out),
                non_motion(&batch),
                "non-motion subsequence preserved exactly"
            );
            assert!(
                !has_adjacent_same_class_motion(&out),
                "no two adjacent same-class motion survive"
            );
        }
    }

    // --- extra edge cases beyond the Swift suite ---

    /// Two motion runs of the SAME class separated by a barrier do NOT merge across it: the
    /// barrier flushes the first run's latest, then the second run starts fresh.
    #[test]
    fn same_class_runs_split_by_barrier_do_not_merge() {
        assert_eq!(
            coalesce(&[
                move_ev(0.1),
                move_ev(0.2),
                key(5),
                move_ev(0.3),
                move_ev(0.4)
            ]),
            vec![move_ev(0.2), key(5), move_ev(0.4)],
        );
    }

    /// Interleaved drags of DIFFERENT buttons are the same `.mouseDrag` class, so they DO
    /// collapse to the LATEST event — which keeps the latest button (absolute latest-wins).
    #[test]
    fn drag_run_keeps_latest_button() {
        assert_eq!(
            coalesce(&[
                drag_b(0.1, MouseButton::Left),
                drag_b(0.2, MouseButton::Right)
            ]),
            vec![drag_b(0.2, MouseButton::Right)],
        );
    }

    /// Adjacent barriers pass through untouched and in order (no motion to flush between them).
    #[test]
    fn adjacent_barriers_pass_through() {
        let batch = vec![
            down_b(MouseButton::Right),
            up_b(MouseButton::Right),
            key(1),
            scroll(1.0),
            text("x"),
        ];
        assert_eq!(coalesce(&batch), batch);
    }

    /// A leading motion run before the first barrier flushes its latest, then the barrier.
    #[test]
    fn leading_motion_then_barrier() {
        assert_eq!(
            coalesce(&[move_ev(0.1), move_ev(0.2), move_ev(0.3), up()]),
            vec![move_ev(0.3), up()],
        );
    }

    /// Alternating move/drag never collapses (every pair is a class-change boundary).
    #[test]
    fn alternating_move_drag_never_collapses() {
        let batch = vec![
            move_ev(0.1),
            drag(0.2),
            move_ev(0.3),
            drag(0.4),
            move_ev(0.5),
        ];
        assert_eq!(coalesce(&batch), batch);
    }

    /// A single trailing motion event after barriers is still emitted (trailing-run flush).
    #[test]
    fn single_trailing_motion_after_barriers() {
        assert_eq!(
            coalesce(&[down(), up(), move_ev(0.7)]),
            vec![down(), up(), move_ev(0.7)]
        );
    }

    /// Two-element batch of the same class collapses to one (smallest collapsing input — guards
    /// the `len() <= 1` early-out boundary).
    #[test]
    fn two_same_class_collapse() {
        assert_eq!(coalesce(&[move_ev(0.1), move_ev(0.2)]), vec![move_ev(0.2)]);
        assert_eq!(coalesce(&[drag(0.1), drag(0.2)]), vec![drag(0.2)]);
    }

    /// A two-element batch that is two distinct barriers is returned verbatim (early-out only
    /// fires at len <= 1; len == 2 goes through the loop unchanged).
    #[test]
    fn two_barriers_preserved() {
        assert_eq!(coalesce(&[down(), up()]), vec![down(), up()]);
    }

    // --- test helpers (the Swift `InputMotionCoalescerTests` private helpers follow the same shape) ---

    fn is_move(e: &InputEvent) -> bool {
        matches!(e, InputEvent::MouseMove { .. })
    }

    fn is_drag(e: &InputEvent) -> bool {
        matches!(e, InputEvent::MouseDrag { .. })
    }

    fn non_motion(events: &[InputEvent]) -> Vec<InputEvent> {
        events
            .iter()
            .filter(|e| !is_move(e) && !is_drag(e))
            .cloned()
            .collect()
    }

    fn has_adjacent_same_class_motion(events: &[InputEvent]) -> bool {
        events
            .windows(2)
            .any(|w| (is_move(&w[0]) && is_move(&w[1])) || (is_drag(&w[0]) && is_drag(&w[1])))
    }

    fn random_event(rng: &mut SeededRng) -> InputEvent {
        match rng.next_in(7) {
            0 => move_ev(rng.next_unit()),
            1 => drag(rng.next_unit()),
            2 => down(),
            3 => up(),
            4 => scroll(1.0),
            5 => key(7),
            _ => text("x"),
        }
    }

    /// Deterministic RNG (`SplitMix64`) so the fuzz invariants reproduce exactly. The Swift
    /// test's `SeededRNG` follows the same shape. The exact value sequence need not match — the
    /// test asserts STRUCTURAL invariants over many batches, not a golden output.
    struct SeededRng {
        state: u64,
    }

    impl SeededRng {
        fn new(seed: u64) -> Self {
            Self { state: seed }
        }

        fn next_u64(&mut self) -> u64 {
            self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }

        /// A uniform `usize` in `0..n` (`n` must be > 0).
        fn next_in(&mut self, n: usize) -> usize {
            (self.next_u64() % n as u64) as usize
        }

        /// A `f64` in `[0, 1)`.
        fn next_unit(&mut self) -> f64 {
            (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
        }
    }
}
