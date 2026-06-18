//! Adaptive FEC (WF-4) — the canonical `AdaptiveFECPolicy` logic (the Swift shell mirrors it).
//!
//! Two PURE concerns:
//!  * **wire codec** — [`group_size`] maps a 3-bit on-wire tier to the group size both
//!    ends must use; used by the host packetizer AND the client reassembler.
//!  * **loss→tier decision** (host only) — [`tier`] / [`next_tier_state`] pick the tier
//!    from the EWMA loss with hysteresis, a one-step-per-call clamp, a relax dwell, and
//!    a sticky-relax window after an unrecovered loss.
//!
//! Tier 0 means "use the endpoint's configured default group size" (NOT a hardcoded 5)
//! and its flag bits are all-zero, so an unflagged host is byte-identical to today.

/// The default on-wire tier. Routes to the endpoint's configured `fec.group_size()` on
/// both ends; its flag bits are all-zero.
pub const DEFAULT_TIER: u8 = 0;

/// How many consecutive relax-demanding reports must accumulate before the tier steps
/// DOWN one level (escalation stays immediate). ~12s at the ~2/s netstats cadence.
pub const RELAX_DWELL_REPORTS: i32 = 24;

/// After any report carrying unrecovered loss, the relax dwell is DOUBLED for this many
/// reports. `2 × dwell` by construction (a shorter window could never gate a streak).
pub const STICKY_RELAX_WINDOW_REPORTS: i32 = 2 * RELAX_DWELL_REPORTS;

/// Maps a wire tier index to the FEC group size both ends must use, or `None` for the
/// OFF (no-parity) tier.
///
/// TOTAL over every `u8` — a malformed tier off a corrupt fragment
/// can never trap; unknown indices fall back to `default_group_size`.
///
/// * tier 0 → `default` (g5 in prod) — flag bits 3-5 = 0.
/// * tier 1 → `None` (OFF, no parity).
/// * tier 2 → 10 (light, ~10%).
/// * tier 3 → 3 (heavy, ~33%).
/// * tier 4 → 2 (severe, 50%).
/// * tier 5,6,7 and any other → `default` (reserved → safe, forward-compatible).
#[must_use]
pub const fn group_size(tier: u8, default_group_size: usize) -> Option<usize> {
    match tier {
        1 => None,
        2 => Some(10),
        3 => Some(3),
        4 => Some(2),
        _ => Some(default_group_size),
    }
}

/// Wire FEC tier for the ADAPTIVE-`m` ladder's CLEAN level → parity `m` = [`PARITY_M_CLEAN`].
///
/// Picked from the three reserved tier slots (5/6/7), all of which [`group_size`] maps to the
/// endpoint default (`= k`) — the hard `m > 1` constraint (the Cauchy encoder has exactly `k`
/// columns; tiers 2/3/4 map to `g != k` and so can NOT carry `m > 1`).
pub const PARITY_TIER_CLEAN: u8 = 5;
/// Wire FEC tier for the adaptive-`m` ladder's NORMAL/baseline level → `m` = [`PARITY_M_NORMAL`].
pub const PARITY_TIER_NORMAL: u8 = 6;
/// Wire FEC tier for the adaptive-`m` ladder's BURST level → `m` = [`PARITY_M_BURST`].
pub const PARITY_TIER_BURST: u8 = 7;

/// Parity shards per group at the adaptive ladder's CLEAN level (least overhead; 2-loss
/// recovery per group, which interleaving spreads bursts into).
pub const PARITY_M_CLEAN: usize = 2;
/// Parity shards per group at the NORMAL/baseline level (matches the legacy fixed `FEC_M=3`).
pub const PARITY_M_NORMAL: usize = 3;
/// Parity shards per group at the BURST level (heavy recovery for the rare big loss burst).
pub const PARITY_M_BURST: usize = 5;

