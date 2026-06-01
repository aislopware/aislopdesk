# 16 — Read-only Structured Inspector (companion cho TUI)

> Hướng: **Main = libghostty TUI** (full fidelity, mọi tương tác qua TUI) + **inspector READ-ONLY song song** (desktop + iOS) để xem thứ khó đọc trong scrollback: subagent content, tool calls đầy đủ, CoT, todos, workflow. Nguồn: `research/readonly-inspector-corpus.json`.
>
> *As-of: Claude Code v2.1.x (2026-06). Claim gắn version + flag undocumented → verify trên CC version đích.*

## Vì sao hướng này thắng (differentiator)

- **Read-only = né TOÀN BỘ cost của một SDK-driven interactive pane:** không reimplement slash/model/permissions (TUI lo hết input), không duplicate-prompt, không lo `--bare`/`settingSources` (ta **quan sát** transcript, không **drive** agent). Không có input path từ inspector → claude → an toàn tuyệt đối.
- **Cùng session với TUI** (không phải session SDK thứ 2). Đọc transcript của chính `claude` process đang chạy.
- **Hơn Happy/Happier:** họ chỉ có structured (mất TUI fidelity); ta có **TUI đầy đủ + inspector** = best of both.

## Data source: tail JSONL transcript (+ hooks bổ sung)

`claude` ghi JSONL append-only tại `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` (override `CLAUDE_CONFIG_DIR`). **Lấy path từ field `transcript_path` trong hook payload** (`SessionStart`) — không tự reconstruct.

| Thành phần | Trong JSONL? | Ghi chú |
|------------|--------------|---------|
| **tool_use input** đầy đủ | ✅ | assistant `message.content[]` block `{type:tool_use,id,name,input}` |
| **tool_result output** đầy đủ | ✅ | user line `{type:tool_result,tool_use_id,content,is_error}` + top-level `toolUseResult` (full file/diff) |
| **Todos/Tasks** | ✅ (qua tool calls) | `TaskCreate/TaskUpdate/TaskList` (mới, default v2.1.142+) / `TodoWrite` (cũ) — **accumulate từ chuỗi tool call**, không phải bản ghi riêng |
| **Subagent (Task/sidechain)** | ✅ **file RIÊNG** | `~/.claude/projects/<project>/<sessionId>/subagents/agent-<hash>.jsonl` + meta `agent-<hash>.meta.json` (`{agentType,description,toolUseId}`); mỗi dòng `isSidechain:true` + `agentId` |
| **CoT/thinking** | ⚠️ phần lớn RỖNG trên Opus 4.x | block `{type:thinking,thinking:"",signature}` luôn có cấu trúc nhưng text rỗng mặc định — xem dưới |

> ⚠️ **CORRECTION (refuted):** native `claude` **KHÔNG** ghi `parent_tool_use_id` top-level; subagent turns **KHÔNG** interleave vào file session chính. → tail mỗi file chính = **mất hết subagent**. Phải watch thêm thư mục `subagents/` (FSEvents), index theo `agentId`, dùng hook **`SubagentStop.agent_transcript_path`** làm tín hiệu. (Path từ source Happier + observed local — **KHÔNG official**, verify trên CC version đích.)

> ⚠️ **CoT/thinking — caveat nặng nhất:** trên **Claude 4 (Opus 4.5/4.7/4.8 = stack của ta)** field `thinking` mặc định **RỖNG** (`display:"omitted"` cho Opus 4.7+; `showThinkingSummaries` không wire tới `thinking.display`). Workaround: flag **undocumented** `claude --thinking-display summarized` → populate text (có thể vỡ khi update). `redacted_thinking` (mã hoá) chỉ Claude 3.7, không phải Claude 4. → Inspector phải defensive: `thinking===""` + có `signature` → render placeholder "Thinking (not persisted)". **Đây là quyết định load-bearing (xem cuối).**

## "Workflow" = Dynamic Workflows (tính năng mới)

CC ≥ **v2.1.154** (ra 28/05/2026, **research preview**). Là **JS orchestration script** Claude tự viết, chạy runtime **tách biệt** conversation, spawn ≤16 concurrent / 1000 total agent, intermediate results trong **biến script** (ngoài context). Trigger: keyword `workflow`, `/effort ultracode`, `/deep-research`. Saved ở `.claude/workflows/`. UI: `/workflows`. Tắt: `CLAUDE_CODE_DISABLE_WORKFLOWS=1`.
- **Observe:** KHÔNG có JSONL event riêng, KHÔNG có hook WorkflowStart/Stop. Gián tiếp qua **SubagentStart/Stop hooks** + sidechain files. ⚠️ **Gap:** main JSONL **thưa/im lặng** suốt workflow run dài (results trong script vars) → inspector phải show "workflow running" (qua Subagent hooks) thay vì trông như treo.

