import Foundation

/// Adaptive FEC (WF-4): chooses the per-frame XOR-parity group size from the
/// host's measured loss, and signals that choice on the wire so the client splits
/// data/parity identically. Two clearly-separated, PURE concerns (mirroring the
/// `NetworkEstimate` / `LiveCongestionController` value-type style):
///
///  A. WIRE CODEC — ``groupSize(forTier:default:)`` maps a 3-bit on-wire tier index
///     (carried in the spare bits of the fragment flags byte) to the group size BOTH
///     ends must use. Used by the host packetizer AND the client reassembler.
///  B. LOSS→TIER DECISION — ``tier(forLossRate:previousTier:)`` (host only) picks the
///     tier from the EWMA loss with hysteresis + a one-step clamp (anti-flap).
///
/// SIGNALLING INVARIANT: tier 0 means "use the endpoint's CONFIGURED default group
/// size" (NOT a hardcoded 5). Production both ends run `XORParityFEC(5)`, so tier 0
/// is byte-identical to today. With `RWORK_ADAPTIVE_FEC` unset the host always sends
/// tier 0, so the spare flags bits stay zero and every frame is wire-identical to the
/// pre-WF-4 path.
public enum AdaptiveFECPolicy {
    /// The default on-wire tier. Tier 0 routes to the endpoint's configured `fec.groupSize`
    /// on BOTH ends (5 in prod), and its bits in the flags byte are all-zero → byte-identical
    /// to the pre-adaptive path when the host always sends it.
    public static let defaultTier: UInt8 = 0

    // MARK: A. Wire codec (host packetize + client reassemble)

    /// Maps a wire tier index to the FEC group size both ends must use, or `nil` for the
    /// OFF (no-parity) tier. TOTAL over EVERY `UInt8` value — a malformed/unknown tier read
    /// off a corrupt fragment can NEVER trap; unknown indices fall back to the default group
    /// size. The fragment flags byte only carries 3 bits (0..7), but this function is defined
    /// for all 256 values defensively.
    ///
    /// - tier 0 → `default` (g5 in prod): the "default" — off-path AND adaptive-medium. Bits 3-5 = 0.
    /// - tier 1 → `nil`  (OFF, no parity): clean link, FEC overhead removed.
    /// - tier 2 → 10  (light, ~10% overhead).
    /// - tier 3 → 3   (heavy, ~33% overhead).
    /// - tier 4 → 2   (severe, 50% overhead).
    /// - tier 5,6,7 and any other value → `default` (reserved → safe default, forward-compatible).
    public static func groupSize(forTier tier: UInt8, default defaultGroupSize: Int) -> Int? {
        switch tier {
        case 1: return nil            // OFF (clean link, no parity)
        case 2: return 10             // light (~10%)
        case 3: return 3              // heavy (~33%)
        case 4: return 2              // severe (50%)
        default: return defaultGroupSize // 0 + reserved 5,6,7 (+ any other) → safe default
        }
    }

    // MARK: B. Loss → tier decision (host only)

    /// Internal redundancy LEVEL, monotonic in loss (0 = least redundancy … 4 = most):
    ///  level 0 = OFF, 1 = g10, 2 = g5 (the default), 3 = g3, 4 = g2.
    /// Decisions step at most ONE level per call; the level↔tier maps below translate to/from
    /// the non-monotonic wire tier numbering (tier 0 must be g5 for byte-identity, so the wire
    /// order is NOT the redundancy order).
    private static func level(forTier tier: UInt8) -> Int {
        switch tier {
        case 1: return 0   // OFF
        case 2: return 1   // g10
        case 0: return 2   // g5 (default)
        case 3: return 3   // g3
        case 4: return 4   // g2
        default: return 2  // reserved → treat as the default/g5 level
        }
    }

    private static func tier(forLevel level: Int) -> UInt8 {
        switch level {
        case 0: return 1   // OFF
        case 1: return 2   // g10
        case 2: return 0   // g5 (default)
        case 3: return 3   // g3
        case 4: return 4   // g2
        default: return 0  // clamp → default
        }
    }

    /// The redundancy level the loss demands, given the current level. Hysteretic:
    /// asymmetric up/down thresholds create a dead-band so a loss oscillating around a
    /// boundary does NOT flap the tier. Within the dead-band the current level holds.
    ///
    /// Up-thresholds (raise redundancy):  ≥0.005→L1, ≥0.02→L2, ≥0.05→L3, ≥0.10→L4.
    /// Down-thresholds (must fall well below to relax): <0.002→L0, <0.012→L1, <0.035→L2, <0.08→L3.
    /// For every adjacent pair the up-threshold strictly exceeds the down-threshold (dead-band),
    /// so `upLevel <= downLevel` always and the two `if`s below are mutually exclusive.
    private static func targetLevel(forLossRate loss: Double, currentLevel current: Int) -> Int {
        let upLevel: Int
        if loss >= 0.10 { upLevel = 4 }
        else if loss >= 0.05 { upLevel = 3 }
        else if loss >= 0.02 { upLevel = 2 }
        else if loss >= 0.005 { upLevel = 1 }
        else { upLevel = 0 }

        let downLevel: Int
        if loss < 0.002 { downLevel = 0 }
        else if loss < 0.012 { downLevel = 1 }
        else if loss < 0.035 { downLevel = 2 }
        else if loss < 0.08 { downLevel = 3 }
        else { downLevel = 4 }

        if upLevel > current { return upLevel }     // loss has risen → demand more redundancy
        if downLevel < current { return downLevel } // loss low enough → relax
        return current                              // dead-band → hold
    }

    /// Picks the next wire tier from the EWMA loss and the previous tier, with hysteresis and a
    /// strict one-level-per-call clamp (anti-flap). The clamp means relaxation toward OFF on a
    /// sustained clean link is GRADUAL (g5→g10→OFF over successive reports) and a loss spike never
    /// jumps multiple levels at once — so it can never "prematurely" jump straight to OFF, and the
    /// host only ever calls this on a real netstats report (inert with no data).
    public static func tier(forLossRate loss: Double, previousTier: UInt8) -> UInt8 {
        let current = level(forTier: previousTier)
        let target = targetLevel(forLossRate: loss, currentLevel: current)
        let stepped: Int
        if target > current { stepped = current + 1 }
        else if target < current { stepped = current - 1 }
        else { stepped = current }
        return tier(forLevel: stepped)
    }
}