/// Maps a wire tier index to the number of parity shards per group (the code's `m`) the
/// receive path must expect.
///
/// TOTAL over every `u8` — a malformed tier off a corrupt fragment can never trap.
///
/// CRITICAL byte-identity invariant: with the production `default_m == 1` (the XOR/`m == 1`
/// codec) EVERY tier resolves to `m == 1`, so a single-parity host/client is unaffected — the
/// `m > 1` tier slots are GATED on `default_m >= 2`, which only the multi-loss / adaptive-`m`
/// codec supplies. A production XOR host never emits tiers 5/6/7 (its ladder produces only the
/// group-size tiers 0–4), so those slots are reached only by an adaptive-`m` host paired with an
/// adaptive-`m` client (deploy-together, matched `FEC_M >= 2`) — no mixed-fleet hazard.
///
/// * tier 1 (OFF) → `1` (no parity is sent, so `m` is moot; pinned to the byte-identical `1`).
/// * tiers 5/6/7, only when `default_m >= 2` → [`PARITY_M_CLEAN`] / [`PARITY_M_NORMAL`] /
///   [`PARITY_M_BURST`] (the adaptive ladder's three levels; the group size for all three is `k`).
/// * every other tier (and 5/6/7 when `default_m == 1`) → `default_m`.
#[must_use]
pub const fn parity_count(tier: u8, default_m: usize) -> usize {
    match tier {
        // The OFF tier sends no parity at all; its `m` is never consulted, but pin it to the
        // byte-identical 1 so a future table edit can't accidentally imply parity on an OFF frame.
        1 => 1,
        // Adaptive-m ladder levels — gated on a multi-loss codec so the production XOR path
        // (default_m == 1) stays byte-identical (every tier → m == 1).
        PARITY_TIER_CLEAN if default_m >= 2 => PARITY_M_CLEAN,
        PARITY_TIER_NORMAL if default_m >= 2 => PARITY_M_NORMAL,
        PARITY_TIER_BURST if default_m >= 2 => PARITY_M_BURST,
        _ => default_m,
    }
}

/// Pure resolution of the OFF-tier escape hatch (`AISLOPDESK_FEC_ALLOW_OFF=1`), testable
/// without process state.
#[must_use]
pub fn allow_off_tier(env_value: Option<&str>) -> bool {
    env_value == Some("1")
}

/// Reads the OFF-tier escape hatch from the live process environment.
#[must_use]
pub fn allow_off_tier_from_env() -> bool {
    allow_off_tier(std::env::var("AISLOPDESK_FEC_ALLOW_OFF").ok().as_deref())
}

/// Internal redundancy LEVEL (0 = least redundancy … 4 = most): 0=OFF, 1=g10, 2=g5
/// (default), 3=g3, 4=g2. The wire tier numbering is NOT the redundancy order (tier 0
/// must be g5 for byte-identity), so these maps translate between them.
#[allow(clippy::match_same_arms)] // explicit documentary mapping (matches the Swift shell's table).
const fn level_for_tier(tier: u8) -> i32 {
    match tier {
        1 => 0, // OFF
        2 => 1, // g10
        0 => 2, // g5 (default)
        3 => 3, // g3
        4 => 4, // g2
        _ => 2, // reserved → default/g5 level
    }
}

#[allow(clippy::match_same_arms)] // explicit documentary mapping (matches the Swift shell's table).
const fn tier_for_level(level: i32) -> u8 {
    match level {
        0 => 1, // OFF
        1 => 2, // g10
        2 => 0, // g5 (default)
        3 => 3, // g3
        4 => 4, // g2
        _ => 0, // clamp → default
    }
}

#[allow(clippy::bool_to_int_with_if)] // explicit form documents the floor LEVELS, not a cast.
const fn relax_floor_level(allow_off: bool) -> i32 {
    if allow_off { 0 } else { 1 }
}

/// The redundancy level the loss demands, given the current level. Hysteretic:
/// asymmetric up/down thresholds create a dead-band so a loss oscillating around a
/// boundary does not flap the tier.
#[allow(clippy::bool_to_int_with_if)] // a threshold LADDER reads clearer than a cast on the tail arms.
fn target_level(loss: f64, current: i32) -> i32 {
    let up_level = if loss >= 0.10 {
        4
    } else if loss >= 0.05 {
        3
    } else if loss >= 0.02 {
        2
    } else if loss >= 0.005 {
        1
    } else {
        0
    };

    let down_level = if loss < 0.002 {
        0
    } else if loss < 0.012 {
        1
    } else if loss < 0.035 {
        2
    } else if loss < 0.08 {
        3
    } else {
        4
    };

    if up_level > current {
        up_level // loss has risen → demand more redundancy
    } else if down_level < current {
        down_level // loss low enough → relax
    } else {
        current // dead-band → hold
    }
}

