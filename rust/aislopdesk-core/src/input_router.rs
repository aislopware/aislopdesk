//! Host-side input-datagram routing + window-raise policy.
//!
//! The canonical `InputDatagramRouter` and `InputInjectorRaisePolicy` logic; the native Swift
//! shell keeps copies (`Sources/AislopdeskVideoHost/VideoSessionLogic.swift`) that track this
//! (golden parity).
//!
//! Both are PURE decision logic, kept apart from the live `InputInjector` (which posts
//! real `CGEvent`s and runs Accessibility IPC) so the routing + raise rules are testable
//! without a window server, a socket, or TCC. The actor in `AislopdeskVideoHostSession`
//! owns the live components and delegates every decision here.
//!
//! ## The raise latch (doc 18 §A — activate-then-control)
//!
//! Posting an event to a backgrounded window first needs an expensive (~6–10 synchronous
//! cross-process Accessibility IPC round-trips) raise+focus. Doing it on *every* event is
//! the dominant felt input latency, so [`InputDatagramRouter`] computes a per-event
//! `raise_first` flag from a caller-tracked latch:
//!
//! * a pointer button-down ALWAYS raises ([`always_raises`](InputDatagramRouter::always_raises));
//! * an armed latch (`needs_raise == true`) raises everything EXCEPT a latch-exempt scroll
//!   ([`latch_exempt_from_raise`](InputDatagramRouter::latch_exempt_from_raise) — a scroll
//!   goes to the window under the cursor regardless of key focus, so it never pays the AX
//!   raise: the "scroll bị delay" fix);
//! * a mouse-up re-arms the latch for the NEXT event
//!   ([`rearm_raise_after`](InputDatagramRouter::rearm_raise_after)) so a fresh click
//!   sequence re-raises.
//!
//! [`InputInjectorRaisePolicy`] is the complementary CHEAP gate that decides — from a
//! non-AX frontmost-app read — whether the full AX raise chain is needed at all.

use crate::input_event::InputEvent;

/// Routes a datagram received on the input channel.
///
/// Pure decision logic: parse the
/// [`InputEvent`] and decide whether it should be injected (and the raise/gating policy).
/// Kept separate so the routing decision is testable without an `InputInjector` (which
/// posts real `CGEvent`s).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InputDatagramRouter;

/// The decision for one received input datagram. The Swift shell's `InputDatagramRouter.Decision` mirrors this.
#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    /// Inject this event. `raise_first` is true when the window must be raised + focused
    /// before posting (the first event of an interaction / any pointer button-down — doc
    /// 18 §A activate-then-control).
    Inject {
        /// The decoded event to inject.
        event: InputEvent,
        /// Whether to raise + focus the target window before posting.
        raise_first: bool,
    },
    /// Drop a malformed/undecodable datagram (a corrupt single packet must never crash the
    /// receiver — same contract as the reassembler). `reason` is a plain `String`.
    Drop {
        /// Human-readable reason the datagram was dropped.
        reason: String,
    },
    /// Ignore the datagram because the session is not streaming.
    IgnoreNotStreaming,
}

impl InputDatagramRouter {
    /// Builds a stateless router (the Swift shell's `InputDatagramRouter()` mirrors this).
    #[must_use]
    pub const fn new() -> Self {
        Self
    }

    /// Decides what to do with one raw input datagram.
    ///
    /// * `datagram` — the raw input-channel bytes.
    /// * `media_flowing` — whether the session is in `.streaming` (otherwise the datagram is
    ///   ignored without even being decoded).
    /// * `needs_raise` — whether the next injected event should raise+focus first. The caller
    ///   (actor) tracks this: true on the first event, and re-armed after a mouse-up so a
    ///   fresh click sequence re-raises (a pointer button-down always raises; pure
    ///   moves/keys/scrolls/text do not, to avoid focus thrash).
    #[must_use]
    // `route` is an instance method to match the Swift shell's `InputDatagramRouter.route` (the actor
    // holds a `let router = InputDatagramRouter()`); the type is a stateless namespace handle,
    // so `self` is intentionally unused.
    #[allow(clippy::unused_self)]
    pub fn route(self, datagram: &[u8], media_flowing: bool, needs_raise: bool) -> Decision {
        if !media_flowing {
            return Decision::IgnoreNotStreaming;
        }
        let Ok(event) = InputEvent::decode(datagram) else {
            return Decision::Drop {
                reason: "undecodable input datagram".to_owned(),
            };
        };
        let raise_first = Self::raise_first(&event, needs_raise);
        Decision::Inject { event, raise_first }
    }

