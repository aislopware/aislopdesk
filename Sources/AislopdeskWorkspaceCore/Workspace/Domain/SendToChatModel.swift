import Foundation

// MARK: - SendToChatContext (the captured, headless "what gets quoted" payload)

/// The PURE display + delivery payload the E13 "Send to Chat" dialog (`⌘⌃↩`, ES-E13-5) carries: the
/// source LOCATION (the dialog's title row — e.g. `composer.md L3` for a file pane, or the pane's display
/// title for a terminal pane), the VERBATIM captured `quoted` text (the read-only preview box), and an
/// optional `sourcePath` (the `…/composer.md#L3` reference line otty prepends to the delivered message for
/// a file source; `nil` for a terminal pane, which has no file path).
///
/// A PURE value type (no SwiftUI / store / `AislopdeskTerminal` import) so the capture + compose are
/// unit-testable without the renderer — the view feeds it the selection / last-output strings the store
/// resolved off the active pane (libghostty selection or the OSC-133 `D` block), and the agent-pane send
/// path reads ``SendToChatModel/payload(for:)`` for the exact VERBATIM bytes.
public struct SendToChatContext: Equatable, Sendable {
    /// The source location shown in the dialog title row (e.g. `composer.md L3`, or a terminal pane's
    /// display title). Plain text, never an exfil vector.
    public let title: String
    /// The VERBATIM captured text — the selection (if any) else the last command's output. Shown in the
    /// read-only quoted preview box, and quoted line-by-line into the delivered message.
    public let quoted: String
    /// An optional file reference line (`…/composer.md#L3`) prepended to the delivered message for a file
    /// source. `nil` for a terminal pane (no file path) — then the message is just the quoted block.
    public let sourcePath: String?

    public init(title: String, quoted: String, sourcePath: String? = nil) {
        self.title = title
        self.quoted = quoted
        self.sourcePath = sourcePath
    }
}

// MARK: - SendToChatSession (one Claude-only agent pane in the "Send to:" picker)

/// One entry in the dialog's "Send to:" session picker — a LIVE agent pane (`composerAgentActive`, i.e.
/// `claudeStatus != .none`) the captured context can be routed to. **Claude-only** (BINDING directive 1):
/// the model badge is always "Claude Code"; `MetadataCodec.AgentKind.codex` is never surfaced here.
///
/// A PURE value type keyed by the pane's stable ``PaneID`` so the picker rows + the last-used default
/// resolve headlessly (the store builds the list off its live sessions; this model only filters + defaults).
public struct SendToChatSession: Identifiable, Equatable, Sendable {
    /// The stable identity of the agent pane this row routes to (the picker selection + the send target).
    public let id: PaneID
    /// The pane's display name (its live OSC title or spec title, e.g. `CC | my-project`).
    public let name: String

    public init(id: PaneID, name: String) {
        self.id = id
        self.name = name
    }

    /// The agent model badge shown on the right of the picker row. Claude-only, so always "Claude Code"
    /// (the otty `OpenCode` / `GLM-5.1` multi-model badges are out of scope — see the spec mapping notes).
    public var agentLabel: String { "Claude Code" }
}

// MARK: - SendToChatModel (the pure capture + compose + picker-default policy)

/// The PURE "Send to Chat" policy (ES-E13-5): captures the source (selection wins over last-output),
/// composes the VERBATIM delivered message (a quoted context block + the user's comment), encodes the exact
/// PTY bytes (no ``SendKeysParser`` — the standing injection-safety invariant), and resolves the picker's
/// last-used default. `nonisolated` + `#if`-unguarded so it composes from any context and tests on every
/// platform (mirrors ``PeekReplyFormatter``).
public enum SendToChatModel {
    /// Captures the context payload for a focused pane: the SELECTION (if non-blank) is used; otherwise the
    /// LAST command output (the OSC-133 `D` block text); otherwise `nil` (nothing to send — the caller does
    /// not open the dialog). `title`/`sourcePath` flow straight through. The chosen text is stored VERBATIM
    /// (presence is decided on a whitespace-trimmed probe, but the preview shows the raw bytes).
    public static func capture(
        title: String,
        selection: String?,
        lastOutput: String?,
        sourcePath: String? = nil,
    ) -> SendToChatContext? {
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SendToChatContext(title: title, quoted: selection, sourcePath: sourcePath)
        }
        if let lastOutput, !lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SendToChatContext(title: title, quoted: lastOutput, sourcePath: sourcePath)
        }
        return nil
    }

    /// Composes the VERBATIM message delivered to the agent: an optional file-reference line, then the
    /// captured text quoted line-by-line (each line prefixed `> `, matching otty's `send-to-chat-frame-05`),
    /// then — when the user typed a comment — a blank separator line and the comment. The quoted block's
    /// leading/trailing BLANK lines are dropped (CRLF normalized to LF) so a trailing newline in the
    /// captured output never leaves a dangling `> `; interior lines + content are preserved byte-for-byte.
    public static func compose(context: SendToChatContext, comment: String) -> String {
        var lines: [String] = []
        if let path = context.sourcePath, !path.isEmpty { lines.append(path) }
        let body = context.quoted.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lines.append("> \(line)")
        }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            lines.append("")
            lines.append(trimmedComment)
        }
        return lines.joined(separator: "\n")
    }

    /// The exact PTY bytes for the composed `message`, byte-identical to ``ComposerModel/sendDraft()``: a
    /// MULTI-line message rides as one inert DEC bracketed-paste block (so its embedded newlines stay live
    /// -input-inert and the whole prompt lands as ONE turn, not one-per-line), a SINGLE-line message is the
    /// raw UTF-8; both end in a single CR (`0x0D`) to submit. VERBATIM — the literal text is never run
    /// through ``SendKeysParser`` (a literal `"<Enter>"` in the captured output can't become a control byte).
    public static func payload(for message: String) -> Data {
        let wrapped = message.contains(where: \.isNewline) ? PasteTransform.bracketed(message) : message
        var bytes = Data(wrapped.utf8)
        bytes.append(0x0D)
        return bytes
    }

    /// The picker's default selection: the LAST-USED session (keyed by a preferences ``PaneID``) when it is
    /// still in the live list, else the first live agent session, else `nil` (no agent pane open → the
    /// dialog offers only the "New session" option). The previously chosen session is pre-selected when the
    /// dialog opens (the spec's "last-used session is the default").
    public static func defaultSession(
        in sessions: [SendToChatSession],
        lastUsed: PaneID?,
    ) -> SendToChatSession? {
        if let lastUsed, let match = sessions.first(where: { $0.id == lastUsed }) { return match }
        return sessions.first
    }
}
