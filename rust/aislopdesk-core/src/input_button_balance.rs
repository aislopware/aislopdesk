//! Pure button-balance bookkeeping for input injection — a port of Swift
//! `InputButtonBalance` (in `Sources/AislopdeskVideoHost/VideoSessionLogic.swift`).
//!
//! The reorder fix (ordered inbound consumer) keeps a single interaction's
//! down→drag→up in order, but it cannot conjure a `mouseUp` that the wire DROPPED or a
//! flaky gesture never sent. A target app that received a `mouseDown` with no matching
//! `mouseUp` stays stuck mid-selection, so the NEXT click "đã bắt đầu selection rồi".
//! This tracks which buttons are logically HELD so a fresh `mouseDown` for an
//! already-held button can emit a synthetic release FIRST — guaranteeing a click never
//! begins inside a stuck selection. Only down/up mutate the held set;
//! moves/drags/scroll/keys/text pass through unchanged.
//!
//! ## Why the held set is keyed on the wire value
//!
//! Swift uses `Set<MouseButton>`. The Rust [`MouseButton`](crate::input_event::MouseButton)
//! deliberately does NOT derive `Ord`/`Hash`, so this port keys a deterministic
//! [`BTreeSet<u8>`] on the on-wire raw value ([`MouseButton::raw`]) instead. The three
//! variants map 1:1 to `0/1/2`, so the set has exactly the same membership semantics as
//! the Swift `Set<MouseButton>` while staying allocation-deterministic for golden parity.

use crate::input_event::{InputEvent, MouseButton};
use std::collections::BTreeSet;

/// What to do before injecting an event — the byte-identical mirror of Swift
/// `InputButtonBalance.Plan`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Plan {
    /// Emit a synthetic release of THIS button before the real event (`None` ⇒ none). Set
    /// only when a `mouseDown` arrives for a button still marked held (a lost up).
    pub pre_release: Option<MouseButton>,
    /// SUPPRESS the event entirely — do NOT post it. Set for a `mouseUp` whose button is
    /// NOT held: a duplicate of the client's loss-resilient 3× `mouseUp` (the first up
    /// already released the button) or an up with no matching down. Posting it would be a
    /// spurious extra `*MouseUp` into the target app (breaks the double-click coalescer /
    /// custom WebKit/Electron tracking). This is what makes the wire redundancy truly
    /// idempotent on the host: the FIRST up of the burst posts, the rest are dropped.
    pub suppress: bool,
}

impl Plan {
    /// Builds a plan. Mirrors Swift's `init(preRelease:suppress:)`; the Swift default
    /// arguments are `pre_release: None, suppress: false` — use [`Plan::default`] for that.
    #[must_use]
    pub const fn new(pre_release: Option<MouseButton>, suppress: bool) -> Self {
        Self {
            pre_release,
            suppress,
        }
    }
}

/// Pure button-balance bookkeeping for input injection (testable WITHOUT `CGEvents`).
///
/// See the [module docs](self) for the rationale. The held set is the only state; it is
/// mutated solely by `mouseDown`/`mouseUp` in [`plan`](Self::plan).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct InputButtonBalance {
    /// Logically-held buttons, keyed on [`MouseButton::raw`] (see module docs).
    held: BTreeSet<u8>,
}

