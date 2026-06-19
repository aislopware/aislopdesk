import Foundation

/// A PURE, deterministic per-pane Claude-status state machine (docs/41 §4.3, docs/42 W7).
///
/// **Clock is injected.** Every `reduce` takes an absolute `now: TimeInterval`; the
/// machine NEVER calls `Date()`/`Date.now` (it imports Foundation only for `TimeInterval`,
/// a plain `Double`). This keeps tests deterministic and honours the repo's no-wall-clock
/// convention. The only time-driven transition is `done → idle` after `doneToIdleTimeout`,
/// fired on a `tick` (or any signal) whose `now` reaches the deadline.
///
/// **Signal precedence (defense-in-depth, docs/41 §4.2).**
/// 1. `processPresent(false)` / `sessionEnd` → `.none` (termination wins, clears all state).
/// 2. Authoritative HOOK events set the status directly (UserPrompt/PreTool → working;
///    Notification(permission|waiting) → needsPermission; Stop → done; SessionStart → idle).
/// 3. `processPresent(true)` / OSC `Claude:` title → presence FLOOR `.idle` (only lifts
///    `.none`; never downgrades a richer hook status).
/// 4. `manifestVerdict` (the no-hooks fallback) is CONSERVATIVE: a `.none` verdict is
///    ignored; `.working`/`.needsPermission` apply ONLY when an authoritative hook block
///    is not already in effect.
///
/// `mutating func reduce(_:at:)` returns the new `ClaudeStatus`. Idempotent on duplicate
/// signals; out-of-order / unknown signals never trap (validate-then-drop).
public struct ClaudeStatusMachine: Sendable, Equatable {
    /// Seconds a `.done` status lingers before decaying to `.idle` (docs/41 §4.3 done→idle).
    public let doneToIdleTimeout: TimeInterval

    /// Current rolled-up status.
    public private(set) var status: ClaudeStatus

    /// A short human label (≤ `maxLabel` chars) — last assistant message / permission prompt
    /// text — for the pane chrome chip. `nil` when there is nothing to show.
    public private(set) var label: String?

    /// Absolute time the status entered `.done` (the done→idle decay anchor). `nil` otherwise.
    private var doneSince: TimeInterval?

    /// Whether an authoritative hook block is in effect — a conservative manifest verdict
    /// must not clear it. Set on Notification(permission|waiting), cleared on any
    /// authoritative working/idle/done/terminal transition.
    private var hookBlocked: Bool

    /// Cap for `label` — keeps the chip bounded regardless of a hostile/huge hook body.
    public static let maxLabel = 120

    public init(doneToIdleTimeout: TimeInterval = 8) {
        // Ordered max guards a negative / NaN injected timeout (validate-then-clamp; ordered
        // min/max per the repo's NaN-faithful convention, never a bare `<` ternary).
        self.doneToIdleTimeout = Double.maximum(0, doneToIdleTimeout)
        status = .none
        label = nil
        doneSince = nil
        hookBlocked = false
    }

    /// Fold one signal at absolute time `now`, returning the new status.
    @discardableResult
    public mutating func reduce(_ signal: ClaudeSignal, at now: TimeInterval) -> ClaudeStatus {
        switch signal {
        case let .processPresent(present):
            if present {
                liftPresenceFloor()
            } else {
                terminate()
            }

        case let .hook(event):
            apply(event, at: now)

        case let .manifestVerdict(verdict):
            applyManifest(verdict)

        case let .oscTitle(title):
            if Self.titleNamesClaude(title) { liftPresenceFloor() }

        case .tick:
            break // pure time advance; decay handled below
        }

        decayIfDue(now: now)
        return status
    }

    // MARK: - Hook events (authoritative)

    private mutating func apply(_ event: ClaudeHookEvent, at now: TimeInterval) {
        switch event {
        case .sessionStart:
            // Session opened → present & at rest. Clears any stale block/label.
            enter(.idle, label: nil)

        case .userPromptSubmit:
            enter(.working, label: nil)

        case .preToolUse:
            // A tool starting resolves a just-answered permission prompt → working. The raw
            // tool name is not useful chip text (the meaningful label is the Stop message), so
            // working transitions CLEAR the label.
            enter(.working, label: nil)

        case .postToolUse:
            // A tool result is mid-turn → keep working (don't fall back to idle/done here).
            enter(.working, label: nil)

        case let .notification(kind, label):
            switch kind {
            case .permission,
                 .waitingForInput:
                enterBlocked(label: label)
            case .other:
                // Informational (auth_success / elicitation_complete) — no status change,
                // but it does corroborate presence (lift the floor off `.none`).
                liftPresenceFloor()
            }

        case let .stop(_, label):
            enter(.done, label: label, at: now)

        case .subagentStop:
            // A subagent stopping does not change the parent pane's coarse status.
            break

        case .sessionEnd:
            terminate()
        }
    }

    // MARK: - Manifest verdict (conservative fallback)

    private mutating func applyManifest(_ verdict: ClaudeStatus) {
        switch verdict {
        case .none:
            // Unsure → never downgrade; presence is the floor.
            break
        case .needsPermission:
            // Only the manifest's strongest, conservative signal (a known approval UI).
            enterBlocked(label: label)
        case .working:
            // A coarse "working" guess must NOT clear an authoritative hook block.
            if !hookBlocked { enter(.working, label: nil) }
        case .idle:
            if !hookBlocked, status == .none { enter(.idle, label: nil) }
        case .done:
            if !hookBlocked { enter(.done, label: label, at: nil) }
        }
    }

    // MARK: - State entry helpers

    /// Presence floor — lift `.none` to `.idle`; never downgrade a richer status.
    private mutating func liftPresenceFloor() {
        if status == .none { enter(.idle, label: nil) }
    }

    private mutating func enterBlocked(label: String?) {
        hookBlocked = true
        doneSince = nil
        status = .needsPermission
        if let label { self.label = Self.clampLabel(label) }
    }

    /// Enter a non-blocked status. `at` non-nil marks the done-decay anchor.
    private mutating func enter(_ next: ClaudeStatus, label newLabel: String?, at now: TimeInterval? = nil) {
        hookBlocked = false
        status = next
        label = newLabel.map(Self.clampLabel)
        if next == .done {
            doneSince = now
        } else {
            doneSince = nil
        }
    }

    private mutating func terminate() {
        status = .none
        label = nil
        doneSince = nil
        hookBlocked = false
    }

    // MARK: - Time-based decay (injected clock)

    private mutating func decayIfDue(now: TimeInterval) {
        guard status == .done, let since = doneSince else { return }
        // Ordered comparison; decay once the elapsed time reaches the timeout.
        let elapsed = now - since
        if elapsed >= doneToIdleTimeout {
            enter(.idle, label: nil)
        }
    }

    // MARK: - Helpers

    private static func clampLabel(_ s: String) -> String {
        // Bound the chip text; validate-then-clamp on a hostile/huge body. Empty → nil.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= maxLabel { return trimmed }
        return String(trimmed.prefix(maxLabel))
    }

    /// True when an OSC 2 title names Claude (e.g. `Claude: my-project`, `✳ Claude Code`).
    static func titleNamesClaude(_ title: String) -> Bool {
        title.range(of: "claude", options: .caseInsensitive) != nil
    }
}

public extension ClaudeStatusMachine {
    /// Convenience: the label, but `nil` when it is empty (the clamp can yield "").
    var displayLabel: String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }
}
