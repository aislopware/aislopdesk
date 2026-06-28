import Foundation

// MARK: - E13 WI-3 (ES-E13-2): the per-pane agent-badge gating policy (Claude-only)

/// The three otty "Agent Behaviour" badge toggles, distilled into a pure value the sidebar applies AFTER
/// the ``TabBadgeResolver`` has fused the live signals into a single badge. The settings UI (global) and a
/// per-pane override both produce one of these; ``RailRowsBuilder`` resolves the effective gates for a pane
/// (override else global default) and runs ``gated(_:by:)`` on the resolver's output.
///
/// **Why a SEPARATE gate, not a resolver argument.** ``TabBadgeResolver/badge(...)`` stays PURE + signal-only
/// (E6) — it knows nothing about user preferences. The user-facing show/hide choice rides here, layered on
/// top, so the resolver's precedence + freshness logic is untouched and unit-pinned independently.
///
/// **What the gates DROP.** Each toggle hides exactly its own badge family and nothing else:
///  - `badgeWhileProcessing == false` → drop ``TabBadgeKind/running`` (the spinner).
///  - `badgeWhenComplete == false`    → drop ``TabBadgeKind/completed`` + ``TabBadgeKind/finished``.
///  - `badgeWhenAwaitingInput == false` → drop ``TabBadgeKind/awaitingInput`` (the hand).
///
/// **What the gates NEVER drop.** ``TabBadgeKind/error`` (a failed command demands attention regardless),
/// and the privilege badges ``TabBadgeKind/sudo`` / ``TabBadgeKind/caffeinate`` (a security / sleep-blocking
/// signal is not an "agent badge" the user opted out of) always survive — these are not agent-progress
/// chatter, so the agent-badge toggles must not silence them.
public struct AgentBadgeGates: Equatable, Sendable {
    /// Show the ``TabBadgeKind/running`` spinner while a command / agent is processing (otty
    /// "Badge while processing"). Default ON.
    public var badgeWhileProcessing: Bool
    /// Show the ``TabBadgeKind/completed`` checkmark flash + the settled ``TabBadgeKind/finished`` dot when a
    /// command exits 0 / an agent finishes its turn (otty "Badge when complete"). Default ON.
    public var badgeWhenComplete: Bool
    /// Show the ``TabBadgeKind/awaitingInput`` hand when a blocked agent / interactive prompt needs a human
    /// (otty "Badge when awaiting input"). Default ON.
    public var badgeWhenAwaitingInput: Bool

    public init(
        badgeWhileProcessing: Bool = true,
        badgeWhenComplete: Bool = true,
        badgeWhenAwaitingInput: Bool = true,
    ) {
        self.badgeWhileProcessing = badgeWhileProcessing
        self.badgeWhenComplete = badgeWhenComplete
        self.badgeWhenAwaitingInput = badgeWhenAwaitingInput
    }

    /// All three gates ON — the global default before any settings change / per-pane override (every agent
    /// badge shows, byte-identical to the pre-E13 rail).
    public static let allOn = Self()

    /// Apply the gates to one already-resolved badge. Returns `nil` (no badge) when the toggle for the
    /// badge's family is OFF; returns the badge unchanged when its family is ON, or when the badge is an
    /// always-on family (error / sudo / caffeinate). A `nil` input passes through as `nil`.
    public static func gated(_ kind: TabBadgeKind?, by gates: Self) -> TabBadgeKind? {
        guard let kind else { return nil }
        switch kind {
        case .running:
            return gates.badgeWhileProcessing ? kind : nil
        case .completed,
             .finished:
            return gates.badgeWhenComplete ? kind : nil
        case .awaitingInput:
            return gates.badgeWhenAwaitingInput ? kind : nil
        case .error,
             .sudo,
             .caffeinate:
            // Never silenced by an agent-badge toggle: an error / privilege / sleep-block is not opt-out
            // agent-progress chatter.
            return kind
        }
    }

    /// Returns a copy with one gate flipped — the per-pane override the tab context-menu toggle writes.
    public func toggling(_ gate: AgentBadgeGate) -> Self {
        var copy = self
        switch gate {
        case .whileProcessing: copy.badgeWhileProcessing.toggle()
        case .whenComplete: copy.badgeWhenComplete.toggle()
        case .whenAwaitingInput: copy.badgeWhenAwaitingInput.toggle()
        }
        return copy
    }
}

/// Identifies one of the three ``AgentBadgeGates`` toggles — the selector the tab context-menu uses to flip
/// a single per-pane override bit.
public enum AgentBadgeGate: Sendable, CaseIterable {
    case whileProcessing
    case whenComplete
    case whenAwaitingInput
}