impl InputButtonBalance {
    /// A fresh balance with nothing held.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds `event` into the held set and returns the injection plan. A `mouseDown` for an
    /// already-held button asks for a pre-release (then stays held — the fresh down owns it);
    /// a `mouseUp` for a HELD button releases it (post it); a `mouseUp` for a button NOT held
    /// is a redundant/duplicate up and is SUPPRESSED; everything else passes through.
    pub fn plan(&mut self, event: &InputEvent) -> Plan {
        match event {
            InputEvent::MouseDown { button, .. } => {
                // `insert` returns false if the key was already present; that "already
                // present" is exactly Swift's `held.contains(button)` stuck-check, so we
                // read the membership first, then insert (idempotently keeps it held).
                let stuck = self.held.contains(&button.raw());
                self.held.insert(button.raw());
                Plan::new(if stuck { Some(*button) } else { None }, false)
            }
            InputEvent::MouseUp { button, .. } => {
                if self.held.remove(&button.raw()) {
                    // first up for a held button — release it (post it)
                    Plan::default()
                } else {
                    // duplicate / orphan up — drop it (idempotent)
                    Plan::new(None, true)
                }
            }
            InputEvent::MouseMove { .. }
            | InputEvent::MouseDrag { .. }
            | InputEvent::Scroll { .. }
            | InputEvent::Key { .. }
            | InputEvent::Text { .. } => Plan::default(),
        }
    }

    /// Whether `button` is currently held. Mirrors Swift `held.contains(_)`.
    #[must_use]
    pub fn held_contains(&self, button: MouseButton) -> bool {
        self.held.contains(&button.raw())
    }

    /// Whether no button is held. Mirrors Swift `held.isEmpty`.
    #[must_use]
    pub fn held_is_empty(&self) -> bool {
        self.held.is_empty()
    }