    /// A pointer button-down always raises+focuses the target first (doc 18 §A); pure
    /// moves / scrolls / keys / text do not, to avoid yanking focus on every keystroke.
    #[must_use]
    pub const fn always_raises(event: &InputEvent) -> bool {
        matches!(event, InputEvent::MouseDown { .. })
    }

    /// After injecting `event`, whether the NEXT event should be forced to raise. A mouse-up
    /// ends an interaction, so the next event re-raises; otherwise the raise latch is cleared
    /// once any event has been injected.
    #[must_use]
    pub const fn rearm_raise_after(event: &InputEvent) -> bool {
        matches!(event, InputEvent::MouseUp { .. })
    }

    /// Whether `event` is EXEMPT from the armed raise latch (the scroll-latency fix). A scroll
    /// is dispatched by the window server to the window UNDER THE CURSOR regardless of key
    /// focus, so it never needs the (expensive: ~6–10 synchronous AX IPC round-trips) re-raise
    /// — even when the post-click latch is armed by [`rearm_raise_after`](Self::rearm_raise_after).
    /// The canonical gesture is "click a pane to focus it, then scroll": before this exemption
    /// that first post-click scroll paid a full AX raise ("scroll bị delay"). A `mouseDown`
    /// still always raises ([`always_raises`](Self::always_raises)); a key/text with the latch
    /// armed still raises (it needs key focus). Because an exempt scroll does NOT satisfy
    /// `raise_first`, the actor never clears the latch on it, so a key arriving AFTER the scroll
    /// still re-raises.
    #[must_use]
    pub const fn latch_exempt_from_raise(event: &InputEvent) -> bool {
        matches!(event, InputEvent::Scroll { .. })
    }

    /// The single pure rule the live consumer (`AislopdeskVideoHostSession.injectCoalesced`)
    /// and [`route`](Self::route) share: should `event` raise+focus the target window before
    /// injection, given the current latch? A `mouseDown` always raises; otherwise the armed
    /// latch raises everything EXCEPT a latch-exempt scroll.
    #[must_use]
    pub const fn raise_first(event: &InputEvent, needs_raise: bool) -> bool {
        (needs_raise && !Self::latch_exempt_from_raise(event)) || Self::always_raises(event)
    }
}

/// Pure policy for the host's activate-then-control window raise (the CLICK-latency fix).
///
/// The
/// injector's `raiseTargetWindow()` runs ~6–10 SYNCHRONOUS cross-process Accessibility IPC
/// calls (each capped at the 0.25 s messaging timeout) that the input consumer AWAITS before
/// the click is posted — so paying the full chain on EVERY click of a window that is already
/// frontmost is the dominant felt input latency ("click bị delay 1 lúc"). This decides, from a
/// CHEAP non-AX frontmost-app read, whether the full AX raise is actually needed. Pure ⇒
/// headlessly testable without AX/TCC.
///
/// A namespace type with no instances (the Swift shell's caseless `enum` mirrors this).
#[derive(Debug, Clone, Copy)]
pub struct InputInjectorRaisePolicy;