## Hooks — kênh push bổ sung (không thay JSONL)
- `SessionStart` → `transcript_path` + `session_id` + `model`.
- `PostToolUse` → full `tool_name`+`tool_input`+`tool_result`+`duration_ms` (sub-second, **sớm hơn JSONL flush** → card tức thì).
- `SubagentStop` → `agent_id`+`agent_type`+**`agent_transcript_path`**+`last_assistant_message`.
- Hooks **không** mang thinking. Dùng type `http` (POST tới listener) / `command` async — không poll.

## Thiết kế cho stack ta

**Data flow:** host spawn `claude` (PTY) + đăng ký `SessionStart` hook (POST tới local listener) → inspector daemon mở `transcript_path`, FSEvents watch + watch `subagents/` → parse thành typed events → **NWConnection THỨ HAI** (length-prefixed JSON frames) multiplex trên cùng NetBird tunnel cạnh PTY byte stream → client Swift actor giữ ordered store → SwiftUI read-only views. (Optional: PostToolUse/SubagentStop hooks HTTP cho push low-latency, backfill JSONL sau.)

**Views:** tool-call card (input+output+diff+duration, ghép qua `tool_use_id`) · subagent tree (collapsible, attach qua `agentId`, sort theo timestamp **trong level**) · thinking block (empty-aware) · todos/workflow panel · message timeline.

**Sync/dedup:** `processedMessageKeys` Set (key theo `uuid` / `sidechain:<id>:<uuid>` / ...); file append-only → re-read tail (cap ~1MB), `JSON.parse` từng dòng trong try/catch (line có thể ghi dở); `.passthrough()` tolerate unknown fields (schema chỉ stable ở mức discriminated-union); skip internal types (`file-history-snapshot`,`queue-operation`,`rate_limit_event`); reconnect = host gán monotonic `seq`, client gửi `lastSeq` → replay.

**Platform fit:** desktop = split-view (TUI trái, inspector phải) · iOS = tab/bottom-sheet (timeline → drill-down), read-only hoàn toàn.

## Effort & pitfalls
**Effort v1 ~5–7 tuần:** host tailer+hook listener+framing (~2–3w) · SwiftUI views (~2–3w) · subagent tree (+~1w).
**Pitfalls:** (1) transcript lag vs TUI (JSONL flush theo turn) → dùng PostToolUse hook cho card tức thì; (2) output lớn → truncate ~50KB + "show more"; (3) sidechain ordering async → sort-trong-level; (4) workflow im lặng → detect qua hooks; (5) race SessionStart trước khi file tạo → retry mở file.

## Phasing
- **P1 (MVP, 80% giá trị):** tail session JSONL chính + SessionStart hook; tool-call cards + timeline + todos.
- **P2:** subagent tree (watch `subagents/`, SubagentStop hook).
- **P3:** workflow panel + agent teams inbox (experimental, defer).
- **CoT:** placeholder-only ở mọi phase (đã chốt — không có phase "CoT text").

## Quyết định đã chốt
1. **CoT/thinking = CHỈ PLACEHOLDER** ✅ — render "Thinking (not persisted)" + signature fingerprint khi `thinking===""`. **KHÔNG** theo đuổi flag undocumented `--thinking-display summarized` (fragile). → bỏ P4 "CoT text"; nếu sau Anthropic persist thinking mặc định thì hiển thị tự nhiên (đã có sẵn chỗ render).
2. **Transport = NWConnection length-prefixed** (thứ 2, multiplex trên NetBird tunnel) — nhất quán với PTY path. WebSocket chỉ nếu event rate cao gây vấn đề (đo sau).
3. **Workflow panel / Agent Teams = defer** (research preview / experimental off-by-default).

## Độ tin cậy (honest)
- ✅ High: JSONL là source đúng; tool input/output/todos đầy đủ; hooks bổ sung; `agent_transcript_path` thật; Workflow = Dynamic Workflows v2.1.154+.
- ⚠️ Uncertain (load-bearing): thinking rỗng trên Claude 4 (model+flag dependent, corpus có verdict mâu thuẫn); subagent/team path từ Happier source + observed, **không official** → verify trên CC version đích; schema chỉ stable mức union → `.passthrough()`.
- ❌ Refuted: `parent_tool_use_id` top-level (phải dùng file `subagents/` riêng).
