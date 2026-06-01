# PaneCast — Remote-coding tool cho Apple (terminal-first hybrid)

> Tài liệu thiết kế kỹ thuật. **Codename "PaneCast"** = legacy từ thời ý tưởng screen-sharing; nay là **công cụ coding từ xa** (chạy shell/Claude Code từ xa), terminal-first.
>
> 👉 **Đọc đầu tiên: [00-overview.md](00-overview.md)** (kiến trúc + mọi quyết định) · **Log quyết định: [DECISIONS.md](DECISIONS.md)**

App điều khiển/coding từ xa trên Apple (macOS host, macOS + iOS/iPadOS client), native Swift. Use-case: **coding hằng ngày** — terminal (shell + Claude Code) là chính, cửa sổ GUI (VS Code/Xcode) là phụ.

## Scope (đã chốt)

| Hạng mục | Quyết định |
|----------|-----------|
| **Host** (máy chạy code) | macOS 14+ (Apple Silicon), **non-sandboxed** (spawn shell + CGEvent) |
| **Client** (máy xem/điều khiển) | macOS + iOS/iPadOS, native Swift |
| **Use-case** | ⭐ **Coding hằng ngày** (shell + Claude Code) — KHÔNG phải game-streaming |
| **Phạm vi mạng** | **NetBird mesh (WireGuard), giả định direct P2P** (~5–20ms). Relay = degraded (chỉ cảnh báo). Encryption + auth ở tầng VPN → app không encrypt. [13](13-netbird-transport.md) |
| **Hai data path** | **① Terminal (primary):** host PTY → TCP → libghostty client. **② GUI video (Phase 4):** ScreenCaptureKit + VideoToolbox, per-window. + **③ Inspector read-only** (tail JSONL transcript) |
| **Điều khiển** | Terminal: input = byte → PTY stdin (né input-injection). GUI window: activate-then-control + CGEvent (Phase 4) |

## Mục tiêu phi chức năng (profile CODING)

- **Terminal text nét tuyệt đối** — đi qua **PTY → libghostty, KHÔNG qua codec**. (Vấn đề 4:2:0 chỉ ảnh hưởng **GUI video-path**; với coding text-heavy, terminal path né hoàn toàn.)
- **Input/typing/cursor responsiveness** quan trọng; motion-to-photon **không cần** <16ms — coding chịu được ~40–80ms. Terminal latency = network RTT (~1–5ms LAN-direct).
- **fps KHÔNG phải mục tiêu** — màn hình tĩnh phần lớn → idle near-zero (GUI path). (120fps/ProMotion/floor-<16ms: **bỏ**.)
- 100% native Swift. Terminal renderer = **libghostty** (+ patch external-backend tự own).

## Tài liệu

> **Status:** `CURRENT` = kiến trúc hiện hành · `REFERENCE` = chỉ cho GUI video-path (Phase 4) · `SUPERSEDED` = đã thay, giữ làm lịch sử.

### ⭐ Đọc đầu tiên
| File | Nội dung |
|------|----------|
| [00-overview.md](00-overview.md) | **Architecture overview** — 3 data path + mọi quyết định, mỗi điểm link doc chi tiết |
| [DECISIONS.md](DECISIONS.md) | **Log quyết định** — 1 dòng/quyết định + status + link |

### CURRENT — kiến trúc hiện hành
| # | File | Nội dung |
|---|------|----------|
| 12 | [12-coding-profile.md](12-coding-profile.md) | Kiến trúc hybrid + thiết kế terminal path (host PTY, libghostty) + GUI video 4:2:0 + roadmap |
| 13 | [13-netbird-transport.md](13-netbird-transport.md) | Mạng NetBird (WireGuard mesh): bỏ encrypt tầng app, utun=`.other`, Bonjour không qua mesh, direct vs relayed, chọn VPN |
| 14 | [14-claude-code-integration.md](14-claude-code-integration.md) | Tích hợp Claude Code (TERM/fullscreen/auth, ô input ngoài A+B1; B2 SDK pane bỏ), học từ Warp + herdr |
| 16 | [16-readonly-inspector.md](16-readonly-inspector.md) | ⭐ **Read-only inspector** song song TUI (differentiator): tail JSONL transcript → tool cards / subagent tree / todos / workflow / CoT-placeholder |
| 17 | [17-native-feel-synthesis.md](17-native-feel-synthesis.md) | ⭐ **Best-solution synthesis** — nghiên cứu lại OSS/thương mại (Mosh/ET/Parsec/Moonlight/Xpra…): latency thấp nhất + cảm giác máy thật cho cả TUI & GUI per-window; native-feel techniques + gap-analysis + open-spikes |
| 18 | [18-risk-resolutions.md](18-risk-resolutions.md) | ⭐ **Risk resolutions** — cách giải cụ thể (verified + skeptic-checked) cho 9 rủi ro/spike: libghostty threading, coordinate mapping, 2-session encoder, decode latency, concurrent encoders, iOS reconnect, security. **0 blocker** + spike plan |
| 15 | [15-prior-art-happy-happier.md](15-prior-art-happy-happier.md) | Prior art Happy/Happier (cách hook Claude Code: SDK + hooks + relay E2E) + bài học + pitfall |