    /// The held buttons in ascending wire-value order (Left, Right, Other) — a
    /// deterministic snapshot of Swift's `held` set for introspection / tests. Every stored
    /// key is a valid raw value (only `mouseDown`/`mouseUp` insert), so the parse never drops.
    #[must_use]
    pub fn held(&self) -> Vec<MouseButton> {
        self.held
            .iter()
            .filter_map(|&v| MouseButton::from_u8(v))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::VideoPoint;
    use crate::input_event::InputModifiers;

    fn n() -> VideoPoint {
        VideoPoint::new(0.5, 0.5)
    }

    fn down(b: MouseButton) -> InputEvent {
        InputEvent::MouseDown {
            button: b,
            normalized: n(),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn up(b: MouseButton) -> InputEvent {
        InputEvent::MouseUp {
            button: b,
            normalized: n(),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    fn drag(b: MouseButton) -> InputEvent {
        InputEvent::MouseDrag {
            button: b,
            normalized: n(),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        }
    }

    // ---- 1:1 mirrors of InputButtonBalanceTests.swift ----

    #[test]
    fn clean_click_never_pre_releases() {
        let mut bal = InputButtonBalance::new();
        assert_eq!(
            bal.plan(&down(MouseButton::Left)).pre_release,
            None,
            "first down has nothing held"
        );
        assert!(bal.held_contains(MouseButton::Left));
        assert_eq!(bal.plan(&up(MouseButton::Left)).pre_release, None);
        assert!(
            !bal.held_contains(MouseButton::Left),
            "up clears the button"
        );
    }

    #[test]
    fn drag_select_never_pre_releases() {
        let mut bal = InputButtonBalance::new();
        assert_eq!(bal.plan(&down(MouseButton::Left)).pre_release, None);
        for _ in 0..5 {
            assert_eq!(
                bal.plan(&drag(MouseButton::Left)).pre_release,
                None,
                "a drag never pre-releases"
            );
        }
        assert_eq!(bal.plan(&up(MouseButton::Left)).pre_release, None);
        assert!(bal.held_is_empty());
    }

    /// The core recovery: a down → drag with the up LOST, then a fresh down. The fresh down
    /// must pre-release the still-held button so the click does not start inside a selection.
    #[test]
    fn lost_up_then_click_pre_releases() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        let _ = bal.plan(&drag(MouseButton::Left));
        // (up never arrives — dropped on the wire / never sent by a flaky three-finger drag)
        let plan = bal.plan(&down(MouseButton::Left));
        assert_eq!(
            plan.pre_release,
            Some(MouseButton::Left),
            "a down on a still-held button releases it first"
        );
        assert!(
            bal.held_contains(MouseButton::Left),
            "the fresh down then owns the button"
        );
    }

    #[test]
    fn double_click_does_not_pre_release() {
        let mut bal = InputButtonBalance::new();
        assert_eq!(bal.plan(&down(MouseButton::Left)).pre_release, None);
        assert_eq!(bal.plan(&up(MouseButton::Left)).pre_release, None);
        assert_eq!(
            bal.plan(&down(MouseButton::Left)).pre_release,
            None,
            "second click is clean — the first up cleared the button"
        );
        assert_eq!(bal.plan(&up(MouseButton::Left)).pre_release, None);
    }

    #[test]
    fn redundant_up_is_suppressed_after_first() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        // The client sends the up 3× for loss-resilience. The FIRST releases + posts; the
        // 2nd/3rd find nothing held → SUPPRESSED so the host posts no spurious extra *MouseUp.
        let first = bal.plan(&up(MouseButton::Left));
        assert!(
            !first.suppress,
            "first up releases the held button and is posted"
        );
        assert_eq!(first.pre_release, None);
        assert!(
            bal.plan(&up(MouseButton::Left)).suppress,
            "2nd duplicate up is suppressed"
        );
        assert!(
            bal.plan(&up(MouseButton::Left)).suppress,
            "3rd duplicate up is suppressed"
        );
        assert!(bal.held_is_empty());
    }

    #[test]
    fn orphan_up_with_no_down_is_suppressed() {
        let mut bal = InputButtonBalance::new();
        // An up that arrives with no matching down (reorder / lost down) must not post a
        // stray release into the target app.
        assert!(bal.plan(&up(MouseButton::Left)).suppress);
        assert!(bal.held_is_empty());
    }

    #[test]
    fn down_post_first_up_then_redundant_suppressed_does_not_stick_button() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        assert!(!bal.plan(&up(MouseButton::Left)).suppress); // released
        assert!(bal.plan(&up(MouseButton::Left)).suppress); // duplicate dropped
                                                            // A fresh click after the redundant ups is clean — the button was released by the first up.
        assert_eq!(
            bal.plan(&down(MouseButton::Left)).pre_release,
            None,
            "fresh click does not pre-release — duplicates did not leave it held"
        );
    }

    #[test]
    fn moves_scroll_keys_text_do_not_change_held() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        let noop = [
            InputEvent::MouseMove {
                normalized: n(),
                tag: 0,
            },
            InputEvent::Scroll {
                dx: 1.0,
                dy: 2.0,
                normalized: n(),
                tag: 0,
            },
            InputEvent::Key {
                key_code: 1,
                down: true,
                modifiers: InputModifiers::default(),
                tag: 0,
            },
            InputEvent::Text {
                text: "x".to_owned(),
                tag: 0,
            },
        ];
        for e in &noop {
            assert_eq!(bal.plan(e).pre_release, None, "{e:?} never pre-releases");
            assert_eq!(
                bal.held(),
                vec![MouseButton::Left],
                "{e:?} leaves held state untouched"
            );
        }
    }

    #[test]
    fn buttons_tracked_independently() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        assert_eq!(
            bal.plan(&down(MouseButton::Right)).pre_release,
            None,
            "right is independent of a held left"
        );
        assert_eq!(bal.held(), vec![MouseButton::Left, MouseButton::Right]);
        // A right down again (right still held, e.g. lost right-up) pre-releases right only.
        assert_eq!(
            bal.plan(&down(MouseButton::Right)).pre_release,
            Some(MouseButton::Right)
        );
        assert_eq!(bal.plan(&up(MouseButton::Left)).pre_release, None);
        assert_eq!(bal.held(), vec![MouseButton::Right]);
    }

    // ---- Additional edge-case coverage ----

    #[test]
    fn plan_default_is_none_and_not_suppress() {
        let p = Plan::default();
        assert_eq!(p.pre_release, None);
        assert!(!p.suppress);
        assert_eq!(p, Plan::new(None, false));
    }

