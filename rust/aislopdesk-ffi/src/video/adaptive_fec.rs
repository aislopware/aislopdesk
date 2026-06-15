//! `adaptive_fec`: pure, scalar (tier/`next_tier_state` ~per netstats report; `group_size` on the
//! reassemble/packetize path; FFI overhead negligible vs decode/encode).

use aislopdesk_core::adaptive_fec;

/// Tier-decision state for the dwell-gated adaptive-FEC variant, flattened for the C ABI.
///
/// Mirrors [`adaptive_fec::TierState`] field-for-field (`#[repr(C)]`, same field order). Crosses
/// by value in both directions.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdTierState {
    /// Current wire tier (0..=7 on the wire; any `u8` is total).
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
}

impl From<adaptive_fec::TierState> for AisdTierState {
    fn from(s: adaptive_fec::TierState) -> Self {
        Self {
            tier: s.tier,
            relax_streak: s.relax_streak,
            sticky_relax_remaining: s.sticky_relax_remaining,
        }
    }
}

impl From<AisdTierState> for adaptive_fec::TierState {
    fn from(s: AisdTierState) -> Self {
        Self::new(s.tier, s.relax_streak, s.sticky_relax_remaining)
    }
}

/// Maps a wire tier to the FEC group size both ends must use.
///
/// Wraps
/// [`adaptive_fec::group_size`]. Returns `1` and writes the group size to `*out` for a parity
/// tier; returns `0` for the OFF (no-parity) tier (leaving `*out` untouched — treat as nil).
/// TOTAL over every `tier` (unknown → `default_group_size`, never traps). A null `out` returns
/// `0` without writing.
///
/// # Safety
/// `out`, if non-null, must be a writable `usize` pointer.
#[must_use]
#[unsafe(no_mangle)]
pub const unsafe extern "C" fn aisd_adaptive_fec_group_size(
    tier: u8,
    default_group_size: usize,
    out: *mut usize,
) -> u8 {
    unsafe {
        match adaptive_fec::group_size(tier, default_group_size) {
            // Return `1` only when a size was actually written, so the return is a clean
            // postcondition (`1` ⟺ `*out` holds a valid group size). A null `out` (caller error)
            // yields `0` like the OFF tier — nothing written, no UB.
            Some(g) if !out.is_null() => {
                out.write(g);
                1
            }
            _ => 0,
        }
    }
}

/// Picks the next wire tier from the EWMA `loss` and the `previous_tier` (the plain decider;
/// the production host uses [`aisd_adaptive_fec_next_tier_state`]).
///
/// Wraps [`adaptive_fec::tier`].
/// `allow_off` is the OFF-tier escape hatch resolved by the caller from `AISLOPDESK_FEC_ALLOW_OFF`
/// (read `!= 0`), keeping the core environment-free.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_adaptive_fec_tier(loss: f64, previous_tier: u8, allow_off: u8) -> u8 {
    adaptive_fec::tier(loss, previous_tier, allow_off != 0)
}

/// Dwell-gated tier step — the production entry point.
///
/// Wraps [`adaptive_fec::next_tier_state`]:
/// escalation is immediate (one step, resets the relax streak); relaxation is counted across
/// consecutive relax-demanding reports and applied at the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Returns the next state by value.
/// `allow_off` / `saw_unrecovered_loss` are bytes read `!= 0`; the caller resolves `allow_off`
/// from the environment and passes `dwell`, keeping the core environment-free.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_adaptive_fec_next_tier_state(
    loss: f64,
    state: AisdTierState,
    dwell: i32,
    allow_off: u8,
    saw_unrecovered_loss: u8,
) -> AisdTierState {
    adaptive_fec::next_tier_state(
        loss,
        state.into(),
        dwell,
        allow_off != 0,
        saw_unrecovered_loss != 0,
    )
    .into()
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn adaptive_fec_group_size_matches_core() {
        let mut out: usize = 0;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(0, 5, &mut out) }, 1);
        assert_eq!(out, 5);
        out = 999;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(1, 5, &mut out) }, 0);
        assert_eq!(out, 999, "OFF must not write *out");
        for (tier, def, want) in [
            (2u8, 5usize, 10usize),
            (3, 5, 3),
            (4, 5, 2),
            (5, 5, 5),
            (200, 7, 7),
        ] {
            out = 0;
            assert_eq!(
                unsafe { aisd_adaptive_fec_group_size(tier, def, &mut out) },
                1
            );
            assert_eq!(out, want, "tier {tier} default {def}");
        }
        assert_eq!(
            unsafe { aisd_adaptive_fec_group_size(0, 5, core::ptr::null_mut()) },
            0
        );
    }

    #[test]
    fn adaptive_fec_tier_matches_core() {
        assert_eq!(
            aisd_adaptive_fec_tier(0.10, 0, 0),
            adaptive_fec::tier(0.10, 0, false)
        );
        assert_eq!(aisd_adaptive_fec_tier(0.10, 0, 0), 3);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 0), 2);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 1), 1);
        assert_eq!(
            aisd_adaptive_fec_tier(0.0, 2, 2),
            1,
            "any nonzero allow_off is true"
        );
        assert_eq!(aisd_adaptive_fec_tier(0.015, 0, 0), 0);
    }

    #[test]
    fn adaptive_fec_next_tier_state_matches_core() {
        let dwell = adaptive_fec::RELAX_DWELL_REPORTS;
        let armed = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 0,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            1,
        );
        assert_eq!(
            armed.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS
        );
        let esc = aisd_adaptive_fec_next_tier_state(
            0.10,
            AisdTierState {
                tier: 0,
                relax_streak: 10,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!((esc.tier, esc.relax_streak), (3, 0));
        let core_next = adaptive_fec::next_tier_state(
            0.0,
            adaptive_fec::TierState::new(0, 5, 0),
            dwell,
            false,
            false,
        );
        let ffi_next = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 5,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!(adaptive_fec::TierState::from(ffi_next), core_next);
    }

    #[test]
    fn adaptive_fec_tier_state_repr_round_trips() {
        let s = adaptive_fec::TierState::new(3, 7, 11);
        assert_eq!(adaptive_fec::TierState::from(AisdTierState::from(s)), s);
    }
}