/// Picks the next wire tier from the EWMA loss and the previous tier, with hysteresis
/// and a strict one-level-per-call clamp (anti-flap).
///
/// Relaxation floors at level 1 (g10)
/// unless `allow_off`. (The plain decider; production uses [`next_tier_state`].)
#[must_use]
pub fn tier(loss: f64, previous_tier: u8, allow_off: bool) -> u8 {
    let current = level_for_tier(previous_tier);
    let target = target_level(loss, current).max(relax_floor_level(allow_off));
    let stepped = match target.cmp(&current) {
        std::cmp::Ordering::Greater => current + 1,
        std::cmp::Ordering::Less => current - 1,
        std::cmp::Ordering::Equal => current,
    };
    tier_for_level(stepped)
}

/// Tier decision state for the dwell-gated variant: the current wire tier, the count of
/// consecutive relax-demanding reports, and the sticky-relax countdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierState {
    /// Current wire tier.
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
}

impl Default for TierState {
    fn default() -> Self {
        Self {
            tier: DEFAULT_TIER,
            relax_streak: 0,
            sticky_relax_remaining: 0,
        }
    }
}

impl TierState {
    /// Builds an explicit tier state.
    #[must_use]
    pub const fn new(tier: u8, relax_streak: i32, sticky_relax_remaining: i32) -> Self {
        Self {
            tier,
            relax_streak,
            sticky_relax_remaining,
        }
    }
}

/// Dwell-gated tier step — the production entry point.
///
/// Escalation is immediate (one step,
/// resets the relax streak); relaxation is counted across consecutive relax-demanding
/// reports and applied only when the streak reaches the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Any non-relax report resets the
/// streak. Relaxation floors at level 1 (g10) unless `allow_off`.
#[must_use]
pub fn next_tier_state(
    loss: f64,
    state: TierState,
    dwell: i32,
    allow_off: bool,
    saw_unrecovered_loss: bool,
) -> TierState {
    let sticky = if saw_unrecovered_loss {
        STICKY_RELAX_WINDOW_REPORTS
    } else {
        (state.sticky_relax_remaining - 1).max(0)
    };
    let effective_dwell = if sticky > 0 { 2 * dwell } else { dwell };
    let current = level_for_tier(state.tier);
    let target = target_level(loss, current).max(relax_floor_level(allow_off));

    if target > current {
        return TierState::new(tier_for_level(current + 1), 0, sticky);
    }
    if target < current {
        let streak = state.relax_streak + 1;
        if streak >= effective_dwell.max(1) {
            return TierState::new(tier_for_level(current - 1), 0, sticky);
        }
        return TierState::new(state.tier, streak, sticky);
    }
    TierState::new(state.tier, 0, sticky)
}

// ============================================================================
// Adaptive PARITY-COUNT ladder (the m-adaptive path).
//
// A SEPARATE ladder from the group-size one above: instead of changing the XOR group size at a
// fixed m == 1, it keeps the group size at `k` and changes the parity multiplicity `m` per frame
// (via tiers 5/6/7 → [`PARITY_M_CLEAN`]/`_NORMAL`/`_BURST`). It reuses the same hysteresis +
// dwell + sticky-relax machinery (so a loss burst escalates `m` immediately and a clean link
// relaxes `m` only after a sustained quiet streak), but over 3 redundancy levels (0=clean,
// 1=normal, 2=burst) with NO OFF tier — the floor is the CLEAN level (m == 2), since this path
// runs only on a link already known to need multi-loss recovery.
// ============================================================================

