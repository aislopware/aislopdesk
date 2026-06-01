# 15 — Prior art: Happy & Happier (mobile/desktop cho Claude Code)

> Đọc source thật `slopus/happy` + `happier-dev/happier` (clone verify). Đây là 2 dự án **đang ship** app mobile/desktop cho Claude Code — prior art trực tiếp. Nguồn: `research/happy-happier-corpus.json`.

## Phát hiện cốt lõi (làm thay đổi cách nghĩ)

**Cả hai relay STRUCTURED events lên mobile, KHÔNG relay raw TUI.**
- **Local mode:** spawn `claude` với `stdio: inherit` → full TUI hiện ở **terminal của host**, KHÔNG stream byte xuống mobile. fd 3 (pipe thứ 4) = side-channel bắt thinking-state.
- **Mobile/remote:** dùng **official `@anthropic-ai/claude-agent-sdk`** (`query()`) → SDK tự spawn `claude --output-format stream-json`; mobile nhận **NDJSON events** (assistant/text_delta, tool_use, tool_result, result) + đọc **JSONL transcript** Claude ghi ra đĩa. Render **native UI (cards)**, KHÔNG phải terminal.
- → **Họ kết luận mobile cần native UI, không phải raw ANSI terminal.** Đây là cách tiếp cận **SDK pane** — ta **KHÔNG làm** (best-only). Structured view của ta = **read-only inspector [16]** (đọc JSONL transcript, không drive agent).

## Cách móc vào Claude Code (tóm tắt)

| | slopus/happy | happier-dev/happier |
|--|--------------|---------------------|
| Hook local | `claude` + stdio inherit (TUI ở host) + fd3 thinking | giống hệt |
| Hook remote/mobile | `@anthropic-ai/claude-agent-sdk` → stream-json | SDK + fallback `--print`; **ACP** cho codex/gemini/opencode/qwen/copilot/cursor |
| Inject hook | `--settings` (SessionStart) + `--mcp-config` | **`--plugin-dir` (additive)** — tránh PATH wrapper nuốt `--settings` |
| Parse hook payload | snake_case (+ một phần camel) | snake_case **+** camelCase (phòng schema drift) |
| Permission từ mobile | MCP/RPC | `PermissionRequest` hook riêng |
| Transport | Socket.IO/WSS relay (`cluster-fluster.com`), **bắt buộc, no P2P** | Socket.IO relay (`api.happier.dev`), self-host Docker, Tailscale Serve |
| Encryption | **E2E** NaCl secretbox / AES-256-GCM dataKey | **E2E** X25519+XSalsa20-Poly1305 zero-knowledge |
| Auth relay | NaCl keypair challenge → JWT (no password) | keypair + OAuth/OIDC/mTLS enterprise |
| Auth Claude | PKCE OAuth scope `user:inference` (reuse subscription) | reuse `~/.claude/.credentials.json` per-profile |
| Client | Expo/RN + **Tauri** (+ Electron `codium`) | Expo/RN + Tauri |

## Bài học NÊN mượn cho tool của ta

> ℹ️ Mục dưới là **observation từ prior-art**. Quyết định cuối (auth, transport, control-plane, dedup) = single source ở [DECISIONS.md](DECISIONS.md) + [14](14-claude-code-integration.md)/[13](13-netbird-transport.md).