impl InputInjectorRaisePolicy {
    /// Whether to run the full AX raise chain. Skips it ONLY when the target app is ALREADY
    /// the frontmost app AND this is not the first interaction (the first interaction always
    /// raises, to set `kAXMainWindow`/`kAXFocusedWindow` so keystrokes land on the right
    /// window even when the app is already frontmost). Errs toward raising on any uncertainty
    /// — a `None` frontmost read or a different frontmost app — so activate-then-control
    /// correctness is never weakened: a click on a genuinely-backgrounded window still raises.
    ///
    /// `frontmost_pid`/`target_pid` are `pid_t` on Apple platforms, which is `Int32` ⇒ `i32`
    /// here; a `None` frontmost is the no-frontmost-app case (the Swift shell's `pid_t?` nil).
    #[must_use]
    pub const fn should_raise(
        frontmost_pid: Option<i32>,
        target_pid: i32,
        first_interaction: bool,
    ) -> bool {
        if first_interaction {
            return true;
        }
        match frontmost_pid {
            // Unknown frontmost → raise to be safe.
            None => true,
            Some(pid) => pid != target_pid,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::VideoPoint;
    use crate::input_event::{InputModifiers, MouseButton};

    const fn router() -> InputDatagramRouter {
        InputDatagramRouter::new()
    }

    const fn n() -> VideoPoint {
        VideoPoint::new(0.5, 0.5)
    }

    // The derived `InputModifiers::default()` is `InputModifiers(0)`, written directly so the
    // event helpers can be `const fn` (Default::default is not const).
    const fn mods0() -> InputModifiers {
        InputModifiers(0)
    }

    const fn down() -> InputEvent {
        InputEvent::MouseDown {
            button: MouseButton::Left,
            normalized: n(),
            click_count: 1,
            modifiers: mods0(),
            tag: 0,
        }
    }

    const fn up() -> InputEvent {
        InputEvent::MouseUp {
            button: MouseButton::Left,
            normalized: n(),
            click_count: 1,
            modifiers: mods0(),
            tag: 0,
        }
    }

    const fn move_ev() -> InputEvent {
        InputEvent::MouseMove {
            normalized: n(),
            tag: 0,
        }
    }

    const fn drag() -> InputEvent {
        InputEvent::MouseDrag {
            button: MouseButton::Left,
            normalized: n(),
            click_count: 1,
            modifiers: mods0(),
            tag: 0,
        }
    }

    const fn scroll() -> InputEvent {
        InputEvent::Scroll {
            dx: 0.0,
            dy: -3.0,
            normalized: n(),
            scroll_phase: 0,
            momentum_phase: 0,
            continuous: false,
            tag: 0,
        }
    }

    const fn key() -> InputEvent {
        InputEvent::Key {
            key_code: 0x24,
            down: true,
            modifiers: mods0(),
            tag: 0,
        }
    }

    fn text() -> InputEvent {
        InputEvent::Text {
            text: "x".to_owned(),
            tag: 0,
        }
    }

    /// Returns the `raise_first` of an [`Decision::Inject`], panicking otherwise.
    fn inject_raise(d: Decision) -> bool {
        match d {
            Decision::Inject { raise_first, .. } => raise_first,
            other => panic!("expected inject, got {other:?}"),
        }
    }

    // ---- Input routing cases (the Swift `InputDatagramRouterTests` suite cross-checks the same). ----

    #[test]
    fn ignores_when_not_streaming() {
        let datagram = InputEvent::MouseMove {
            normalized: n(),
            tag: 1,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, false, true),
            Decision::IgnoreNotStreaming
        );
    }

    #[test]
    fn drops_undecodable_datagram() {
        // unknown event type 0xFF
        let garbage = [0xFFu8, 0x00, 0x01];
        assert!(matches!(
            router().route(&garbage, true, false),
            Decision::Drop { .. }
        ));
    }

    #[test]
    fn injects_decodable_event() {
        let event = InputEvent::Text {
            text: "hi".to_owned(),
            tag: 9,
        };
        match router().route(&event.encode(), true, false) {
            Decision::Inject {
                event: decoded,
                raise_first,
            } => {
                assert_eq!(decoded, event);
                assert!(
                    !raise_first,
                    "text does not raise unless the latch is armed"
                );
            }
            other => panic!("expected inject, got {other:?}"),
        }
    }

    #[test]
    fn armed_latch_raises_key_but_exempts_scroll() {
        // A key with the latch armed raises (it needs key focus)...
        assert!(
            inject_raise(router().route(&key().encode(), true, true)),
            "an armed latch raises a key event (it needs key focus)"
        );
        // ...but a SCROLL is exempt: it goes to the window under the cursor regardless of
        // focus, so it never pays the AX raise even when the post-click latch is armed.
        assert!(
            !inject_raise(router().route(&scroll().encode(), true, true)),
            "an armed latch must NOT raise a scroll (latch-exempt)"
        );
    }

    #[test]
    fn scroll_is_the_only_latch_exempt_event() {
        assert!(InputDatagramRouter::latch_exempt_from_raise(&scroll()));
        assert!(!InputDatagramRouter::latch_exempt_from_raise(&move_ev()));
        assert!(!InputDatagramRouter::latch_exempt_from_raise(&down()));
        assert!(!InputDatagramRouter::latch_exempt_from_raise(&up()));
        assert!(!InputDatagramRouter::latch_exempt_from_raise(&key()));
        assert!(!InputDatagramRouter::latch_exempt_from_raise(&text()));
    }

    #[test]
    fn mouse_down_always_raises_regardless_of_latch() {
        assert!(
            inject_raise(router().route(&down().encode(), true, false)),
            "a pointer button-down always raises+focuses first (doc 18 §A)"
        );
    }

    #[test]
    fn move_scroll_key_text_do_not_raise_with_latch_clear() {
        let events = [move_ev(), drag(), scroll(), key(), text(), up()];
        for event in events {
            assert!(
                !inject_raise(router().route(&event.encode(), true, false)),
                "{event:?} must not raise when the latch is clear"
            );
        }
    }

    #[test]
    fn rearm_raise_after_mouse_up_only() {
        assert!(InputDatagramRouter::rearm_raise_after(&up()));
        assert!(!InputDatagramRouter::rearm_raise_after(&down()));
        assert!(!InputDatagramRouter::rearm_raise_after(&move_ev()));
        assert!(!InputDatagramRouter::rearm_raise_after(&drag()));
        assert!(!InputDatagramRouter::rearm_raise_after(&text()));
    }

    /// Simulates a full click sequence's latch evolution as the actor would track it:
    /// initial event raises (armed), down raises, up re-arms, next event raises again.
    #[test]
    fn raise_latch_evolution_across_click_sequence() {
        let r = router();
        let mut needs_raise = true; // actor starts armed
        let mut step = |event: &InputEvent| -> bool {
            let raise_first = inject_raise(r.route(&event.encode(), true, needs_raise));
            needs_raise = InputDatagramRouter::rearm_raise_after(event);
            raise_first
        };
        assert!(
            step(&down()),
            "first event raises (armed) + is a button-down"
        );
        assert!(
            !step(&move_ev()),
            "mid-drag move does not re-raise (latch cleared after the down)"
        );
        assert!(
            !step(&up()),
            "the up itself does not raise; it RE-ARMS the latch for the NEXT event"
        );
        assert!(
            step(&down()),
            "next click raises again (latch re-armed by the prior up)"
        );
    }

    /// The canonical "click a pane, then scroll, then type" gesture, modelled with the EXACT
    /// actor latch logic (clears the latch only when it actually raises, re-arms after a
    /// mouse-up). Proves the scroll-latency fix.
    #[test]
    fn post_click_scroll_is_exempt_but_leaves_latch_for_following_key() {
        let mut needs_raise = true; // actor starts armed
        let mut step = |event: &InputEvent| -> bool {
            let raise_first = InputDatagramRouter::raise_first(event, needs_raise);
            if raise_first {
                needs_raise = false; // actor clears the latch before raising
            }
            if InputDatagramRouter::rearm_raise_after(event) {
                needs_raise = true; // a mouse-up re-arms it
            }
            raise_first
        };
        assert!(step(&down()), "click raises (button-down)");
        assert!(!step(&up()), "the up re-arms the latch");
        assert!(
            !step(&scroll()),
            "the post-click scroll is latch-exempt → NO AX raise (the fix)"
        );
        assert!(
            step(&key()),
            "a key after the scroll still raises (the exempt scroll did not consume the latch)"
        );
    }

    // ---- added edge cases -------------------------------------------------------------

    #[test]
    fn drop_reason_is_the_documented_string() {
        assert_eq!(
            router().route(&[0xFF], true, false),
            Decision::Drop {
                reason: "undecodable input datagram".to_owned(),
            }
        );
    }

    #[test]
    fn empty_datagram_drops() {
        // An empty datagram has not even a type byte ⇒ decode errors ⇒ drop (never a crash).
        assert!(matches!(
            router().route(&[], true, false),
            Decision::Drop { .. }
        ));
    }

    #[test]
    fn not_streaming_ignored_even_for_garbage() {
        // The streaming gate runs BEFORE decode, so a corrupt datagram while not streaming is
        // ignored (not dropped) — decode is never attempted.
        assert_eq!(
            router().route(&[0xFF], false, true),
            Decision::IgnoreNotStreaming
        );
    }

    #[test]
    fn armed_latch_raises_move_and_drag() {
        for event in [move_ev(), drag()] {
            assert!(
                inject_raise(router().route(&event.encode(), true, true)),
                "an armed latch raises {event:?} (not latch-exempt)"
            );
        }
    }

    #[test]
    fn mouse_down_raises_with_armed_latch() {
        // A button-down satisfies BOTH always-raises and the armed latch.
        assert!(inject_raise(router().route(&down().encode(), true, true)));
    }

    #[test]
    fn always_raises_only_mouse_down() {
        assert!(InputDatagramRouter::always_raises(&down()));
        for event in [up(), move_ev(), drag(), scroll(), key(), text()] {
            assert!(
                !InputDatagramRouter::always_raises(&event),
                "{event:?} must not always-raise"
            );
        }
    }

    #[test]
    fn raise_first_rule_direct() {
        // Latch clear: only a button-down raises.
        assert!(InputDatagramRouter::raise_first(&down(), false));
        assert!(!InputDatagramRouter::raise_first(&scroll(), false));
        assert!(!InputDatagramRouter::raise_first(&key(), false));
        assert!(!InputDatagramRouter::raise_first(&move_ev(), false));
        assert!(!InputDatagramRouter::raise_first(&drag(), false));
        assert!(!InputDatagramRouter::raise_first(&text(), false));
        assert!(!InputDatagramRouter::raise_first(&up(), false));
        // Latch armed: everything raises EXCEPT a latch-exempt scroll.
        assert!(InputDatagramRouter::raise_first(&key(), true));
        assert!(InputDatagramRouter::raise_first(&move_ev(), true));
        assert!(InputDatagramRouter::raise_first(&drag(), true));
        assert!(InputDatagramRouter::raise_first(&text(), true));
        assert!(InputDatagramRouter::raise_first(&up(), true));
        assert!(InputDatagramRouter::raise_first(&down(), true));
        assert!(!InputDatagramRouter::raise_first(&scroll(), true));
    }

    // ---- Raise-policy cases (the Swift `InputInjectorRaisePolicyTests` suite cross-checks the same). ----

    #[test]
    fn skips_raise_when_already_frontmost_and_not_first() {
        assert!(
            !InputInjectorRaisePolicy::should_raise(Some(42), 42, false),
            "an already-frontmost target on a repeat interaction skips the expensive AX raise"
        );
    }

    #[test]
    fn raises_on_first_interaction_even_if_already_frontmost() {
        assert!(
            InputInjectorRaisePolicy::should_raise(Some(42), 42, true),
            "the first interaction always raises to set kAXMainWindow/kAXFocusedWindow"
        );
    }

    #[test]
    fn raises_when_a_different_app_is_frontmost() {
        assert!(
            InputInjectorRaisePolicy::should_raise(Some(7), 42, false),
            "a backgrounded target must raise to come frontmost (activate-then-control)"
        );
    }

    #[test]
    fn raises_when_frontmost_is_unknown() {
        assert!(
            InputInjectorRaisePolicy::should_raise(None, 42, false),
            "an unreadable frontmost errs toward raising so correctness is never weakened"
        );
    }

    // ---- added edge cases -------------------------------------------------------------

    #[test]
    fn first_interaction_raises_regardless_of_frontmost_state() {
        assert!(InputInjectorRaisePolicy::should_raise(None, 42, true));
        assert!(InputInjectorRaisePolicy::should_raise(Some(7), 42, true));
        assert!(InputInjectorRaisePolicy::should_raise(Some(42), 42, true));
    }

    #[test]
    fn negative_pids_compare_by_equality() {
        // pid_t is signed; equal negative pids skip, different ones raise.
        assert!(!InputInjectorRaisePolicy::should_raise(Some(-1), -1, false));
        assert!(InputInjectorRaisePolicy::should_raise(Some(-1), -2, false));
    }
}
