import Foundation

// MARK: - AgentResumeRouter (the pure "where does Resume land" decision)

/// The PURE "Resume an agent session" policy (E13, WI-6, ES-E13-6): given a captured Claude session id and a
/// map of the LIVE agent panes (session id → the pane currently running it), decide whether the History
/// viewer's **Resume** button should JUMP to the already-running tab or SPAWN a fresh pane running the
/// VERBATIM `claude --resume <id>` command.
///
/// **Claude-only** (BINDING directive 1): the resume verb is hard-fixed to `claude` — no branch on
/// ``MetadataCodec/AgentKind`` (codex / opencode are never surfaced anywhere in the agent UI). The command is
/// emitted VERBATIM and is NEVER routed through ``SendKeysParser`` — a literal `<Enter>` or quote inside a
/// session id can therefore never become a control byte (the standing injection-safety invariant, mirroring
/// ``SendToChatModel`` and ``PeekReplyFormatter``).
///
/// A pure value enum (no SwiftUI / store / `AislopdeskTerminal` import) so BOTH decisions are unit-tested
/// without a view — the inspector's History viewer feeds it the host-reported `session.id` plus the store's
/// live-pane map and acts on the returned ``ResumeTarget``. `#if`-unguarded so it compiles + tests on every
/// platform.
public enum AgentResumeRouter {
    /// Where a Resume action lands.
    public enum ResumeTarget: Equatable, Sendable {
        /// A live tab already runs this session — focus it instead of starting a second copy.
        case jumpTo(PaneID)
        /// No live tab runs it — spawn a pane running this VERBATIM command (`claude --resume <id>\n`).
        case spawn(command: String)
    }

    /// The VERBATIM command line that resumes a Claude session: `claude --resume <id>` plus a single trailing
    /// newline (`\n`) to submit it. The `sessionID` is interpolated AS-IS — no escaping, no parser: the caller
    /// passes the host-reported ``MetadataCodec/AgentSessionInfo/id`` exactly as the resume CLI consumes it
    /// (matching the existing Open-Quickly resume path).
    public static func resumeCommand(sessionID: String) -> String {
        "claude --resume \(sessionID)\n"
    }

    /// Decides where Resume lands for `sessionID`: ``ResumeTarget/jumpTo(_:)`` when `liveSessionIDs` maps the
    /// id to a live pane (a tab is already running that exact session — never start a duplicate), else
    /// ``ResumeTarget/spawn(command:)`` carrying ``resumeCommand(sessionID:)`` for a fresh run.
    ///
    /// The match is CANONICAL: the host reports a session's ``MetadataCodec/AgentSessionInfo/id`` as an
    /// absolute `<id>.jsonl` PATH, while a live pane advertises the BARE Claude session id off its inspector
    /// channel. An exact-key hit wins first (the common case + the unit pins); otherwise both sides are reduced
    /// to ``canonicalSessionID(_:)`` (the file-name leaf, extension stripped) so the path form and the bare
    /// form resolve to the SAME live tab — without this the jump branch is dead and every Resume spawns.
    public static func target(sessionID: String, liveSessionIDs: [String: PaneID]) -> ResumeTarget {
        if let pane = liveSessionIDs[sessionID] {
            return .jumpTo(pane)
        }
        let canonical = canonicalSessionID(sessionID)
        if let pane = liveSessionIDs.first(where: { canonicalSessionID($0.key) == canonical })?.value {
            return .jumpTo(pane)
        }
        return .spawn(command: resumeCommand(sessionID: sessionID))
    }

    /// Reduces a session id to its canonical comparison form: the file-name leaf (the part after the last
    /// `/`) with a single trailing extension removed — so the host's `<id>.jsonl` path and the bare `<id>` the
    /// live inspector channel reports compare EQUAL. A bare id (no path, no extension) passes through
    /// unchanged, so the spawn command keeps interpolating the VERBATIM host id. Pure string slicing.
    public static func canonicalSessionID(_ id: String) -> String {
        let leaf = id.split(separator: "/").last.map(String.init) ?? id
        guard let dot = leaf.lastIndex(of: "."), dot != leaf.startIndex else { return leaf }
        return String(leaf[..<dot])
    }
}