1. **SessionStart hook để lấy session UUID + transcript path — dùng `--plugin-dir`, KHÔNG `--settings`.** Bài học production-hardened của happier: PATH wrapper (cmux...) âm thầm nuốt `--settings` (last-write-wins). Parse **cả** `session_id`/`sessionId` + `transcript_path`/`transcriptPath` (schema đã đổi giữa version). Cần dù ta relay PTY — để map resume/handoff (file-watch JSONL có race khi nhiều process cùng project dir).
2. **Tách bạch 2 tầng credential:** auth transport (NetBird keypair / setup-token) độc lập auth Claude. **Auth Claude an toàn nhất: reuse `~/.claude/.credentials.json`** (để `claude` login sẵn) thay vì tự chạy PKCE — vì scope `user:inference` của happy CHƯA xác nhận có cấp quota Pro/Max hay chỉ API-billed (⚠️ liên quan quyết định auth ở [14](14-claude-code-integration.md)).
3. **Session resume replay-safe:** dedup theo uuid (happy `sessionScanner`) + monotonic `seq` server-side → sau NetBird reconnect biết miss message nào.
4. **Auth keypair challenge→token** (no password/email) cho machine registration — hợp setup-token flow.
5. **Push notification + presence-suppression** ("Claude ready", suppress khi đang xem). **Dùng APNs/FCM thẳng từ host** (không Expo Push — privacy). → cần một **control plane nhẹ** (xem dưới).
6. **tmux làm persistence layer** cho headless session (happier `startHappyHeadlessInTmux`) → libghostty client attach/detach, sống qua disconnect.
7. **E2E encrypt app-layer** cho mọi metadata/transcript nếu sau thêm history/signaling server (NetBird đã lo byte path, nhưng store thì wrap key per-session).

## Pitfall họ gặp — ta tránh

1. **stdin `O_NONBLOCK`** (happy #301): phải `setBlocking(true)` xóa O_NONBLOCK libuv để lại, nếu không TUI echo garbled / cursor nhân đôi. **Ta sẽ gặp y hệt** khi inherit/relay PTY.
2. **`CLAUDE_CODE_ENTRYPOINT`:** SDK headless set `sdk-cli`/`sdk-ts` → `claude --resume` picker lọc bỏ. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) khi spawn để vẫn resume từ terminal được.
3. **⚠️ Duplicate prompt forwarding:** khi có **CẢ compose-box (B1) LẪN PTY** cùng feed prompt → vào JSONL 2 lần. **Ta phơi bày cả hai đồng thời (đúng quyết định B1!) → BẮT BUỘC dedup ring buffer (text+timestamp).** Ghi nhận cho B1.
4. **`--settings` non-composable** + **schema hook drift** → `--plugin-dir` + parse phòng thủ (đã nêu).
5. **Orphan sidechain buffering** khi `Task` tool spawn subagent (message subagent đến trước parent) — vô hình trong PTY mode, nhưng nếu ta layer structured event lên iOS thì phải xử lý.

## Ta làm KHÁC / TỐT HƠN
1. **Full TUI fidelity qua libghostty** — họ KHÔNG stream TUI xuống mobile; ta relay raw PTY (`TERM=xterm-ghostty`) giữ nguyên màu/cursor/compose-box. Khác biệt bản chất.
2. **P2P, không relay SPOF** — happy/happier chết nếu relay sập; NetBird P2P loại relay khỏi byte path (latency gần-zero, bớt 1 trust boundary).
3. **Một codepath PTY duy nhất** thay vì 2 launcher (local TUI + remote SDK).

## ⚠️ 3 điểm cần cân nhắc (honest, có thể tinh chỉnh kiến trúc)

1. **iOS: raw TUI vs structured-event layer.** Cả happy lẫn happier kết luận **mobile cần native UI, không phải raw ANSI** (pinch-zoom terminal trên màn nhỏ là tệ). → **Cân nhắc layer structured-event lên trên PTY cho iOS** (parse thêm event từ byte stream libghostty đã có — incremental), ta dùng **read-only inspector [16]** cho structured view (read-only, không drive) + **giữ libghostty TUI làm chính** (full fidelity) trên cả desktop lẫn iOS. (KHÔNG làm SDK-driven pane.)
2. **Vẫn cần control plane nhẹ dù P2P.** NetBird lo byte path, NHƯNG **push notification** ("Claude cần input" khi app background) + **"host offline → queue prompt"** cần control plane. Đừng ảo tưởng P2P xóa 100% server — chỉ xóa relay khỏi *byte path*. (NetBird management server + APNs/FCM trực tiếp từ host có thể đủ.)
3. **OAuth scope uncertainty** (mục 2 bài học) — ảnh hưởng quyết định auth doc 14.
