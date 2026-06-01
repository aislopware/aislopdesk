import Foundation

/// Folds parsed ``TranscriptLine``s (and hook payloads) into ``InspectorEvent``s,
/// maintaining the cross-line state the events need: tool-card pairing, the latest
/// todo list, subagent nodes, and a dedup set.
///
/// Pure and synchronous — no I/O, no concurrency. The tailer / watcher / hook seam
/// feed lines in; this produces the typed events. Keeping it a value-free `struct`
/// of mutable state (driven from a single actor / task) makes it trivially testable
/// with fixtures and means the ordering is exactly the feed order.
///
/// Tool-card pairing rules (doc 16, "ghép qua tool_use_id"):
/// - a `tool_use` opens a `pending` card and emits it;
/// - a later `tool_result` with matching `tool_use_id` completes/errors it and
///   re-emits the card with the new status + output;
/// - **out-of-order**: a `tool_result` seen *before* its `tool_use` is held, then
///   applied when the `tool_use` arrives (the card is emitted once, already resolved);
/// - **missing result**: a card with no result stays `pending` forever (no crash);
/// - `is_error == true` ⇒ `.errored`.
public struct EventBuilder {
    /// Dedup keys already processed (doc 16 `processedMessageKeys`). Keyed by line
    /// uuid (main) or `sidechain:<agentID>:<uuid>` so a re-read tail never double-emits.
    private var processedKeys: Set<String> = []

    /// Open tool cards by id (main session). Used to apply a later `tool_result`.
    private var openCards: [String: ToolCard] = [:]

    /// `tool_result`s that arrived before their `tool_use` (out-of-order), keyed by id.
    private var pendingResults: [String: ToolResultBlock] = [:]

    /// Per-subagent open cards, keyed `agentID` → (cardID → card).
    private var subagentOpenCards: [String: [String: ToolCard]] = [:]
    private var subagentPendingResults: [String: [String: ToolResultBlock]] = [:]

    /// Known subagent nodes by id (so a status change re-emits the same node).
    private var subagents: [String: SubagentNode] = [:]

    /// The latest todo list (replaced wholesale on each `TodoWrite`/`Task*`).
    private var latestTodos: [TodoItem] = []

    public init() {}

    // MARK: - Main-session lines

    /// Folds one main-session transcript line into zero or more events.
    public mutating func ingest(line: TranscriptLine) -> [InspectorEvent] {
        switch line {
        case let .user(user):
            return ingestUser(user, agentID: nil)
        case let .assistant(assistant):
            return ingestAssistant(assistant, agentID: nil)
        case let .meta(meta):
            return ingestMeta(meta)
        case .ignored:
            return []
        case let .unknown(raw):
            return [.unknownLine(raw: raw)]
        }
    }

    /// Folds one **subagent** transcript line (from a `subagents/agent-<hash>.jsonl`
    /// file). `agentID` identifies the owning subagent node.
    public mutating func ingestSubagent(line: TranscriptLine, agentID: String) -> [InspectorEvent] {
        switch line {
        case let .user(user):
            return ingestUser(user, agentID: agentID)
        case let .assistant(assistant):
            return ingestAssistant(assistant, agentID: agentID)
        case .meta, .ignored:
            return []
        case let .unknown(raw):
            return [.unknownLine(raw: raw)]
        }
    }

    // MARK: - Hook folding (seam, doc 16)

    /// Folds a typed hook payload into the stream. Hooks are a *push* channel that
    /// complements the JSONL tail (SessionStart gives the path; PostToolUse gives a
    /// sub-second card; SubagentStop links a subagent file in).
    public mutating func ingest(hook: HookPayload) -> [InspectorEvent] {
        switch hook {
        case let .sessionStart(info):
            return [.sessionStarted(info)]

        case let .postToolUse(toolUse, result):
            // A PostToolUse hook can arrive before the JSONL flush (doc 16). Treat it
            // exactly like seeing the tool_use (+ optional result) so the card shows
            // immediately; the later JSONL line dedups on the same card id.
            var events = applyToolUse(toolUse, agentID: nil)
            if let result {
                events += applyToolResult(result, agentID: nil)
            }
            return events

        case let .subagentStop(node):
            // Mark the subagent stopped (creating the node if first seen). The file at
            // `agent_transcript_path` is tailed separately by the watcher.
            return updateSubagent(node)
        }
    }

    // MARK: - Subagent node lifecycle

    /// Records/updates a subagent node and emits the change (idempotent on no-change).
    public mutating func updateSubagent(_ node: SubagentNode) -> [InspectorEvent] {
        let existing = subagents[node.id]
        // Merge: a later update (e.g. SubagentStop) should not blank fields a meta file
        // already supplied.
        var merged = node
        if let existing {
            merged.parentID = node.parentID ?? existing.parentID
            merged.agentType = node.agentType ?? existing.agentType
            merged.description = node.description ?? existing.description
            merged.lastAssistantMessage = node.lastAssistantMessage ?? existing.lastAssistantMessage
        }
        if merged == existing { return [] }
        subagents[node.id] = merged
        return [.subagentUpdated(merged)]
    }

    // MARK: - User / assistant

    private mutating func ingestUser(_ user: UserLine, agentID: String?) -> [InspectorEvent] {
        guard markProcessed(user.identity, agentID: agentID) else { return [] }
        var events: [InspectorEvent] = []
        if let text = user.text, !text.isEmpty {
            events.append(.message(MessageEvent(role: .user, text: text, agentID: agentID)))
        }
        for result in user.toolResults {
            events += applyToolResult(result, agentID: agentID)
        }
        return events
    }