### REFERENCE — GUI video-path (Phase 4)
| # | File | Nội dung |
|---|------|----------|
| 01 | [01-architecture.md](01-architecture.md) | Kiến trúc video pipeline + latency budget *(GUI video-path)* |
| 02 | [02-host-capture-encode.md](02-host-capture-encode.md) | Capture cửa sổ (ScreenCaptureKit) + encode (VideoToolbox) |
| 04 | [04-client-decode-render.md](04-client-decode-render.md) | Decode (VideoToolbox) + render (Metal / AVSampleBufferDisplayLayer) |
| 05 | [05-input-window-control.md](05-input-window-control.md) | Inject input GUI window, raise cửa sổ, Accessibility *(R1/R2 chỉ GUI path)* |
| 09 | [09-codec-choice.md](09-codec-choice.md) | Codec (HEVC 4:2:0/8-bit, AV1/VVC/ProRes), chroma, bitrate |
| 10 | [10-latency-optimization.md](10-latency-optimization.md) | Kỹ thuật latency (Parsec/Moonlight/Sunshine): LTR, pacer, cursor client-side *(GUI path)* |
| 11 | [11-absolute-latency.md](11-absolute-latency.md) | Floor latency sâu (73-agent) + API corrections + Phase-0 spike checklist *(GUI path)* |
| 03 | [03-transport-protocol.md](03-transport-protocol.md) | Transport video (UDP), packet format, loss handling *(GUI path; NetBird overrides — [13])* |
| 06 | [06-permissions-distribution.md](06-permissions-distribution.md) | TCC permissions, sandbox, ký & notarize |

### SUPERSEDED
| # | File | Ghi chú |
|---|------|---------|
| 07 | [07-roadmap.md](07-roadmap.md) | Roadmap cũ (video-first) — **ghi đè** bởi [12 §Roadmap] / [00] (terminal = Phase 1) |
| 08 | [08-risks-open-questions.md](08-risks-open-questions.md) | Rủi ro/câu hỏi mở (phần lớn GUI-path; nhiều mục đã giải — xem [DECISIONS.md]) |

## Đọc theo vai trò
- **Hiểu kiến trúc** → [00-overview.md](00-overview.md) (+ [DECISIONS.md](DECISIONS.md))
- **Code Phase 1 (terminal MVP)** → [00](00-overview.md) → [17](17-native-feel-synthesis.md) (native-feel) → [18](18-risk-resolutions.md) (cách giải rủi ro + threading/reconnect) → [12](12-coding-profile.md) (host PTY + libghostty) → [13](13-netbird-transport.md) (transport) → [14](14-claude-code-integration.md) → [16](16-readonly-inspector.md)
- **Code GUI video-path (Phase 4)** → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- **Tối ưu latency (GUI path)** → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)

## Thuật ngữ

### Kiến trúc hiện hành
| Từ | Nghĩa |
|----|-------|
| **PTY** | Pseudo-terminal — cặp master/slave fd; host chạy shell trong PTY, đọc/ghi master fd. (KHÔNG viết "PTF".) |
| **TUI** | Terminal UI — app full-screen trong terminal (vim, Claude Code interactive) |
| **libghostty** | Engine terminal của Ghostty (C-ABI) — client renderer (full surface) |
| **NetBird / WireGuard** | Mesh VPN P2P; lo encryption + auth ở tầng mạng |
| **alt-screen** | Alternate screen buffer (DECSET 1049) — TUI chiếm cả màn |
| **OSC / kitty keyboard** | Escape sequences: OSC 52 (clipboard), OSC 133 (prompt marks); kitty keyboard protocol (Shift+Enter...) |
| **JSONL transcript** | File Claude Code ghi từng dòng JSON (messages/tool_use/...) — data source cho inspector |
| **A+B1** | Ô input ngoài: A=shell input box, B1=overlay→PTY (giữ TUI). KHÔNG B2 SDK pane (structured view = inspector read-only) |
| **setup-token** | `claude setup-token` — OAuth token 1 năm cho headless host |
| **CoT** | Chain-of-thought / thinking blocks (Opus 4.x: rỗng → inspector render placeholder) |
| **`TCP_NODELAY`** | Tắt Nagle trên socket — bắt buộc PATH 1, kẻo gom keystroke +200ms |
| **Predictive/local echo** | Client tự echo phím trước khi host phản hồi (Mosh). Ta **không** làm full (libghostty opaque); chỉ glitch-caret tuỳ chọn |
| **ET replay buffer** | Eternal Terminal: ring 64MB seq-numbered để reconnect lossless (thay tmux) |
| **Client-side cursor** | Strip cursor khỏi video, gửi vị trí qua side-channel, vẽ ở client → pointer latency = RTT (kỹ thuật native-feel GUI mạnh nhất) |
| **Lossy-first→lossless-upgrade** | GUI: gửi frame lossy ngay, re-encode lossless dirty-rect khi idle → text nét mà vẫn nhanh |
| **NV12** | `420YpCbCr8BiPlanarVideoRange` — pixel format cho zero-copy capture→VideoToolbox |
| **LTR** | Long-Term Reference frame — recovery loss không cần forced-IDR |

### GUI video-path
| Từ | Nghĩa |
|----|-------|
| **Glass-to-glass latency** | Độ trễ pixel-đổi-host → hiển-thị-client |
| **IDR / Keyframe / NALU** | Frame độc lập / đơn vị dữ liệu H.264/HEVC |
| **TCC / AX** | macOS permission system / Accessibility API |