/// Internal redundancy LEVEL for the parity-count ladder (0 = least `m` … 2 = most): 0=clean
/// (m2, tier 5), 1=normal (m3, tier 6), 2=burst (m5, tier 7). Any other tier (a corrupt read,
/// or a group-size tier) maps to the NORMAL baseline.
const fn m_level_for_tier(tier: u8) -> i32 {
    match tier {
        PARITY_TIER_CLEAN => 0,
        PARITY_TIER_BURST => 2,
        _ => 1, // PARITY_TIER_NORMAL and any other → baseline
    }
}

const fn tier_for_m_level(level: i32) -> u8 {
    match level {
        0 => PARITY_TIER_CLEAN,
        2 => PARITY_TIER_BURST,
        _ => PARITY_TIER_NORMAL, // 1 and any clamp → baseline
    }
}

/// The parity redundancy level the loss demands, given the current level. Hysteretic:
/// asymmetric up/down thresholds create a dead-band so a loss oscillating around a boundary
/// does not flap the level.
///
/// Up-thresholds (raise `m`): ≥0.005 → L1, ≥0.03 → L2.
/// Down-thresholds (relax `m`): <0.002 → L0, <0.02 → L1.
/// For each adjacent boundary the up-threshold strictly exceeds the down-threshold (dead-band).
#[allow(clippy::bool_to_int_with_if)] // a threshold ladder reads clearer than a cast.
fn m_target_level(loss: f64, current: i32) -> i32 {
    let up_level = if loss >= 0.03 {
        2
    } else if loss >= 0.005 {
        1
    } else {
        0
    };
    let down_level = if loss < 0.002 {
        0
    } else if loss < 0.02 {
        1
    } else {
        2
    };
    if up_level > current {
        up_level
    } else if down_level < current {
        down_level
    } else {
        current
    }
}