    private mutating func ingestAssistant(_ assistant: AssistantLine, agentID: String?) -> [InspectorEvent] {
        guard markProcessed(assistant.identity, agentID: agentID) else { return [] }
        var events: [InspectorEvent] = []
        for thinking in assistant.thinkingBlocks {
            events.append(.thinking(ThinkingMarker(
                isPlaceholder: thinking.isPlaceholder,
                signature: thinking.signature,
                text: thinking.text
            )))
        }
        if let text = assistant.text, !text.isEmpty {
            events.append(.message(MessageEvent(role: .assistant, text: text, agentID: agentID)))
        }
        for use in assistant.toolUses {
            // Todos/tasks are accumulated state, not a card (doc 16).
            if let todoEvent = todosEvent(from: use) {
                events.append(todoEvent)
            } else {
                events += applyToolUse(use, agentID: agentID)
            }
        }
        return events
    }

    private mutating func ingestMeta(_ meta: MetaLine) -> [InspectorEvent] {
        guard markProcessed(meta.identity, agentID: nil) else { return [] }
        // Only surface session-defining metadata (model / cwd / id). Other meta lines
        // carry no UI value.
        if meta.sessionID != nil || meta.model != nil || meta.cwd != nil {
            return [.sessionStarted(SessionInfo(sessionID: meta.sessionID, model: meta.model, cwd: meta.cwd))]
        }
        return []
    }

    // MARK: - Tool-card pairing

    private mutating func applyToolUse(_ use: ToolUseBlock, agentID: String?) -> [InspectorEvent] {
        // If a result already arrived out-of-order, resolve immediately.
        if let pending = takePendingResult(id: use.id, agentID: agentID) {
            let card = ToolCard(
                id: use.id, name: use.name, input: use.input,
                output: pending.content,
                status: pending.isError ? .errored : .completed
            )
            setOpenCard(card, agentID: agentID)
            return cardEvent(card, agentID: agentID)
        }
        let card = ToolCard(id: use.id, name: use.name, input: use.input, status: .pending)
        setOpenCard(card, agentID: agentID)
        return cardEvent(card, agentID: agentID)
    }

    private mutating func applyToolResult(_ result: ToolResultBlock, agentID: String?) -> [InspectorEvent] {
        guard var card = openCard(id: result.toolUseID, agentID: agentID) else {
            // Out-of-order: result before tool_use. Hold it.
            setPendingResult(result, agentID: agentID)
            return []
        }
        card.output = result.content
        card.status = result.isError ? .errored : .completed
        setOpenCard(card, agentID: agentID)
        return cardEvent(card, agentID: agentID)
    }

    private func cardEvent(_ card: ToolCard, agentID: String?) -> [InspectorEvent] {
        if let agentID {
            return [.subagentToolCard(agentID: agentID, card: card)]
        }
        return [.toolCard(card)]
    }

    // MARK: - Todos

    /// Parses a `TodoWrite` / `TaskCreate`-style payload into the latest todo list.
    /// Returns the `todosUpdated` event, or `nil` if `use` is not a todo/task tool.
    private mutating func todosEvent(from use: ToolUseBlock) -> InspectorEvent? {
        guard use.name == "TodoWrite" || use.name == "TaskCreate" || use.name == "TaskUpdate" else {
            return nil
        }
        // Both shapes carry a `todos` (TodoWrite) or `tasks` array of objects.
        let array = use.input["todos"]?.arrayValue ?? use.input["tasks"]?.arrayValue ?? []
        let items: [TodoItem] = array.compactMap { entry in
            guard case let .object(obj) = entry else { return nil }
            let content = obj["content"]?.stringValue
                ?? obj["description"]?.stringValue
                ?? obj["text"]?.stringValue
            guard let content else { return nil }
            let statusRaw = obj["status"]?.stringValue ?? "pending"
            let status = TodoItem.Status(rawValue: statusRaw) ?? .pending
            return TodoItem(content: content, status: status, activeForm: obj["activeForm"]?.stringValue)
        }
        latestTodos = items
        return .todosUpdated(items)
    }

    /// The current todo snapshot (used by tests + replay-from-scratch).
    public var todos: [TodoItem] { latestTodos }

    // MARK: - Dedup

    /// Marks a line processed; returns `false` if it was already seen (so the caller
    /// emits nothing). A line without a uuid is always processed (can't dedup it, but
    /// the tailer guarantees each physical line is fed once).
    private mutating func markProcessed(_ identity: LineIdentity, agentID: String?) -> Bool {
        guard let uuid = identity.uuid else { return true }
        let key = agentID.map { "sidechain:\($0):\(uuid)" } ?? uuid
        return processedKeys.insert(key).inserted
    }

    // MARK: - Open-card / pending-result storage (main vs subagent)

    private func openCard(id: String, agentID: String?) -> ToolCard? {
        if let agentID { return subagentOpenCards[agentID]?[id] }
        return openCards[id]
    }

    private mutating func setOpenCard(_ card: ToolCard, agentID: String?) {
        if let agentID {
            subagentOpenCards[agentID, default: [:]][card.id] = card
        } else {
            openCards[card.id] = card
        }
    }

    private mutating func setPendingResult(_ result: ToolResultBlock, agentID: String?) {
        if let agentID {
            subagentPendingResults[agentID, default: [:]][result.toolUseID] = result
        } else {
            pendingResults[result.toolUseID] = result
        }
    }

    private mutating func takePendingResult(id: String, agentID: String?) -> ToolResultBlock? {
        if let agentID {
            return subagentPendingResults[agentID]?.removeValue(forKey: id)
        }
        return pendingResults.removeValue(forKey: id)
    }
}
