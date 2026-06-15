//! Pure host-side size negotiation: clamps a client `resizeRequest`'s desired size into the
//! host's allowed window bounds and decides whether a resize epoch is stale.

use crate::geometry::VideoSize;

/// Pure host-side size negotiation for the in-session resize feature — the canonical
/// `SizeNegotiation`. The Swift shell's `SizeNegotiation` mirrors this.
///
/// Turns a client `resizeRequest`'s desired size into the `u16` capture dimensions the host
/// will adopt, clamped to the host's allowed `min`/`max` window size and rounded to a
/// `u16`-safe int that is NEVER zero (a zero-dimension SCStream/encoder config is invalid). No
/// `ScreenCaptureKit` / AX — exactly the discipline of [`VideoSessionStateMachine`], so the
/// clamp + epoch ordering are unit-testable in isolation. Modelled as a unit struct (the
/// caseless-enum namespace pattern: it is never instantiated).
///
/// [`VideoSessionStateMachine`]: super::VideoSessionStateMachine
pub struct SizeNegotiation;

impl SizeNegotiation {
    /// Clamps `desired` into `[min, max]` per axis and rounds to a `u16`-safe, non-zero
    /// integer. Identity (within rounding) when `desired` is already inside the bounds.
    ///
    /// Matches the actor's hello clamp (`u16(max(1, min(u16::MAX, v.round())))`) but bounded by
    /// the host's min/max policy rather than a single window size. The min is floored at 1 and
    /// the max ceilinged at `u16::MAX` so a degenerate (zero / out-of-range) policy can never
    /// yield 0 or overflow.
    #[must_use]
    pub fn clamp(desired: VideoSize, min_size: VideoSize, max_size: VideoSize) -> (u16, u16) {
        (
            Self::clamp_axis(desired.width, min_size.width, max_size.width),
            Self::clamp_axis(desired.height, min_size.height, max_size.height),
        )
    }

    /// One axis of [`clamp`](Self::clamp). Float op order + global-min/max NaN semantics are
    /// canonical (see [`swift_min`]/[`swift_max`]); the Swift shell matches these exactly.
    fn clamp_axis(value: f64, lo: f64, hi: f64) -> u16 {
        // Floor the lower bound at 1 and ceiling the upper at u16::MAX, then order them (a
        // swapped/degenerate policy must still clamp into a valid window).
        let lo_c = swift_max(1.0, swift_min(lo.round(), f64::from(u16::MAX)));
        let hi_c = swift_max(1.0, swift_min(hi.round(), f64::from(u16::MAX)));
        let lower = swift_min(lo_c, hi_c);
        let upper = swift_max(lo_c, hi_c);
        // NaN/non-finite desired collapses to the lower bound (never 0, never a trap).
        let v = if value.is_finite() {
            value.round()
        } else {
            lower
        };
        let clamped = swift_min(swift_max(v, lower), upper);
        // `clamped` is integer-valued and in [1, u16::MAX]; `as u16` truncates toward zero;
        // the Swift shell's `UInt16(Double)` does the same (no saturation triggered, no NaN).
        clamped as u16
    }

    /// Whether `epoch` is stale relative to the last APPLIED epoch — a value `<= last_applied`
    /// (a duplicate or out-of-order/older request) must be ignored so a UDP reorder/retransmit
    /// cannot un-settle the coalesced size. The first request of a session (any `epoch >= 1`
    /// against `last_applied == 0`) is therefore NOT stale.
    #[must_use]
    pub const fn is_stale_epoch(epoch: u32, last_applied: u32) -> bool {
        epoch <= last_applied
    }
}

/// `min(x, y) == { y < x ? y : x }` — propagates a NaN operand (unlike `f64::min`, which
/// returns the non-NaN operand and would diverge on hostile policy bounds). Finite inputs
/// agree with `f64::min`. The Swift shell does the same, so the two stay bit-identical.
#[inline]
const fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// `max(x, y) == { y >= x ? y : x }` — the NaN-faithful counterpart of `f64::max`
/// (see [`swift_min`]); the Swift shell does the same. Finite inputs agree with `f64::max`.
#[inline]
const fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}