/// Dwell-gated parity-tier step — the m-adaptive counterpart of [`next_tier_state`], with an
/// asymmetric FAST-ATTACK / slow-decay response tuned for burst loss.
///
/// ESCALATION jumps STRAIGHT to the level the loss demands in ONE report (not one step at a
/// time) — a burst should be at full parity by its *second* frame, not three reports later — and
/// any `saw_unrecovered_loss` this report forces at least the NORMAL level (`m == 3`) regardless
/// of the EWMA, because the loss EWMA lags a fresh burst by a report or two while a real dropped
/// frame is instant evidence. (NORMAL is the floor on a real loss, not BURST, so a single
/// isolated drop on an otherwise-clean link does not pin max parity; sustained loss climbs the
/// EWMA to BURST.) Escalation resets the relax streak.
///
/// RELAXATION stays gradual and conservative: one level per report, gated on the relax dwell
/// (doubled while a sticky window from a recent unrecovered loss is open) — so the link gives up
/// hard-won protection slowly. The floor is the CLEAN level (`m == 2`); there is no OFF tier.
#[must_use]
pub fn next_parity_tier_state(
    loss: f64,
    state: TierState,
    dwell: i32,
    saw_unrecovered_loss: bool,
) -> TierState {
    let sticky = if saw_unrecovered_loss {
        STICKY_RELAX_WINDOW_REPORTS
    } else {
        (state.sticky_relax_remaining - 1).max(0)
    };
    let effective_dwell = if sticky > 0 { 2 * dwell } else { dwell };
    let current = m_level_for_tier(state.tier);
    // Fast-attack: a real dropped frame floors the demand at NORMAL even before the EWMA reacts.
    let target = if saw_unrecovered_loss {
        m_target_level(loss, current).max(1)
    } else {
        m_target_level(loss, current)
    };

    if target > current {
        // Jump straight to the demanded level (not one step) — full parity by the next frame.
        return TierState::new(tier_for_m_level(target), 0, sticky);
    }
    if target < current {
        let streak = state.relax_streak + 1;
        if streak >= effective_dwell.max(1) {
            return TierState::new(tier_for_m_level(current - 1), 0, sticky);
        }
        return TierState::new(state.tier, streak, sticky);
    }
    TierState::new(state.tier, 0, sticky)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_size_wire_table() {
        assert_eq!(group_size(0, 5), Some(5));
        assert_eq!(group_size(1, 5), None);
        assert_eq!(group_size(2, 5), Some(10));
        assert_eq!(group_size(3, 5), Some(3));
        assert_eq!(group_size(4, 5), Some(2));
        // reserved + any other → default
        assert_eq!(group_size(5, 5), Some(5));
        assert_eq!(group_size(200, 7), Some(7));
    }

    #[test]
    fn parity_count_every_current_tier_is_m1() {
        // The load-bearing invariant: with the production default_m == 1, EVERY tier that
        // exists on the wire today resolves to m == 1 — no current frame changes behavior.
        for tier in 0u8..=7 {
            assert_eq!(
                parity_count(tier, 1),
                1,
                "tier {tier} must be m=1 with default_m=1 (no wire change today)"
            );
        }
        // And across the full u8 range a corrupt tier never traps and stays at the default.
        for tier in 0u8..=255 {
            assert_eq!(parity_count(tier, 1), 1, "tier {tier} m=1 default");
        }
    }

    #[test]
    fn parity_count_honours_a_test_only_default_m() {
        // With a multi-loss codec (default_m >= 2) the non-ladder tiers follow default_m; the OFF
        // tier (1) stays pinned to 1.
        assert_eq!(parity_count(0, 3), 3, "tier 0 = baseline = default_m");
        assert_eq!(parity_count(2, 2), 2, "group-size tier follows default_m");
        assert_eq!(parity_count(1, 4), 1, "OFF tier never implies parity");
    }

    #[test]
    fn parity_count_adaptive_m_ladder_tiers() {
        // The adaptive-m ladder tiers (5/6/7) resolve to their explicit m ONLY on a multi-loss
        // codec (default_m >= 2); on the production XOR codec (default_m == 1) they stay m == 1
        // so a single-parity fleet is byte-identical (covered by the all-tiers-m1 test below).
        assert_eq!(parity_count(PARITY_TIER_CLEAN, 3), PARITY_M_CLEAN); // 5 → 2
        assert_eq!(parity_count(PARITY_TIER_NORMAL, 3), PARITY_M_NORMAL); // 6 → 3
        assert_eq!(parity_count(PARITY_TIER_BURST, 3), PARITY_M_BURST); // 7 → 5
        // Independent of the exact default_m (any >= 2): the ladder m values are absolute so the
        // host and client agree regardless of the configured FEC_M.
        assert_eq!(parity_count(PARITY_TIER_BURST, 2), PARITY_M_BURST);
        // Gated off on the single-parity codec.
        assert_eq!(parity_count(PARITY_TIER_CLEAN, 1), 1);
        assert_eq!(parity_count(PARITY_TIER_BURST, 1), 1);
    }

    #[test]
    fn parity_ladder_fast_attack_jumps_straight_to_burst() {
        // FAST-ATTACK: a heavy burst (loss >= 0.03 → demand level 2) jumps STRAIGHT from CLEAN to
        // BURST in ONE report (not one step at a time) — full parity by the next frame.
        let s0 = TierState::new(PARITY_TIER_CLEAN, 0, 0); // start clean (m2)
        let s1 = next_parity_tier_state(0.05, s0, RELAX_DWELL_REPORTS, false);
        assert_eq!(
            s1.tier, PARITY_TIER_BURST,
            "clean → BURST in one report (jump, not step)"
        );
        // A moderate loss (0.005..0.02 → demand level 1) jumps to exactly NORMAL.
        let s = next_parity_tier_state(
            0.01,
            TierState::new(PARITY_TIER_CLEAN, 0, 0),
            RELAX_DWELL_REPORTS,
            false,
        );
        assert_eq!(s.tier, PARITY_TIER_NORMAL, "moderate loss → NORMAL");
        // A real dropped frame floors the demand at NORMAL even when the EWMA is still ~0 (the
        // EWMA lags a fresh burst; an actual loss is instant evidence).
        let s = next_parity_tier_state(
            0.0,
            TierState::new(PARITY_TIER_CLEAN, 0, 0),
            RELAX_DWELL_REPORTS,
            true,
        );
        assert_eq!(
            s.tier, PARITY_TIER_NORMAL,
            "unrecovered loss floors at NORMAL despite loss EWMA ~0"
        );
        // On a clean link it relaxes only after the dwell, and floors at CLEAN (never OFF).
        let mut s = TierState::new(PARITY_TIER_BURST, 0, 0);
        for _ in 0..(RELAX_DWELL_REPORTS - 1) {
            s = next_parity_tier_state(0.0, s, RELAX_DWELL_REPORTS, false);
            assert_eq!(s.tier, PARITY_TIER_BURST, "holds before dwell elapses");
        }
        s = next_parity_tier_state(0.0, s, RELAX_DWELL_REPORTS, false);
        assert_eq!(s.tier, PARITY_TIER_NORMAL, "relaxes one level after dwell");
        // Drive all the way down: floor is CLEAN, it never relaxes past it.
        let mut s = TierState::new(PARITY_TIER_CLEAN, 0, 0);
        for _ in 0..(4 * RELAX_DWELL_REPORTS) {
            s = next_parity_tier_state(0.0, s, RELAX_DWELL_REPORTS, false);
        }
        assert_eq!(
            s.tier, PARITY_TIER_CLEAN,
            "clean is the floor (no OFF on this path)"
        );
    }

    #[test]
    fn parity_ladder_dead_band_holds_and_sticky_doubles_dwell() {
        // A loss inside the L1↔L2 dead-band (0.02..0.03) from NORMAL holds.
        let s = TierState::new(PARITY_TIER_NORMAL, 0, 0);
        assert_eq!(
            next_parity_tier_state(0.025, s, RELAX_DWELL_REPORTS, false).tier,
            PARITY_TIER_NORMAL
        );
        // An unrecovered-loss report arms the sticky window (doubled relax dwell).
        let armed = next_parity_tier_state(0.0, TierState::default(), RELAX_DWELL_REPORTS, true);
        assert_eq!(armed.sticky_relax_remaining, STICKY_RELAX_WINDOW_REPORTS);
    }

    #[test]
    fn escalation_is_immediate_one_step() {
        // From tier 0 (level 2 = g5), a 10% loss demands level 4; one step → level 3 = tier 3.
        assert_eq!(tier(0.10, 0, false), 3);
    }

    #[test]
    fn relax_floors_at_g10_by_default() {
        // From tier 2 (level 1 = g10) on a clean link, default floor blocks OFF → stays g10.
        assert_eq!(tier(0.0, 2, false), 2);
        // With the escape hatch, it can relax to OFF (level 0 = tier 1).
        assert_eq!(tier(0.0, 2, true), 1);
    }

    #[test]
    fn dead_band_holds() {
        // tier 0 = level 2; a loss inside the dead-band (0.012..0.02) holds.
        assert_eq!(tier(0.015, 0, false), 0);
    }

    #[test]
    fn dwell_gates_relaxation() {
        // Start at g5 (tier 0, level 2). Clean reports should relax to g10 (tier 2) only
        // after RELAX_DWELL_REPORTS consecutive relax-demanding reports.
        let mut state = TierState::default();
        for _ in 0..(RELAX_DWELL_REPORTS - 1) {
            state = next_tier_state(0.0, state, RELAX_DWELL_REPORTS, false, false);
            assert_eq!(state.tier, 0, "should still hold before dwell elapses");
        }
        state = next_tier_state(0.0, state, RELAX_DWELL_REPORTS, false, false);
        assert_eq!(state.tier, 2, "relaxes one level after dwell");
    }

    #[test]
    fn unrecovered_loss_doubles_dwell() {
        let armed = next_tier_state(0.0, TierState::default(), RELAX_DWELL_REPORTS, false, true);
        assert_eq!(armed.sticky_relax_remaining, STICKY_RELAX_WINDOW_REPORTS);
    }

    #[test]
    fn escalation_resets_relax_streak() {
        let mut state = TierState::new(0, 10, 0);
        // a report demanding escalation resets the streak to 0.
        state = next_tier_state(0.10, state, RELAX_DWELL_REPORTS, false, false);
        assert_eq!(state.relax_streak, 0);
        assert_eq!(state.tier, 3);
    }
}
