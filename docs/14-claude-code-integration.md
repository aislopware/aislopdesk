# 14 — Tích hợp Claude Code (+ Warp, herdr)

> Kết quả workflow nghiên cứu (13-agent + adversarial verify). Use-case: chạy/điều khiển **Claude Code** (Anthropic CLI agent) qua remote-coding tool (terminal path libghostty/NetBird). Nguồn đầy đủ: [research/claude-code-warp-herdr-corpus.json](research/claude-code-warp-herdr-corpus.json).
>
> *As-of: Claude Code v2.1.x (2026-06). Claim gắn version + flag undocumented → verify trên CC version đích.*

## TL;DR
- **Hosting Claude Code:** nó là native binary cần real PTY + alt-screen. **Bật fullscreen mode** (`CLAUDE_CODE_NO_FLICKER=1`) cho remote PTY. PTY bridge phải forward **nguyên vẹn** control sequences + kitty keyboard + SGR mouse + OSC 8/52/777 + bracketed paste; set `COLORTERM=truecolor` + `TERM=xterm-ghostty`. ⚠️ Nếu emit TERM custom → bắt buộc `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` (DEC 2026 bug). Image-paste qua OSC 5522 **chưa chạy** (Ghostty parse-only) → đừng ship, document limitation.
- **Ô input ngoài (Warp-style) — ĐÃ CHỐT A+B1:** (A) shell input box + block mode (`COMMAND_FINISHED` callback + tự sniff `ESC[?1049h/l` để ẩn/hiện box); (B1) Claude Code giữ TUI + overlay compose-box ghi byte vào PTY (kiểu Ctrl-G của Warp). **KHÔNG làm B2 (SDK pane)** — structured view dùng read-only inspector [16]. Xem §"Ô input ngoài".
- **Warp:** ô-input-ngoài = **GUI editor client-side, không gửi PTY tới khi Enter**; ẩn/hiện theo **DECSET 1049 (alt-screen)** mà Warp tự parse trong VT stream (KHÔNG phải raw-mode/termios). Block boundary: ta dùng **`GHOSTTY_ACTION_COMMAND_FINISHED`** callback (có exit_code+duration) — **KHÔNG cần OSC 133** (Warp cũng không dùng OSC 133; tự chèn còn làm Warp vỡ). ✅ **Input editor KHẢ THI trên stack ta** (xem §"Ô input ngoài" dưới). Đừng copy: GPU renderer / cloud orchestration của Warp.
- **herdr** = [github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) — "agent multiplexer" Rust, 3.6k★, AGPL+commercial, NDJSON-over-Unix-socket, native Claude Code. → **Tool của ta nên là FIRST-CLASS CLIENT** của herdr/orchestrators (speak NDJSON protocol, tránh AGPL bằng cách không embed binary), **KHÔNG build orchestration product riêng**. Giá trị của ta = PTY transport + render libghostty + mobile client.

## Quyết định đã chốt (+ open questions đã giải)

**Quyết định 1 — `TERM = xterm-ghostty`** (native). Được kitty keyboard (Shift+Enter, Cmd+C, modifier combos) + DEC 2026 sync auto-detect. ⚠️ **Chấp nhận rủi ro bug paste #54700** (xterm-ghostty terminfo có thể làm multi-line paste mangle newline→Enter; bug "not planned"). **Mitigation:** theo dõi #54700; cân nhắc client-side paste handling (bracketed-paste wrap đúng cách) + cho user toggle về `xterm-256color` nếu gặp. (Nếu chạy CC trong **tmux** thì `CLAUDE_CODE_FORCE_SYNC_OUTPUT` vô hiệu — quyết định kiến trúc: chạy CC trực tiếp trong PTY, không lồng tmux trừ khi cần.)

**Quyết định 2 — Auth = Subscription OAuth + `claude setup-token`** (token 1 năm cho host daemon headless). Interactive session **KHÔNG** ăn Agent SDK credit → coding hằng ngày không bị cap. ⚠️ **Refine từ prior-art ([15](15-prior-art-happy-happier.md)):** an toàn nhất là **reuse `~/.claude/.credentials.json`** (để `claude` login sẵn) thay vì tự chạy PKCE — vì scope `user:inference` (happy dùng) CHƯA xác nhận có cấp quota Pro/Max hay chỉ API-billed. Set `CLAUDE_CODE_ENTRYPOINT=remote_mobile` (non-SDK) khi spawn headless để session vẫn resume được từ terminal. ⚠️ **Lưu ý interaction:** nếu sau làm **SDK-driven agent pane (P1)** trên OAuth → `claude -p`/SDK **ăn Agent SDK credit** (từ 2026-06-15) **và** không dùng được `--bare` (bare cần API key). → SDK pane trên OAuth: bỏ `--bare`, hoặc dùng API key riêng chỉ cho pane đó.

