# 00 — Architecture Overview (đọc đầu tiên)

> Tài liệu **read-first** — gom toàn bộ kiến trúc hiện hành + mọi quyết định đã chốt, mỗi điểm link tới doc chi tiết. Quyết định dạng log: [DECISIONS.md](DECISIONS.md). Codename cũ "PaneCast" (từ thời screen-sharing) — nay là **remote-coding tool**, terminal-first.

## 1. Là gì

> **Triết lý: làm thứ TỐT NHẤT, không fallback** — libghostty-only (không SwiftTerm), không B2 SDK pane, cap fps ~24–30 (GUI). Cam kết một lựa chọn tốt, không nuôi phương án B.

App **điều khiển/coding từ xa** trên Apple (macOS host, macOS + iOS/iPadOS client), native Swift. **Use-case: coding hằng ngày** — chạy shell + **Claude Code** từ xa. KHÔNG phải game-streaming. (Các doc 01–11 viết theo giả định screen-sharing/video cũ → nay là **reference cho GUI video-path** hoặc **superseded** — xem [README](README.md).)

## 2. Kiến trúc: 3 data path

```
┌───────────── HOST (macOS, non-sandboxed) ─────────────┐
│  ① TERMINAL PATH (primary)                            │
│     openpty + posix_spawn → shell / claude (PTY)      │
│        │ raw VT byte stream                           │
│  ③ INSPECTOR (read-only companion)                    │
│     tail JSONL transcript + hooks → typed events      │
│  ② GUI VIDEO PATH (Phase 4)                           │
│     ScreenCaptureKit → VideoToolbox HEVC 4:2:0        │
└───────│──────────────│─────────────────│──────────────┘
        │ TCP          │ NWConn #2        │ UDP        (tất cả qua NetBird WireGuard P2P)
┌───────▼──────────────▼─────────────────▼──────────────┐
│  CLIENT (macOS / iOS / iPadOS)                         │
│  ① libghostty surface (full TUI render) ← + gửi phím  │
│  ③ SwiftUI read-only views (tool cards / subagent /   │
│     todos / workflow / CoT-placeholder)               │
│  ② VTDecompression → Metal (GUI window video)         │
└────────────────────────────────────────────────────────┘
```

- **① Terminal path (PRIMARY)** — full TUI fidelity. Host PTY ([12], [02]) → **plain TCP** qua NetBird → **libghostty** client renderer ([12 §renderer]). Đây là cốt lõi.
- **③ Read-only inspector (DIFFERENTIATOR)** — companion để xem thứ khó đọc trong scrollback (subagent content, tool I/O, todos, workflow). Data = **tail JSONL transcript** Claude Code + hooks → events qua **NWConnection thứ 2**. Read-only nên né mọi cost của việc drive agent. ([16])
- **② GUI video path (Phase 4, secondary)** — chỉ cho cửa sổ GUI (VS Code/Xcode...). ScreenCaptureKit + VideoToolbox HEVC. ([01], [02], [04], [09])

## 3. Quyết định lớn (tóm tắt — chi tiết ở [DECISIONS.md](DECISIONS.md))

| Hạng mục | Quyết định | Doc |
|----------|-----------|-----|
| Use-case | Coding hằng ngày (Claude Code), không game-stream | [12] |
| Mạng | **NetBird (WireGuard mesh), assume direct P2P**; relay = degraded (không engineer) | [13] |
| Encryption | **Không** ở tầng app — WireGuard E2E + NetBird ACL lo | [13] |
| Transport terminal | **Plain TCP** (reliable; chỉ cần buffering) | [13], [12] |
| Transport video | Plain UDP (bỏ QUIC — WireGuard đã encrypt) | [03] |
| Terminal renderer | **libghostty** full surface + **patch external-backend tự own** (ref daiimus External.zig). **KHÔNG SwiftTerm** (best-only) | [12] |
| Host PTY | `openpty` + `posix_spawn(createSession)` (forkpty unsafe từ Swift) | [12] |
| Claude Code TERM | **`xterm-ghostty`** (kitty kbd + DEC2026; chấp nhận rủi ro paste #54700 + toggle fallback) | [14] |
| Claude Code fullscreen | `CLAUDE_CODE_NO_FLICKER=1` cho remote PTY | [14] |
| Auth | **Subscription OAuth + `setup-token`** (hoặc reuse `~/.claude/.credentials.json`); KHÔNG tự PKCE | [14] |
| Ô input ngoài | **A** (shell input box + block) **+ B1** (Claude Code giữ TUI + overlay compose-box→PTY). **KHÔNG B2 SDK pane** (structured view = read-only inspector [16]) | [14] |
| Inspector | **Read-only**, data = JSONL transcript + hooks; **CoT = placeholder-only** | [16] |
| Codec (GUI path) | **HEVC Main 8-bit 4:2:0** + constant-quality (Apple Silicon); 10-bit optional. 4:4:4 dropped; AV1/VVC không HW-encode | [09] |
| Native-feel TUI | **`TCP_NODELAY`** (Nagle +200ms) + dual channel + ET replay-buffer reconnect; **KHÔNG full Mosh predictor** (opaque ghostty → duplicate parser; chỉ glitch-caret tuỳ chọn) | [17] |
| Native-feel GUI | **Client-side cursor** (strip + UDP side-channel + composite ở refresh → pointer=RTT) + **lossy-first→lossless-upgrade** (text nét) + CADisplayLink pacing | [17] |
| Latency | Terminal path = network RTT (~1–5ms LAN-direct, no vsync). GUI path target **40–80ms** (coding); 120fps/floor-<16ms **dropped** | [11], [12] |
| Distribution | Host **non-sandboxed** (spawn shell + CGEvent) → Developer-ID + notarize, **ngoài MAS**; client viewer có thể MAS | [06], [12] |
| Orchestration (herdr/agent-teams) | **Be a client**, không build orchestration product | [14], [15] |

## 4. Lộ trình (chi tiết [12 §Roadmap])
**P0** ⭐ **De-risk gate** — chạy mọi spike architecture-defining TRƯỚC khi build (không park rủi ro sang phase sau). *Phần lớn đã đo xong trên M1 Max/macOS 26.5* ([18 §0]): F decode 1.1ms, G ~8–10 window, low-latency-RC 7.5ms; còn D cursor-strip + echo (không gating). → **P1** Terminal MVP (host PTY → TCP → libghostty) + inspector P1 (tool cards/timeline/todos) → **P2** persistence/reconnect/clipboard + subagent tree → **P3** iOS client → **P4** GUI video path → **P5** polish.

> Phần lớn rủi ro của dự án (input injection macOS — [05]/[08] R1/R2) **chỉ áp dụng GUI video-path (P4)**; terminal path né hoàn toàn (input = byte → PTY stdin).

## 5. Đọc tiếp
- ⭐ **Best-solution synthesis (latency thấp nhất + cảm giác máy thật, TUI & GUI)** → [17](17-native-feel-synthesis.md) — nghiên cứu OSS/thương mại, gap-analysis, open-spikes
- ⭐ **Risk resolutions (cách giải từng rủi ro + spike plan)** → [18](18-risk-resolutions.md) — 0 blocker; PATH 1 build-ready, PATH 2 gated 3 spike nhẹ
- Implement terminal path (P1) → [12](12-coding-profile.md) + [13](13-netbird-transport.md) + [14](14-claude-code-integration.md) + [16](16-readonly-inspector.md)
- Prior art (app mobile/desktop cho Claude Code) → [15](15-prior-art-happy-happier.md)
- GUI video path (P4) → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- Latency reference (GUI path) → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)
