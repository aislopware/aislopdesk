import AislopdeskAgentDetect
import Foundation

// MARK: - ForkSessionDetector (the pure "a /branch minted a new session" decision)

/// The PURE Fork/Branch detector (E13, WI-7, ES-E13-7): given the previously-known Claude session id for a
/// pane and an incoming ``ClaudeSignal``, decide whether the signal advertises a NEW (different) session id —
/// the wire-level fingerprint of an in-place `/branch` (Claude Code copies the conversation up to the
/// invocation point into a brand-new session, which announces itself with a fresh `SessionStart` carrying a
/// new id while the original keeps running). The owning ``LivePaneSession`` runs this off the inspector
/// channel's session-id stream (reusing the ``AislopdeskAgentDetect`` `ClaudeSignal` vocabulary, NOT a new
/// parser) and records the returned id as the pane's pending fork target.
///
/// **Claude-only** (E13 BINDING directive 1): `/branch` is the Claude-Code fork verb; there is no branch on
/// ``MetadataCodec/AgentKind`` (codex / opencode are never surfaced in any agent UI). The detected id is later
/// run VERBATIM as `claude --resume <id>` via ``AgentResumeRouter`` — never through ``SendKeysParser`` (the
/// standing injection-safety invariant shared with ``AgentResumeRouter`` / ``PeekReplyFormatter`` /
/// ``SendToChatModel``).
///
/// A pure value enum (no SwiftUI / store / `AislopdeskTerminal` import) so the change-detection is unit-tested
/// from a before/after signal pair with no view. `#if`-unguarded so it compiles + tests on every platform.
public enum ForkSessionDetector {
    /// The Claude session id a `signal` is ABOUT, if any. Only ``ClaudeSignal/hook(_:)`` events that carry a
    /// `sessionID:` advertise one (a presence / manifest / OSC-title / tick signal references no session); a
    /// `notification` / `subagentStop` hook carries no Claude session id either. A `nil`/empty id is treated
    /// as "no id" (a hook with a missing session id can never look like a fork). Pure — the change decision
    /// in ``detectNewSession(previous:signal:)`` is built on top of this single extraction.
    public static func sessionID(in signal: ClaudeSignal) -> String? {
        guard case let .hook(event) = signal else { return nil }
        switch event {
        case let .sessionStart(id),
             let .userPromptSubmit(id),
             let .stop(id, _),
             let .sessionEnd(id):
            return normalized(id)
        case let .preToolUse(id, _),
             let .postToolUse(id, _):
            return normalized(id)
        case .notification,
             .subagentStop:
            return nil
        }
    }

    /// The NEW session id `signal` advertises iff it DIFFERS from `previous` (a pure change-detector). Returns
    /// `nil` when the signal carries no session id, or carries the SAME id already known (no change). A
    /// `previous == nil` first sighting therefore returns that first id (a `nil → id` change) — the CALLER
    /// (``LivePaneSession``) decides whether that is the pane's BASELINE session (its first claude) or a
    /// genuine `/branch` (a different id appearing AFTER a baseline was already established): only the latter
    /// arms the fork action.
    public static func detectNewSession(previous: String?, signal: ClaudeSignal) -> String? {
        guard let id = sessionID(in: signal) else { return nil }
        guard id != previous else { return nil }
        return id
    }

    /// Trims an optional id to `nil` when absent or empty (so `""` / whitespace never reads as a session id).
    private static func normalized(_ id: String?) -> String? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - ForkDestination (where a detected fork lands)

/// Where a detected `/branch` fork is routed (E13, WI-7). Claude-only and a CLOSED set — a "Fork in New
/// Window" destination is suppressed (no multi-window on the remote / iOS arch), and "Fork in Split Left / Up"
/// are not surfaced; aislopdesk ships only three destinations (right / down / new-tab, matching the split
/// chords). Both the original and the forked thread stay live (the existing multi-pane support); the
/// destination only chooses the new pane's placement, orthogonal to the remote host.
public enum ForkDestination: Sendable, Equatable {
    /// A side-by-side column to the RIGHT of the active pane (the `⌘D` split axis).
    case splitRight
    /// A stacked row BELOW the active pane (the `⌘⇧D` split axis).
    case splitDown
    /// A brand-new tab in the active session.
    case newTab
}