**Open questions libghostty — ĐÃ GIẢI (đọc source):**
- **Alt-screen (1049)**: ✅ chạy đúng qua external-backend (cùng VT parser) → fullscreen Claude Code OK.
- **Parsed-stream vs pixels**: API **OPAQUE** — không có parsed stream/grid; có **action callbacks** (COMMAND_FINISHED/PWD/TITLE/PROGRESS) + `read_text` → **block/status UI qua callbacks**, không parse OSC raw.
- **Kitty keyboard**: ✅ Ghostty tự encode qua `ghostty_surface_key()` → route mọi phím qua đó (KHÔNG dùng bypass path Lakr233). Phù hợp với lựa chọn `xterm-ghostty`.
- **TCP split OSC**: ✅ chỉ cần buffering (VT parser stateful), không loss-recovery.
- Chi tiết + spike còn lại: [12 open-questions](12-coding-profile.md), `research/resolve-open-questions-corpus.json`.

## Ô input ngoài (Warp-style) — thiết kế cho stack ta

> Nguồn: `research/warp-input-box-corpus.json` (đọc source AGPL của Warp). **Cách Warp thực sự làm 2026:** ô input = GUI editor trong process Warp, key KHÔNG xuống PTY tới khi Enter; ẩn/hiện theo state machine `TerminalInputState` (AltScreen / InputEditor / LongRunningCommand) **driven bởi DECSET 1049/47** Warp tự parse — KHÔNG detect raw-mode/termios.

**A. Shell commands → ô input native + block mode — KHẢ THI (~2–4 tuần).**
- Input box SwiftUI pinned bottom; Enter → ghi cả dòng xuống PTY master; output vẫn render trong ghostty surface phía trên.
- Block boundary: dùng **`GHOSTTY_ACTION_COMMAND_FINISHED`** (exit_code+duration) từ `action_cb` — **không cần OSC 133**.
- ⚠️ **BẮT BUỘC: sniff byte stream TRƯỚC khi feed ghostty** — quét ~6 sequence cố định `ESC[?1049h/l`, `ESC[?1047h/l`, `ESC[?47h/l`. Thấy `h` → `altScreenActive=true`, ẩn input box, forward phím raw (vim/btop/htop chiếm màn); thấy `l` → đảo lại. Đây **chính xác** cơ chế Warp; là parser nhỏ fixed-length, không cần full VT parse (~1–2 tuần sau A). Lý do phải tự sniff: **libghostty surface OPAQUE, không có action alt-screen** (`GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN` chỉ ở sub-lib `libghostty-vt`, không reach qua surface).
- Khó: giấu echo shell để không đè input box (shell integration / quản echo); multi-line + history.