    #[test]
    fn pre_release_plan_is_not_suppressed() {
        // A pre-releasing down must still POST (the synthetic release is BEFORE it, the real
        // down is not suppressed).
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        let plan = bal.plan(&down(MouseButton::Left));
        assert_eq!(plan.pre_release, Some(MouseButton::Left));
        assert!(!plan.suppress, "the fresh down itself is never suppressed");
    }

    #[test]
    fn other_button_is_tracked() {
        // The `.other` variant maps to wire value 2 and must balance like left/right.
        let mut bal = InputButtonBalance::new();
        assert_eq!(bal.plan(&down(MouseButton::Other)).pre_release, None);
        assert!(bal.held_contains(MouseButton::Other));
        assert_eq!(
            bal.plan(&down(MouseButton::Other)).pre_release,
            Some(MouseButton::Other),
            "a stuck other-button down pre-releases"
        );
        assert!(!bal.plan(&up(MouseButton::Other)).suppress);
        assert!(bal.held_is_empty());
    }

    #[test]
    fn all_three_buttons_held_and_released_independently() {
        let mut bal = InputButtonBalance::new();
        let _ = bal.plan(&down(MouseButton::Left));
        let _ = bal.plan(&down(MouseButton::Right));
        let _ = bal.plan(&down(MouseButton::Other));
        assert_eq!(
            bal.held(),
            vec![MouseButton::Left, MouseButton::Right, MouseButton::Other],
            "held() is sorted ascending by wire value"
        );
        // Release the middle one; the others stay held.
        assert!(!bal.plan(&up(MouseButton::Right)).suppress);
        assert_eq!(bal.held(), vec![MouseButton::Left, MouseButton::Other]);
        // A duplicate up for the already-released right is suppressed and leaves the rest.
        assert!(bal.plan(&up(MouseButton::Right)).suppress);
        assert_eq!(bal.held(), vec![MouseButton::Left, MouseButton::Other]);
    }

    #[test]
    fn drag_for_a_button_never_held_is_passthrough() {
        // A drag is always a passthrough (no plan effect, no held mutation), even with an
        // empty held set.
        let mut bal = InputButtonBalance::new();
        let plan = bal.plan(&drag(MouseButton::Left));
        assert_eq!(plan, Plan::default());
        assert!(bal.held_is_empty());
    }

    #[test]
    fn orphan_up_does_not_add_to_held() {
        // A suppressed orphan up must not accidentally insert the button.
        let mut bal = InputButtonBalance::new();
        assert!(bal.plan(&up(MouseButton::Right)).suppress);
        assert!(!bal.held_contains(MouseButton::Right));
        assert!(bal.held_is_empty());
    }

    #[test]
    fn equatable_tracks_state() {
        // Two fresh balances are equal; a divergent fold breaks equality; re-converging
        // restores it (the held set is the only state).
        let mut a = InputButtonBalance::new();
        let mut b = InputButtonBalance::new();
        assert_eq!(a, b);
        let _ = a.plan(&down(MouseButton::Left));
        assert_ne!(a, b);
        let _ = b.plan(&down(MouseButton::Left));
        assert_eq!(a, b);
        let _ = a.plan(&up(MouseButton::Left));
        let _ = b.plan(&up(MouseButton::Left));
        assert_eq!(a, b);
        assert!(a.held_is_empty() && b.held_is_empty());
    }

    #[test]
    fn double_down_same_button_then_two_ups_balances_to_one_post() {
        // down, down (stuck → pre-release, still held once), up (released + posted),
        // up (duplicate → suppressed). The fresh-down idempotency means a second down does
        // not stack a second hold.
        let mut bal = InputButtonBalance::new();
        assert_eq!(bal.plan(&down(MouseButton::Left)).pre_release, None);
        assert_eq!(
            bal.plan(&down(MouseButton::Left)).pre_release,
            Some(MouseButton::Left)
        );
        assert!(bal.held_contains(MouseButton::Left));
        assert!(!bal.plan(&up(MouseButton::Left)).suppress);
        assert!(bal.held_is_empty());
        assert!(bal.plan(&up(MouseButton::Left)).suppress);
    }
}
