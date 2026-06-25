# Claude Code Agent Supervision — Current State

Assessed against the otty-clone spec pages (`docs/otty-clone/spec/agents__*.md`).
Date: 2026-06-25.

---

## Overview

The host-side detection stack is fully built and wired end-to-end:
`ClaudePaneDetector` (one machine per pane, fusing foreground-poll + hook + self-report) emits
wire type 26 (`foregroundProcess`) and type 27 (`claudeStatus`) over the control channel.
The client-side `LivePaneSession.feedAgentSignal` sinks these into `WorkspaceStore.paneAgentStatus`,
which drives the inspector's "Agent" row, the iOS toolbar indicator, and the attention/notification
edge. Status badge colours and rollup logic are complete.

What is **absent** is the pane-level chrome: the `AgentInputFooter` bottom bar is defined and its
coordinator+actions exist, but it is **not yet mounted** in `TerminalLeafView` (deferred to L5).
The sidebar tab rows carry `RailRow.status` data but the `OttyTabRow` renders only the title — the
status dot is not rendered there. Prompt queue, send-to-chat, fork/branch, and history viewer are
entirely missing (spec-only docs, no implementation code).

---

## Capability matrix

| Feature | Status | Evidence |
|---|---|---|
| **Agent detection (foreground process poll)** | done | `ClaudePaneDetector.sample(name:at:)` at `Sources/AislopdeskHost/ClaudePaneDetector.swift:103`; ~1 Hz foreground basename poll via `MuxChannelSession.agentWatchTask` at `Sources/AislopdeskHost/MuxChannelSession.swift:538` |
| **Agent detection (hook events — SessionStart/PreToolUse/Stop/Notification)** | done | `AgentHookListener`/`AgentHookHandler` at `Sources/AislopdeskHost/AgentHookListener.swift`; `ClaudePaneDetector.hook(bytes:at:)` at `Sources/AislopdeskHost/ClaudePaneDetector.swift:140`; full hook socket wired in `HostServer.spawnFreshShell` |
| **Agent detection (self-report via ctl verb)** | done | `AgentControlHandler.reportAgent` at `Sources/AislopdeskHost/AgentControlListener.swift:149`; `ClaudePaneDetector.report(state:message:at:)` at `Sources/AislopdeskHost/ClaudePaneDetector.swift:166`; grace-window stickiness prevents foreground-poll from wiping a self-reported state |
| **Agent detection (manifest/screen-text fallback)** | partial | `ClaudeManifestMatcher` at `Sources/AislopdeskAgentDetect/ClaudeManifestMatcher.swift` is complete; `ClaudePaneDetector.manifestVerdict` seam exists at `:217`; **not live-fed**: comment at `:205` says "P6 — available but not yet live-fed (documented deferral)" |
| **awaiting-input / busy / done / idle status model** | done | `ClaudeStatus` enum (none/idle/working/done/needsPermission) at `Sources/AislopdeskAgentDetect/ClaudeStatus.swift`; full state machine with `done → idle` decay at `Sources/AislopdeskAgentDetect/ClaudeStatusMachine.swift` |
| **Status wire transport (type 26 + type 27)** | done | `WireMessage.claudeStatus` / `WireMessage.foregroundProcess`; `ClaudePaneDetector.Emission` deduped at `Sources/AislopdeskHost/ClaudePaneDetector.swift:227`; `LivePaneSession.feedAgentSignal` sinks them at `Sources/AislopdeskWorkspaceCore/Workspace/Store/LivePaneSession.swift:402` |
| **Per-pane status stored client-side** | done | `WorkspaceStore.paneAgentStatus: [PaneID: ClaudeStatus]` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift:2895`; `setAgentStatus` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:35` |
| **Status rollup (tab / session)** | done | `rollupStatus(forTab:)` / `rollupStatus(forSession:)` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:56,62` |
| **Status badge in inspector** | done | `InspectorColumn` reads `activeLive?.claudeStatus` and renders SF Symbol + tint via `StatusPresentation.agentSymbol/agentTint` at `Sources/AislopdeskClientUI/Columns/InspectorColumn.swift:150` |
| **Status indicator in iOS toolbar** | done | `WorkspaceRootView.iosToolbar` renders `StatusPresentation.agentSymbol(activeAgentStatus)` at `Sources/AislopdeskClientUI/WorkspaceRootView.swift:70` |
| **Status dot in sidebar tab rows** | partial | `RailRow.status: ClaudeStatus` is populated by `RailRowsBuilder.rows(for:)` at `Sources/AislopdeskClientUI/Rail/RailRowsBuilder.swift:38`; but `OttyTabRow` (the macOS row view at `Sources/AislopdeskClientUI/Chrome/OttyTabRow.swift`) does **not render the status** — it accepts only `title`/`active`/`onSelect`/`onClose`. The dot is referenced in doc comments but the view prop was never added. |
| **Attention edge (needsPermission / done notification)** | done | `applyAttentionEdge` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:77`; `onAgentAttention` closure wired in `AislopdeskClientApp` at `Sources/AislopdeskClientUI/AislopdeskClientApp.swift:155`; delivers macOS `UNUserNotificationCenter` local notification |
| **Jump-to-oldest-attention (⌘⇧U)** | done | `WorkspaceStore.jumpToOldestAttentionPane()` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:104`; `AttentionJump` pure logic; keybinding registered |
| **Peek & Reply overlay (⌘⇧J)** | partial | `peekReplyTargetPane`, `peekContent`, `sendPeekReply` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:122`; `PeekReplyTarget`, `PeekReplyFormatter`, `PeekContent` pure domain types exist; `.peekAndReply` action registered in `WorkspaceBindingRegistry`; `togglePeekReply` closure wired in routing at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift:137` — **the SwiftUI overlay view is not implemented**: without a `togglePeekReply` closure the routing falls back to `jumpToOldestAttentionPane`. The TODO doc says "future overlay". |
| **Agent label / activity summary in sidebar** | done | `agentLabel`, `activitySummary(forSession:)` at `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:23,189`; host type-27 label field captured in `setAgentLabel` |
| **AgentControlListener (ctl socket verbs: list-panes / read / write / run / wait / spawn / kill / resize / subscribe / report)** | done | Full implementation at `Sources/AislopdeskHost/AgentControlListener.swift`; verbs list-panes, read, write, run, wait, spawn, kill, resize, report, subscribe (per-pane + all-pane) all implemented |
| **Composer (multi-line input bar, ⌘⇧E)** | partial | `InputBarModel` at `Sources/AislopdeskWorkspaceCore/Input/InputBarModel.swift`; `InputBoxModel` at `Sources/AislopdeskClaudeCode/InputBoxModel.swift` (mode detection + dedup ring); `InputBar` view at `Sources/AislopdeskClientUI/Pane/InputBar.swift`; **not mounted** in `TerminalLeafView` (see TODO(L5) comment at `:42`); rich/multi-line toggle exists; no draft persistence, no pin mode, no float-panel mode, no ⌘⇧E keybinding registered |
| **AgentInputFooter bottom bar** | partial | `AgentInputFooterCoordinator` at `Sources/AislopdeskClientUI/Footer/AgentInputFooterCoordinator.swift`; `AgentInputFooterAction` enum at `Sources/AislopdeskClientUI/Footer/AgentInputFooterAction.swift` (8 action cases); coordinator handles: notifications chip (W4), rich-input toggle (W3), file-explorer toggle (W2), start-remote-control (W1), settings (stub), add-context (stub), file-select; **no `AgentInputFooter` SwiftUI view exists** — the coordinator and actions are defined but the rendered bar is a TODO(L5) stub in `TerminalLeafView` |
| **History viewer (JSONL transcript rendering)** | missing | Spec at `docs/otty-clone/spec/agents__history.md`; no implementation code found. `BlockHistoryView` at `Sources/AislopdeskClientUI/Inspector/BlockHistoryView.swift` is the **command-block** (shell command) history, not Claude session JSONL transcript rendering. |
| **Prompt queue (⌘⇧M, queue strip, chips)** | missing | Spec at `docs/otty-clone/spec/agents__prompt-queue.md`; no `PromptQueueStore` or queue strip UI found. OSC 133 shell-integration dispatch seam exists but queue is not built. |
| **Send to Chat (⌘⌃↩, context capture dialog)** | missing | Spec at `docs/otty-clone/spec/agents__send-to-chat.md`; no implementation found. |
| **Fork / Branch session (/branch, /fork)** | na-remote | Spec at `docs/otty-clone/spec/agents__fork-branch-session.md`; fork is invoked inside the Claude Code process via its `/branch` slash command — aislopdesk is a pass-through terminal, so the agent does the fork; aislopdesk would only need to detect the new session and route it to a new pane. No aislopdesk-side fork routing is implemented. |
| **Monitor Tasks / parallel-tasks (tab badge, prevent-sleep toggle, per-tab notification toggles)** | partial | Spec at `docs/otty-clone/spec/agents__parallel-tasks.md`; attention-edge notifications (done/needsPermission) are live; per-tab toggle UI (Badge While Processing, Badge When Complete, Prevent Sleep, etc.) is missing; no IOKit power assertion for prevent-sleep |
| **Claude-specific: TerminalMode / alt-screen detection (B1 compose mode)** | done | `TerminalModeTracker` + `TerminalModeStream` + `InputDedupRing` at `Sources/AislopdeskClaudeCode/`; `InputBoxModel` switches affordance shell↔tuiCompose on alt-screen enter/exit |
| **Claude-specific: OSC title detection** | done | `ClaudeStatusMachine.titleNamesClaude` at `Sources/AislopdeskAgentDetect/ClaudeStatusMachine.swift:222`; `oscTitle` signal lifts presence floor |
| **Agent-generic: subscribe verb (output streaming over ctl socket)** | done | `serveSubscribe` (per-pane) and `serveSubscribeAll` (supervision stream) at `Sources/AislopdeskHost/AgentControlListener.swift:606,743`; `agent_status_changed` NDJSON events emitted on status change |
| **Agent-generic: Claude Code profile (TERM, env seams)** | done | `ClaudeCodeProfile` at `Sources/AislopdeskHost/ClaudeCodeProfile.swift`; injected via `HostEnvironment.curated` in `spawnFreshShell` |

---

## Key files

- `Sources/AislopdeskAgentDetect/ClaudeStatus.swift` — status enum, urgency, rollup
- `Sources/AislopdeskAgentDetect/ClaudeStatusMachine.swift` — pure per-pane state machine
- `Sources/AislopdeskAgentDetect/ClaudeSignal.swift` — signal vocabulary
- `Sources/AislopdeskAgentDetect/ClaudeManifestMatcher.swift` — screen-text / process-name classifier
- `Sources/AislopdeskHost/ClaudePaneDetector.swift` — the single per-pane fusion detector (P1)
- `Sources/AislopdeskHost/AgentHookListener.swift` — hook socket server + `AgentHookHandler`
- `Sources/AislopdeskHost/AgentControlListener.swift` — ctl socket server, all verbs incl. subscribe
- `Sources/AislopdeskHost/AgentControlState.swift` — valid self-report states
- `Sources/AislopdeskHost/ClaudeCodeProfile.swift` — TERM + env for Claude Code panes
- `Sources/AislopdeskHost/HostServer.swift` — `wireAgentStatusFanOut`, fan-out observer registry
- `Sources/AislopdeskHost/MuxChannelSession.swift` — `agentDetector`, `agentWatchTask`, `onAgentStatusChanged`
- `Sources/AislopdeskWorkspaceCore/Workspace/Store/LivePaneSession.swift` — `claudeStatus`, `feedAgentSignal`
- `Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift` — attention edge, rollup, peek & reply, activity summary
- `Sources/AislopdeskClientUI/App/StatusPresentation.swift` — view-layer SF Symbol + colour mapping
- `Sources/AislopdeskClientUI/Rail/RailRowsBuilder.swift` — `RailRow.status` population
- `Sources/AislopdeskClientUI/Chrome/OttyTabRow.swift` — sidebar row view (status NOT rendered)
- `Sources/AislopdeskClientUI/Columns/InspectorColumn.swift` — "Agent" row in inspector
- `Sources/AislopdeskClientUI/WorkspaceRootView.swift` — iOS toolbar agent indicator
- `Sources/AislopdeskClientUI/Footer/AgentInputFooterCoordinator.swift` — footer coordinator
- `Sources/AislopdeskClientUI/Footer/AgentInputFooterAction.swift` — footer action enum
- `Sources/AislopdeskClientUI/Pane/TerminalLeafView.swift` — TODO(L5): footer not mounted
- `Sources/AislopdeskClaudeCode/InputBoxModel.swift` — affordance model (shell ↔ tuiCompose)
- `Sources/AislopdeskClaudeCode/TerminalModeTracker.swift` — alt-screen detection
- `Sources/AislopdeskClientUI/Inspector/BlockHistoryView.swift` — command-block history (NOT Claude session history)
- `Sources/AislopdeskClientUI/AislopdeskClientApp.swift:155` — `onAgentAttention` → `UNUserNotificationCenter`
- `Tests/AislopdeskHostTests/ClaudePaneDetectorTests.swift` — detector tests
- `Tests/AislopdeskWorkspaceCoreTests/Workspace/PeekReplyTests.swift` — peek & reply pure logic tests
- `Tests/AislopdeskWorkspaceCoreTests/Workspace/AttentionTests.swift` — attention-edge tests

---

## Notes (wiring gaps, dead seams, traps)

### Dead seams / partial wiring
- **`manifestVerdict` seam is defined but not live-fed.** `ClaudePaneDetector.manifestVerdict(_:at:)` exists and the machine handles it, but `ClaudePaneDetector.swift:205` documents it as "P6 — available but not yet live-fed". The screen-text scanner (`ClaudeManifestMatcher.coarseStatus`) is never called during a live pane session.
- **`RailRow.status` is populated but never rendered.** `RailRowsBuilder` computes `ClaudeStatus` per row and stores it in `RailRow.status`, but `NavigatorColumn` passes only `row.title`/`row.active` to `OttyTabRow`. The sidebar tab dot is referenced only in doc comments and the implementation plan (`docs/42`), not in the current view code.
- **`AgentInputFooter` view does not exist.** The coordinator (`AgentInputFooterCoordinator`) and action enum (`AgentInputFooterAction`) are implemented and well-tested, but there is no SwiftUI `AgentInputFooter` view file. `TerminalLeafView` has a `TODO(L5)` comment for it.
- **Peek & Reply overlay is logic-only.** `PeekReplyTarget`, `PeekReplyFormatter`, `peekContent`, `sendPeekReply` are implemented and unit-tested. The `togglePeekReply` closure in `WorkspaceBindingRouting` is wired at `:207`, but the only live caller passes `nil` — so ⌘⇧J falls back to `jumpToOldestAttentionPane`. No SwiftUI overlay sheet exists.

### Missing features (no implementation code)
- **History viewer**: No JSONL transcript renderer. The `BlockHistoryView` in the inspector is a shell-command block browser, not a Claude session log viewer. The history spec (`docs/otty-clone/spec/agents__history.md`) is untracked spec only.
- **Prompt queue**: No `PromptQueueStore`, no queue strip UI, no chip management. The OSC 133 idle-dispatch trigger exists in `InputBoxModel` (`.shellCommand` → `.commandFinished`) but nothing reads it to fire a queue.
- **Send to Chat**: No context-capture dialog, no cross-pane routing, no `⌘⌃↩` binding.
- **Per-tab monitoring controls UI**: No settings panel for "Badge While Processing", "Badge When Awaiting Input", "Prevent Sleep While Processing" per-tab toggles. The attention-edge notification fires globally.

### Architecture notes (agent-generic vs Claude-specific)
- `ClaudeStatus`/`ClaudeStatusMachine`/`ClaudeSignal` are **Claude-specific** by name but the urgency/rollup model is generic.
- `AgentControlListener` verbs (list-panes, read, write, run, wait, spawn, kill, resize, subscribe, report) are **agent-generic** — any agent can use the ctl socket.
- `InputBoxModel`/`TerminalModeTracker`/`InputDedupRing` in `AislopdeskClaudeCode` are **Claude Code-specific** (tuned to Claude's TUI compose UX).
- Notifications via `onAgentAttention` fire on `needsPermission` and `done` — both Claude Code states, but the mechanism is wired to the generic `ClaudeStatus` enum and would generalise to any agent using the same wire types.