**B. Claude Code → ô input ngoài: hai đường (đây là chỗ CẦN QUYẾT).**
> Sự thật: chạy `claude` trong Warp → vẫn là **TUI riêng của Claude Code**; Warp chỉ bọc footer + overlay Ctrl-G **ghi byte thẳng vào PTY** (DelayedEnter ~50ms). **Native input box + tool-call cards CHỈ có cho agent riêng của Warp (Oz), KHÔNG cho Claude Code CLI.** CC có 2 mode: classic (inline, không 1049) và **fullscreen (alt-screen, opt-in `/tui fullscreen`/`CLAUDE_CODE_NO_FLICKER=1`)**.
- **B1 — overlay compose-box (kiểu Warp Ctrl-G):** giữ TUI của CC, thêm overlay native, submit = PTY write giả-gõ. **Rẻ** nhưng **fragile** (phải đúng lúc CC ở prompt; xung đột Shift+Tab/focus như bug Warp #9179/#9365). Không có cards native.
- **B2 — SDK pane (kiểu Oz, "Warp-style thật"):** KHÔNG chạy TUI; drive CC qua `claude -p --output-format stream-json --include-partial-messages`, parse NDJSON (`assistant`/`text_delta`, `tool_use`, `tool_result`, `result`) → tool-call cards native + input box thật. **Đắt (~4–8 tuần — viết một frontend Claude Code)** nhưng đây mới là native input-box + cards. ⚠️ Billing: SDK metered riêng (Agent SDK credit) trên subscription; verify OAuth headless chạy trên remote host trước khi cam kết.

**✅ ĐÃ CHỐT: A + B1** (shell input box + overlay compose-box cho Claude Code, giữ TUI). **KHÔNG làm B2 (SDK pane)** (best-only; structured view = read-only inspector [16], không drive agent). Phần B2 dưới chỉ giữ làm bối cảnh.

**Thực thi B1 (lưu ý để né bug kiểu Warp):**
- Overlay compose-box native; submit = ghi byte vào PTY + **DelayedEnter** (text trước, `\r` sau ~50ms).
- **Gate availability theo agent state:** detect `claude` đang chạy (command name) + dùng **Claude Code lifecycle hooks** (OSC 777 / `terminalSequence` — đã có ở doc này) để biết CC đang ở prompt/idle → chỉ bật overlay lúc đó (tránh chèn giữa lúc CC đang render/chạy tool).
- **Đừng nuốt phím CC cần:** đặc biệt **Shift+Tab** (CC dùng để switch mode — bug Warp #9179) và focus/Esc. Overlay chỉ bắt phím khi nó đang focus; nhường lại cho TUI khi không.
- Không có tool-call cards native (cards là việc của SDK pane — đã bỏ); overlay chỉ là lớp pre-compose rồi đổ text vào TUI. Structured view → read-only inspector [16].
- ⚠️ **Duplicate prompt dedup (BẮT BUỘC, bài học Happy/Happier [15](15-prior-art-happy-happier.md)):** B1 phơi bày CẢ compose-box LẪN PTY cùng feed prompt → prompt vào transcript 2 lần. Giữ **dedup ring buffer (text + timestamp)**.
- ⚠️ **stdin `O_NONBLOCK` (Happy #301):** `setBlocking(true)` xóa O_NONBLOCK libuv để lại trước khi spawn — nếu không TUI echo garbled / cursor nhân đôi.

**Test cần làm (không phải quyết định):** CC fullscreen đã thành default trên version đích chưa → `script -q /dev/null claude 2>&1 | xxd | grep "1049"` (thấy `\x1b[?1049h` = đang alt-screen). Quyết định này đổi việc parser alt-screen có bắt được CC interactive không.

---

## Tích hợp Claude Code + Warp + HERDR cho remote-coding tool (libghostty/NetBird)

Phân tích dưới đây dựa trên corpus đã adversarial-verified; các claim **refuted**/**uncertain** được đánh dấu ở từng chỗ load-bearing.

---

### 1. Tích hợp Claude Code: TUI requirements (+ vì sao KHÔNG đi SDK pane)

> **Quyết định: chạy TUI thật, KHÔNG drive qua Agent SDK (B2 bỏ).** Phân tích tier SDK dưới chỉ còn là bối cảnh.

#### 1.1. Claude Code là gì (về mặt terminal)
Claude Code là một **native binary** (x64/ARM64, cài vào `~/.local/bin/claude`), KHÔNG phải Node.js TUI wrapper — npm chỉ là kênh phân phối ([code.claude.com/docs/en/setup](https://code.claude.com/docs/en/setup)). Nó cần một **real PTY** trên Unix (đọc terminal dimensions, emit escape sequences, dùng alt-screen). Đây là tin tốt cho kiến trúc của bạn: raw byte stream qua NetBird hoạt động *nếu* transport layer trung thành với PTY signals (SIGWINCH/`TIOCSWINSZ`) và không strip escape sequences.

Có **hai render mode**:
- **Inline-scrollback (default)**: append vào scrollback của host terminal. Mode này có bug SIGWINCH nổi tiếng — mỗi resize ghi một frame mới mà không xóa frame cũ, flood scrollback ([issue #49086](https://github.com/anthropics/claude-code/issues/49086), [#20094](https://github.com/anthropics/claude-code/issues/20094)).
- **Fullscreen alt-screen (opt-in)**: `CLAUDE_CODE_NO_FLICKER=1` hoặc `/tui fullscreen` (cần v2.1.89+) — dùng alternate screen buffer như vim, memory phẳng, ít byte/frame, thêm mouse support ([code.claude.com/docs/en/fullscreen](https://code.claude.com/docs/en/fullscreen)).

> **Với remote PTY ở bất kỳ latency non-trivial nào, fullscreen mode là mode đúng duy nhất.** Nó isolate redraw vào alt-screen và giảm byte/frame — trực tiếp giúp qua WireGuard. Bật mặc định.

#### 1.2. TUI requirements — MUST support (theo thứ tự ưu tiên)

| # | Yêu cầu | Lý do / nguồn |
|---|---------|----------------|
| 1 | **Propagate `COLORTERM=truecolor` vào PTY env** | UI elements (spinner, permission borders, diff bg, statusline) là hardcoded 24-bit ANSI. Remote shell thường không advertise COLORTERM → màu washed-out ([terminal-config](https://code.claude.com/docs/en/terminal-config), [#35806](https://github.com/anthropics/claude-code/issues/35806)) |
| 2 | **Set `TERM=xterm-ghostty`** | Đây là TERM native của libghostty; bật kitty keyboard protocol cho client. ⚠️ Xem caveat DEC 2026 ở dưới |
| 3 | **Forward kitty keyboard protocol reports nguyên vẹn** | Shift+Enter, Option+Enter, modifier combos phụ thuộc vào nó. Ctrl+J luôn chèn newline mọi terminal ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 4 | **Bật fullscreen mode mặc định** (`CLAUDE_CODE_NO_FLICKER=1`) | Như trên |
| 5 | **Forward SGR mouse tracking reports** | Fullscreen mode request mouse; click-to-position, click-expand tool results, drag-select → OSC 52 copy |
| 6 | **Pass OSC 52 + OSC 8 nguyên vẹn** qua TCP byte stream | Clipboard copy + clickable hyperlinks. ĐỪNG rewrite/strip ([#21586](https://github.com/anthropics/claude-code/issues/21586), [fullscreen](https://code.claude.com/docs/en/fullscreen)) |
| 7 | **Forward SIGWINCH + update PTY ioctl, debounce ~50ms** | Giảm flood redraw qua WireGuard |
| 8 | **Forward Ctrl+C / Ctrl+D / Esc / double-Esc KHÔNG translate** | Chúng có hành vi Claude Code-specific (Esc = stop turn, double-Esc = rewind menu), không phải POSIX default ([interactive-mode](https://code.claude.com/docs/en/interactive-mode)) |
| 9 | **Bracketed paste** (mode 2004) wrappers `ESC[200~`/`ESC[201~` | Paste >10.000 ký tự collapse thành `[Pasted text]` placeholder; `-p` mode cap stdin 10MB ([headless](https://code.claude.com/docs/en/headless)) |

#### 1.3. Hai caveat load-bearing (đã verify — đọc kỹ trước khi ship)

- **⚠️ DEC 2026 synchronized output với `xterm-ghostty` — CONFIRMED là vấn đề.** Từ v2.1.110 Claude Code chuyển từ dynamic capability detection sang **hardcoded TERM allowlist**: chỉ gửi DEC 2026 khi TERM *đúng* là `xterm-ghostty` hoặc `xterm-kitty` ([#49584](https://github.com/anthropics/claude-code/issues/49584), [#55613](https://github.com/anthropics/claude-code/issues/55613)). Workaround `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` shipped ở v2.1.129 nhưng **root cause (allowlist thay vì DECRQM) vẫn chưa fix** tới v2.1.159. → **Nếu client của bạn emit một TERM value mới/custom, BẮT BUỘC set `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1`.** Nếu giữ đúng `xterm-ghostty` thì OK natively, nhưng phải canh bug paste tokenization của terminfo `xterm-ghostty` ([#54700](https://github.com/anthropics/claude-code/issues/54700)) — nếu nó manifest, expose toggle về `xterm-256color` (sẽ tắt DEC 2026 nhưng tránh bug paste).

- **❌ Image paste qua OSC 5522 — REFUTED, KHÔNG ship.** Corpus ban đầu ghi "Ghostty PR in progress"; verdict adversarial cho thấy điều này SAI cả hai chiều: Ghostty PR #10560 đã **MERGED 16/02/2026 (ship trong 1.3.0)** nhưng **chỉ parse-only, KHÔNG implement hành vi** ([PR #10560](https://github.com/ghostty-org/ghostty/pull/10560), [1.3.0 release notes](https://ghostty.org/docs/install/release-notes/1-3-0)). Implementation thực sự được accept là [issue #10549](https://github.com/ghostty-org/ghostty/issues/10549) với comment "we can figure out how to impl this later" — **chưa có PR**. Claude Code issue #42712 KHÔNG verify được (GitHub trả ISSUE NOT FOUND). → **Đừng ship feature image-paste dựa vào OSC 5522 semantics của Ghostty: Ghostty sẽ silently parse nhưng bỏ qua.** Document đây là known limitation; workaround tạm: macOS native Ctrl+V (không Cmd+V), hoặc Kitty (full support).

#### 1.4. Có nên đi sâu qua Agent SDK? — **CÓ, cho một dedicated pane riêng biệt.** (just-run-TUI vs SDK-driven)

Ba tier integration:
- **Tier TUI (PTY passthrough)** — đầy đủ trải nghiệm interactive, nhưng pixel-push ANSI qua network nhạy latency. Issue [#20286](https://github.com/anthropics/claude-code/issues/20286) chứng minh ở ~500ms RTT permission dialog đến trễ 30+ phút (đó là VS Code serialization cụ thể; raw PTY của bạn không có bug đó, nhưng React renderer vẫn re-render mỗi token → nhiều small write → latency typing).
- **Tier headless (`claude -p`)** — non-interactive, `--output-format stream-json` emit NDJSON events (text_delta, tool use, system/init), `--json-schema`, `--continue`/`--resume SESSION_ID`. ⚠️ `--bare` = `settingSources:[]` = **TẮT** skills/commands/CLAUDE.md/hooks → **đừng dùng nếu cần feature parity** (mặc định đã load hết) ([headless](https://code.claude.com/docs/en/headless)).
- **Tier Agent SDK** (`@anthropic-ai/claude-agent-sdk` / `claude-agent-sdk`) — `query()` async generator yield typed messages; PreToolUse/PostToolUse hooks in-process; subagent definitions; MCP attachment; session resumption. TS SDK **bundle native binary làm optional dep** — không cần cài Claude Code riêng ([agent-sdk/overview](https://code.claude.com/docs/en/agent-sdk/overview)).

> **Khuyến nghị kiến trúc lai:** giữ raw PTY path cho user muốn full TUI; **thêm SDK-driven agent pane** (SwiftUI native) cho structured interaction. SDK output là **JSON over stdout — tolerant với network buffering hơn nhiều so với raw ANSI**. Map: tool invocations → UI cards, text_delta → streaming pane, permission approval → native buttons, session cost/model → status bar.
>
> ⚠️ **CORRECTION quan trọng (feature parity — `research/sdk-feature-parity-corpus.json`):** **ĐỪNG dùng `--bare`** cho SDK pane nếu muốn giữ skills/custom-commands! `--bare` = `settingSources: []` = **tắt hết** `.claude/` config (skills, commands, CLAUDE.md, hooks, subagents). Mặc định (bỏ qua `settingSources`) SDK **load HẾT** (`["user","project","local"]`, khớp CLI) → **skills + custom slash commands chạy NGAY by default**. Chỉ cần `cwd` trỏ đúng project root. Xem §"Skills/slash trong SDK" dưới.

> **⚠️ Billing — CONFIRMED:** từ **15/06/2026**, `claude -p` và Agent SDK trên **subscription plan** rút từ "monthly Agent SDK credit" riêng ($20 Pro / $100 Max-5x / $200 Max-20x). **API-key auth (`ANTHROPIC_API_KEY`) KHÔNG bị ảnh hưởng** — pay-as-you-go như cũ ([support article 15036540](https://support.claude.com/en/articles/15036540)). → Nếu tool dùng API-key auth thì không sao; nếu OAuth/subscription, cảnh báo user.

---

### 2. Warp terminal: học được gì — must-have vs nice-to-have vs đừng copy

#### 2.1. Insight cốt lõi
Sức mạnh block model của Warp **đến hoàn toàn từ shell-integration signals, KHÔNG từ renderer**. Warp không phải PTY passthrough emulator: nó own input editor (buffer keystroke ở client, chỉ ghi PTY khi Enter), và group output thành typed blocks qua **injected shell hooks** (precmd/preexec) emit JSON metadata trong escape sequence ([how-warp-works](https://www.warp.dev/blog/how-warp-works), [block-model blog](https://www.warp.dev/blog/block-model-behind-warps-agentic-development-environment)).

> **⚠️ Đính chính protocol (CONFIRMED):** Warp dùng **DCS** (Device Control String, `\eP$f{JSON}\x9c`) làm primary protocol trên **macOS/Linux**, KHÔNG phải OSC 133. Trên **Windows** chuyển sang **custom OSC** vì ConPTY nuốt DCS ([building-warp-on-windows](https://www.warp.dev/blog/building-warp-on-windows)). Quan trọng: **Warp KHÔNG consume OSC 133** — inject OSC 133 markers còn *làm vỡ* render của Warp ([Warp #6718](https://github.com/warpdotdev/warp/issues/6718)). Warp đã open-source (28/04/2026, client AGPL v3 + UI crates MIT) nhưng **source Rust terminal emulation chưa có trong public tree** — protocol chỉ verify được từ docs/blog, không phải source.

Điểm mấu chốt cho bạn: bạn **không** dùng protocol DCS proprietary của Warp. Bạn dùng **OSC 133** (chuẩn mở: A=prompt start, B=command start, C=output begins, D=command finished + exit code) mà iTerm2/Ghostty/Kitty/WezTerm/Windows Terminal đều implement. **Ghostty (libghostty) đã implement OSC 133 sẵn** cho bash/zsh/fish/elvish/nushell. Có open issue xin Claude Code emit OSC 133 ([#22528](https://github.com/anthropics/claude-code/issues/22528)) — **nhưng Claude Code hiện CHƯA emit OSC 133** (claims_to_verify ghi nhận điều này; nhiều issue mở: #1465, #32635). Nghĩa là block detection sẽ áp dụng cho **shell commands** quanh/ngoài Claude Code, không phải nội bộ session Claude Code.

#### 2.2. Phân loại transferable

**MUST-HAVE:**
1. **OSC 133 shell-integration inject trên remote host** — vì PTY chạy qua NetBird TCP (P2P trực tiếp), escape sequences flow nguyên vẹn, **không cần side channel hay remote-server binary** (khác hẳn Warp SSH). Đây là enabling primitive cho block grouping, exit-code coloring, prompt-jump.
2. **Claude Code lifecycle hooks kiểu `claude-code-warp`** — pattern: shell script hook 6 event (SessionStart, Stop, Notification, PermissionRequest, UserPromptSubmit, PostToolUse), emit OSC 777 → drive status pane "agent running / needs permission / done". ⚠️ **CONFIRMED nhưng partially outdated:** format `\033]777;notify;warp://cli-agent;<JSON>\007` đúng cho CC **< 2.1.141**; từ **CC ≥ 2.1.141** plugin chuyển sang field `terminalSequence` JSON trên stdout (vì Stop hook validator reject unknown field), bypass `/dev/tty`. **Implementation phải handle CẢ HAI path** ([warpdotdev/claude-code-warp](https://github.com/warpdotdev/claude-code-warp), `emit-terminal-sequence.sh`).
3. **Bidirectional PTY fidelity gồm control sequences** (Ctrl+C/Z/D, arbitrary byte writes). Warp #1 Terminal-Bench (52%, claim self-reported — flag là **marketing claim**) chứng minh đây là capability quan trọng nhất cho agentic coding correctness; PTY drop/delay control sequence sẽ làm vỡ Claude Code giữa task ([full-terminal-use](https://docs.warp.dev/agent-platform/capabilities/full-terminal-use/)).

**NICE-TO-HAVE (để sau):**
4. **Block-based UI** (height-indexed SumTree, GridStorage cho active + FlatStorage cho scrollback) — cần parse OSC 133 ở client renderer. Hữu ích cho navigation + AI context framing, nhưng **không bắt buộc** để chạy Claude Code.
5. **MCP auto-discovery từ `~/.claude.json` / `.mcp.json`** — Warp đọc cùng config files của Claude Code, user đã config sẵn được integration free ([MCP docs](https://docs.warp.dev/agent-platform/capabilities/mcp/)). Trivial UX, no protocol work.
6. **Rich-content blocks coexist với terminal blocks** trong cùng BlockList (zero-height hidden blocks để collapse) — pattern elegant, hợp với SDK structured event stream.

**KHÔNG NÊN COPY:**
7. **Input editor của Warp** (buffered keystroke, multi-cursor) — incompatible với external-backend model của libghostty (render VT stream as-is). TUI input của Claude Code đã đủ.
8. **GPU renderer / custom UI framework của Warp** — bạn đã có libghostty Metal rendering.
9. **Oz cloud agent orchestration + Warp Drive cloud sync** — proprietary, out of scope cho P2P tool.

---

### 3. HERDR là gì + landscape multi-agent orchestration

#### 3.1. HERDR — CONFIRMED, định danh chính xác
[github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) (tác giả Oğulcan Çelik). "Agent multiplexer that lives in your terminal" — **terminal multiplexer Rust với agent awareness**, single binary. **3.6k stars, v0.6.6 (31/05/2026)** — cả hai số đều CONFIRMED qua live fetch. **Dual-license AGPL-3.0-or-later + commercial** (`hey@herdr.dev`) — CONFIRMED qua LICENSE file/Cargo.toml/nix ([herdr LICENSE](https://github.com/ogulcancelik/herdr/blob/main/LICENSE)). Chạy macOS/Linux, **không Windows** (phụ thuộc Unix socket).

Nó KHÔNG phải Claude Code plugin/framework. Kiến trúc: **background server quản workspaces/tabs/panes mỗi cái backed bằng real vt100 PTY**; thin-client connect local hoặc qua SSH. State tracking 3 signal: **process detection + socket API reports + screen heuristics**. Native integrate Claude Code (hook-based), Codex, OpenCode, Hermes, Pi, Qoder. Socket API = **NDJSON over Unix domain socket, không auth** — agent có thể create/destroy pane, read output, send keystroke, report state (blocked/working/done/idle), wait other agents, spawn helpers. `HERDR_ENV=1` báo agent biết đang chạy trong herdr; `SKILL.md` dạy Claude Code self-orchestrate.

> **⚠️ Lưu ý license load-bearing:** AGPL copyleft áp lên *software* herdr, KHÔNG lên *protocol*. Client Swift tự viết mà chỉ **speak NDJSON protocol** thì KHÔNG distribute herdr code → không tự động dính AGPL (protocol không copyrightable). AGPL chỉ trigger nếu: (a) ship binary herdr trong product, (b) link library herdr, (c) dùng source Rust của herdr. Commercial license (giá chưa công bố) giải quyết cả ba.

> **Đính chính nhận dạng:** "Herd" ([joinherd.ai](https://joinherd.ai/)) và "AgentHerder" ([agentherder.com](https://agentherder.com/)) là **project KHÁC**, đừng nhầm với herdr. "herdctl" ([edspencer.net](https://edspencer.net/2026/1/29/herdctl-orchestration-claude-code)) là tool MIT khác, Node.js, Docker-based, build trên Agent SDK.

#### 3.2. Landscape (universal pattern: git worktree isolation/agent + task queue + human review gate)

- **Claude Code Agent Teams** (native, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, v2.1.32+): lead session spawn N teammate (mỗi cái full session riêng context), shared task list file-locked + mailbox. **⚠️ Split-pane mode CONFIRMED KHÔNG support Ghostty** (chỉ tmux hoặc iTerm2) ([agent-teams docs](https://code.claude.com/docs/en/agent-teams), [#24189](https://github.com/anthropics/claude-code/issues/24189) còn open). Blocker nằm ở phía Ghostty (thiếu stable CLI/IPC); [#26572](https://github.com/anthropics/claude-code/issues/26572) đề xuất `CustomPaneBackend` protocol (JSON-RPC 2.0/NDJSON) sẽ unblock — chưa có phản hồi Anthropic.
- **Claude Squad** (smtg-ai, 7.7k★, Go, AGPL): tmux + worktree/agent, TUI dashboard.
- **Conductor** (conductor.build, macOS GUI, free BYOK): worktree/agent, diff-first review, không cần tmux.
- **Uzi** (devflowinc, Go, MIT): CLI `uzi prompt --agents claude:2,codex:1`, có `broadcast` + `checkpoint` cho sweep workloads.
- **Claude Code Agent Farm** (Dicklesworthstone, Python): 20-50 agent qua tmux panes, file-lock coordination (shared tree, không worktree).
- **Vibe Kanban** (Apache-2.0, community-maintained sau khi Bloop đóng cửa đầu 2026): Kanban-card-per-worktree.

#### 3.3. Có nên cho tool host/manage một herd of agents? — **CÓ, nhưng chỉ làm transport+rendering layer, ĐỪNG build orchestration product.**

Tool của bạn ở vị trí độc nhất để **host herd of Claude Code agents natively**, vì PTY-over-NetBird đã cung cấp core primitive mà tất cả tool kia build lên. Cơ hội cụ thể, theo thứ tự giá trị:
1. **Git worktree per agent** — mọi tool nghiêm túc đều dùng. Host support create/list/switch worktree (trivial shell) + expose mỗi worktree là một PTY session trong UI.
2. **Agent supervisor pane** (sidebar state blocked/working/done) — pattern chung của herdr/Claude Squad/Conductor. State detection dùng 3 signal như herdr: process detection + Claude Code hooks (Stop/TeammateIdle/TaskCompleted) + screen heuristics.
3. **HERDR compatibility** — speak socket protocol NDJSON natively, để client macOS/iPad render workspace/tab/pane model của herdr bằng ghostty surface. Bạn thành **first-class client** thay vì SSH terminal thường.
4. **Lấp gap Ghostty của Agent Teams** — vì Anthropic chưa support Ghostty split-pane, bạn có thể parse tmux pane-creation commands và translate sang multi-PTY model của mình; hoặc implement `CustomPaneBackend` (#26572) nếu nó land.
5. **KHÔNG NÊN làm:** full git-worktree UI, Kanban board, multi-model routing layer. Đó là product layer của herdr/Conductor/Claude Squad. **Giá trị của bạn = PTY transport + rendering quality (libghostty) + mobile client.** Hãy là *PTY host tốt nhất* cho các orchestration tool này, không replicate chúng.

---

### 4. KHUYẾN NGHỊ ROADMAP

#### Bây giờ (P0 — để Claude Code chạy mượt qua network PTY)
Đây là điều kiện đủ để Claude Code TUI hoạt động đúng — làm trước mọi thứ khác:
1. Set env trong PTY: `COLORTERM=truecolor`, `TERM=xterm-ghostty`. Nếu emit TERM custom → **bắt buộc** `CLAUDE_CODE_FORCE_SYNC_OUTPUT=1` (DEC 2026 fix, CONFIRMED).
2. Bật fullscreen mặc định: `CLAUDE_CODE_NO_FLICKER=1`.
3. PTY bridge **bidirectional fidelity**: forward control sequences (Ctrl+C/D, Esc, double-Esc), kitty keyboard reports, SGR mouse, bracketed paste, OSC 8/52/777 **nguyên vẹn**. ĐỪNG strip/rewrite.
4. SIGWINCH forward + ioctl update, **debounce ~50ms**.
5. Document limitation: **image-paste qua remote PTY vỡ** (OSC 5522 chưa implement trong Ghostty — REFUTED claim "PR in progress"); workaround macOS Ctrl+V.

#### Sau (P1 — ô input ngoài Warp-style, ĐÃ CHỐT A+B1)
6a. **A — shell input box + block mode:** SwiftUI input box pinned bottom; Enter→PTY; block boundary qua `GHOSTTY_ACTION_COMMAND_FINISHED`; **sniffer `ESC[?1049h/l`** trên feed stream để ẩn/hiện box (~2–4 tuần + 1–2 tuần sniffer). Xem §"Ô input ngoài".
6b. **B1 — overlay compose-box cho Claude Code:** giữ TUI, overlay ghi PTY + DelayedEnter, gate theo lifecycle hooks, né nuốt Shift+Tab/focus.
6c. **OSC 133** (tùy chọn, metadata giàu hơn) + lifecycle hooks → status pane.
> **B2 (SDK-driven agent pane native) — KHÔNG làm.** TUI giữ 100% feature native; structured view = read-only inspector [16] (read-only, không phải interactive SDK pane).
7. **OSC 133 shell-integration** inject trên remote host (libghostty đã parse sẵn) → block model cho shell commands quanh Claude Code: prompt-jump, exit-code coloring, per-block copy. Lưu ý Claude Code **chưa emit OSC 133 nội bộ** nên block grouping áp ngoài session.
8. **Claude Code lifecycle hooks** (kiểu claude-code-warp, handle cả OSC 777 `/dev/tty` lẫn `terminalSequence` stdout path) → status pane.

#### Sau nữa (P2 — multi-agent / orchestration)
9. **Agent supervisor sidebar** + git-worktree-per-agent PTY sessions.
10. **HERDR socket-protocol client** (NDJSON, tự viết — tránh AGPL bằng cách không embed binary/link library).
11. Lấp **Ghostty split-pane gap** của Agent Teams (parse tmux commands hoặc impl CustomPaneBackend nếu #26572 land).

#### Fit vào kiến trúc hybrid terminal+GUI
- **Terminal path (PTY/NetBird/libghostty)**: P0 + P1.7/P1.8 — là backbone. Block model + OSC 133 sống ở client-side VT parser của libghostty's external-backend.
- **GUI path (ScreenCaptureKit + VideoToolbox)**: orthogonal, dùng cho GUI windows; không đụng PTY layer.
- **SDK pane (P1.6)** là *tier thứ ba* nằm cạnh hai path trên: không phải PTY, không phải video — là native SwiftUI consume JSON stream. Đây chính là chỗ "rich-content blocks" của Warp map vào, và là nơi multi-agent supervisor (P2) hiển thị state.

> ℹ️ **4 open question trên ĐÃ GIẢI** (turn sau) — xem [12 open-questions](12-coding-profile.md): alt-screen ✅ chạy; parsed-stream **opaque** (dùng action callbacks); kitty keyboard ✅ qua `ghostty_surface_key`; TCP chỉ cần buffering.

## Skills / slash commands — chạy native trong TUI

> ℹ️ **B2 đã bỏ** → ta KHÔNG drive Claude Code qua SDK. TUI **chính là** Claude Code thật nên **skills + custom slash commands + mọi feature chạy native 100%**, không cần gì thêm. Phần phân tích SDK-parity dưới chỉ còn giá trị tham khảo (nếu sau này cân nhắc lại).

> Nguồn: `research/sdk-feature-parity-corpus.json`. Trả lời cho câu hỏi: structured-event UI (SDK) có support skills + custom slash command như TUI không?

**CÓ — và gần như free.** ⚠️ **Đính chính giả định cũ:** SDK **load `.claude/` config by DEFAULT** (bỏ qua `settingSources` = `["user","project","local"]`, khớp CLI). **`--bare`/`settingSources:[]` mới là cái TẮT hết** — đừng dùng. Điều kiện duy nhất: **`cwd` trỏ đúng project root** (qua host process, không phải sandbox iOS).

| Feature | SDK | Cách |
|---------|-----|------|
| Skills (`.claude/skills`, model-invoked) | ✅ default | `skills:'all'` (mặc định enabled). ⚠️ `allowed-tools` trong SKILL.md **bị bỏ qua** trong SDK → dùng `allowedTools` trên `query()` |
| Custom slash (`.claude/commands/*.md`) | ✅ default | gửi `/cmd args` làm prompt; `$ARGUMENTS`/`$1`, `!\`bash\``, `@file` đều expand |
| CLAUDE.md, subagents, MCP, hooks, plugins | ✅ default/config | auto khi settingSources default; hoặc programmatic |
| `/compact`, `/clear` | ✅ | gửi như prompt (streaming, CC v2.1.117+) |
| Autocomplete commands/skills | ✅ | đọc `slash_commands`/`skills`/`plugins` từ message `system/init` → native palette |
| `@`-file-mentions | ❌ tui-only | SDK không expand → **native file picker** inject content vào prompt |
| `/model` `/config` `/agents` `/permissions` `/diff` `/memory` `/resume`(picker) | ❌ tui-only | **làm native equivalent** (~15–20 control: model picker, permissions toggle, usage card, diff viewer, CLAUDE.md editor...) |
| Agent teams, `/rewind` checkpoint | ❌ no SDK path | thay bằng programmatic subagents / session branching (`fork_session`) |

**Kết luận:** **năng lực agent cốt lõi (skills, custom commands, subagents, MCP, hooks, CLAUDE.md) đạt parity FREE** trong structured UI; chi phí thêm = ~15–20 native UI cho **management chrome** (không phải năng lực agent); mất thật = agent teams + `/rewind` + visual grids. → **Structured iOS UI (B2) khả thi cho skills + custom commands** — củng cố lựa chọn structured cho iOS ([12 Phase 3](12-coding-profile.md)). **Desktop raw-PTY giữ 100% feature** (vì nó *là* TUI).
