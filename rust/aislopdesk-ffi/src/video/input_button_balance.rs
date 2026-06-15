//! `input_button_balance`: opaque handle (host input-injection button-balance bookkeeping).
//! Driven on the host `InputInjector` (one `plan()` per injected event, NSLock-serialized). The
//! plan logic reads only the event VARIANT + button, so the boundary takes those two scalars (the
//! kind is an `AISD_INPUT_*` discriminant; the button is a raw 0/1/2) rather than marshaling a
//! full event. The held set has at most three members, so it crosses as a u8 bitmask. Same "Rust
//! owns the state" boundary as the deduper.

use super::{AISD_INPUT_MOUSE_DOWN, AISD_INPUT_MOUSE_UP};
use aislopdesk_core::geometry::VideoPoint;
use aislopdesk_core::input_button_balance::InputButtonBalance;
use aislopdesk_core::input_event::{InputEvent, InputModifiers, MouseButton};

/// The injection plan for one event, flattened for the C ABI (the Swift `Plan` mirrors it).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdInputPlan {
    /// `1` ⇒ emit a synthetic release of `pre_release_button` before the real event, else `0`.
    pub has_pre_release: u8,
    /// The button (raw `0`=left/`1`=right/`2`=other) to pre-release; valid iff `has_pre_release`.
    pub pre_release_button: u8,
    /// `1` ⇒ SUPPRESS the event entirely (do not post it), else `0`.
    pub suppress: u8,
}

/// Opaque host input-injection button-balance.
///
/// Create with [`aisd_input_button_balance_new`], fold each event with
/// [`aisd_input_button_balance_plan`], destroy with [`aisd_input_button_balance_free`]. One per
/// injector; not thread-safe (the caller's lock serializes access).
pub struct AisdInputButtonBalance {
    inner: InputButtonBalance,
}

/// Builds the minimal core [`InputEvent`] the balance logic needs: only the variant + button drive
/// [`InputButtonBalance::plan`], so the other fields are dummies. A `kind` of `MOUSE_DOWN` /
/// `MOUSE_UP` with a valid `button` is a down/up; anything else (including an invalid button) is a
/// harmless passthrough (the plan returns the default for it).
fn input_balance_event(kind: u8, button: u8) -> InputEvent {
    let passthrough = InputEvent::MouseMove {
        normalized: VideoPoint::new(0.0, 0.0),
        tag: 0,
    };
    let Some(b) = MouseButton::from_u8(button) else {
        return passthrough;
    };
    match kind {
        AISD_INPUT_MOUSE_DOWN => InputEvent::MouseDown {
            button: b,
            normalized: VideoPoint::new(0.0, 0.0),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        },
        AISD_INPUT_MOUSE_UP => InputEvent::MouseUp {
            button: b,
            normalized: VideoPoint::new(0.0, 0.0),
            click_count: 1,
            modifiers: InputModifiers::default(),
            tag: 0,
        },
        _ => passthrough,
    }
}

/// Creates a fresh button-balance (nothing held). Destroy it with
/// [`aisd_input_button_balance_free`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_input_button_balance_new() -> *mut AisdInputButtonBalance {
    Box::into_raw(Box::new(AisdInputButtonBalance {
        inner: InputButtonBalance::new(),
    }))
}

/// Destroys a balance created by [`aisd_input_button_balance_new`]. No-op on null.
///
/// # Safety
/// `balance` must be a pointer from [`aisd_input_button_balance_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_button_balance_free(balance: *mut AisdInputButtonBalance) {
    unsafe {
        if !balance.is_null() {
            drop(Box::from_raw(balance));
        }
    }
}

/// Folds one event into the held set and returns the injection plan.
///
/// `kind` = `AISD_INPUT_*`, `button` = raw 0/1/2. A null handle returns the default plan (post, no
/// pre-release). Wraps [`InputButtonBalance::plan`].
///
/// # Safety
/// `balance`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_button_balance_plan(
    balance: *mut AisdInputButtonBalance,
    kind: u8,
    button: u8,
) -> AisdInputPlan {
    unsafe {
        let Some(bal) = balance.as_mut() else {
            return AisdInputPlan {
                has_pre_release: 0,
                pre_release_button: 0,
                suppress: 0,
            };
        };
        let plan = bal.inner.plan(&input_balance_event(kind, button));
        AisdInputPlan {
            has_pre_release: u8::from(plan.pre_release.is_some()),
            pre_release_button: plan.pre_release.map_or(0, MouseButton::raw),
            suppress: u8::from(plan.suppress),
        }
    }
}

/// The currently-held buttons as a bitmask: bit 0 = left (raw 0), bit 1 = right (raw 1), bit 2 =
/// other (raw 2). `0` for an empty set or a null handle. Mirrors the Swift `held` set.
///
/// # Safety
/// `balance`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_button_balance_held_mask(
    balance: *const AisdInputButtonBalance,
) -> u8 {
    unsafe {
        balance.as_ref().map_or(0, |bal| {
            bal.inner
                .held()
                .iter()
                .fold(0u8, |mask, b| mask | (1u8 << b.raw()))
        })
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::video::AISD_INPUT_MOUSE_DRAG;

    #[test]
    fn input_button_balance_handle_balances_clicks() {
        unsafe {
            let b = aisd_input_button_balance_new();
            assert!(!b.is_null());
            // Clean left click: no pre-release, posted, left held then cleared.
            let p = aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_DOWN, 0);
            assert_eq!(p.has_pre_release, 0);
            assert_eq!(p.suppress, 0);
            assert_eq!(aisd_input_button_balance_held_mask(b), 0b001);
            let p = aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_UP, 0);
            assert_eq!(p.suppress, 0);
            assert_eq!(aisd_input_button_balance_held_mask(b), 0);
            // A duplicate up is suppressed.
            assert_eq!(
                aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_UP, 0).suppress,
                1
            );
            // Lost-up recovery: a fresh down on a still-held button pre-releases it.
            let _ = aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_DOWN, 1); // right down
            let p = aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_DOWN, 1); // right down again
            assert_eq!(p.has_pre_release, 1);
            assert_eq!(p.pre_release_button, 1);
            assert_eq!(p.suppress, 0);
            assert_eq!(aisd_input_button_balance_held_mask(b), 0b010);
            // A drag never mutates the held set or pre-releases.
            let p = aisd_input_button_balance_plan(b, AISD_INPUT_MOUSE_DRAG, 1);
            assert_eq!(p.has_pre_release, 0);
            assert_eq!(aisd_input_button_balance_held_mask(b), 0b010);
            aisd_input_button_balance_free(b);
            aisd_input_button_balance_free(core::ptr::null_mut()); // no-op
            // A null handle returns the default plan and an empty mask.
            let p = aisd_input_button_balance_plan(core::ptr::null_mut(), AISD_INPUT_MOUSE_UP, 0);
            assert_eq!(p.has_pre_release, 0);
            assert_eq!(p.suppress, 0);
            assert_eq!(aisd_input_button_balance_held_mask(core::ptr::null()), 0);
        }
    }
}
