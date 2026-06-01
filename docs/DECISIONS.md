# DECISIONS — log quyết định

> 1 dòng/quyết định + status + link doc chi tiết. **Khi re-scope: update Ở ĐÂY trước**, rồi sửa doc liên quan (chống drift). Overview: [00-overview.md](00-overview.md).
> Status: ✅ chốt · 🔬 cần spike đo · ⏸️ defer · ❓ open.

## Triết lý
- ✅ **Làm thứ TỐT NHẤT, KHÔNG fallback.** Cam kết một lựa chọn tốt nhất, không nuôi phương án B song song: **libghostty-only** (bỏ SwiftTerm), **KHÔNG B2 SDK pane**, **cap fps ~24–30** (GUI path) cho đủ dùng + giảm băng thông/latency/CPU.
- ✅ **Phase 0 — de-risk gate TRƯỚC khi build production.** KHÔNG park ẩn số "có thể giết kiến trúc" ở phase sau (nếu vỡ thì công phase trước lãng phí). Mọi spike architecture-defining chạy ở Phase 0; chỉ build khi pass. **Phần lớn Phase 0 đã đo xong trên M1 Max/macOS 26.5** (harness: [research/spikes/vtbench]). → [18 §0]

## Phạm vi & kiến trúc
- ✅ **Use-case = coding hằng ngày** (chạy Claude Code), không game-streaming. → [12]
- ✅ **Hybrid 3-path:** terminal (primary) + read-only inspector (differentiator) + GUI video (Phase 4). → [00], [12], [16]
- ✅ **Terminal-first:** terminal path là MVP; GUI video lùi Phase 4. → [12 roadmap]

## Mạng / transport
- ✅ **NetBird (WireGuard mesh), assume direct P2P.** Relay = degraded fallback, chỉ surface + cảnh báo, KHÔNG engineer workaround. → [13]
- ✅ **MEASURED (2 máy thật M1 Max ↔ M2 Pro):** RTT **avg 11ms** (8.5–14.5), 0% loss, **P2P trực tiếp QUA INTERNET** (NAT hole-punch, local 192.168 ↔ remote public IP, không same-LAN). Giả định "5–20ms direct P2P" validated. → [18 §0]
- ✅ **Không encryption tầng app** — WireGuard E2E + NetBird ACL (deny-by-default per-port). → [13]
- ✅ **Terminal = plain TCP** (reliable; escape có thể split qua read → chỉ cần buffering, không loss-recovery). → [13], [12]
- ✅ **`TCP_NODELAY` bắt buộc** mọi socket PATH 1 ngay sau connect — Nagle gom write 1-ký-tự có thể +200ms/keystroke (impact cao, 1 dòng setsockopt). → [17]
- ✅ **Dual data/control channel** (PTY bytes ‖ `TIOCSWINSZ` resize+intent) — burst output không trễ resize-ack (bài học Zellij). → [17]
- ✅ **GUI video = plain UDP** — bỏ QUIC (TLS thừa trên WireGuard). → [03], [13]
- ✅ **KHÔNG pin `requiredInterfaceType=.wiredEthernet`** (NetBird utun = `.other` → sẽ hỏng). → [13]
- ✅ **serviceClass/DSCP vô tác dụng qua tunnel** (WireGuard zero DSCP) → adaptive rate tầng app. → [13]
- ✅ **Discovery:** Bonjour chỉ same-LAN; qua mesh dùng NetBird DNS/IP. → [13]
- ✅ **Vẫn cần control plane nhẹ** dù P2P (push notification + offline-queue): NetBird mgmt + APNs/FCM trực tiếp. → [13 §5b], [15]

## Terminal renderer (client)
- ✅ **libghostty full surface** (không vt + own renderer). → [12]
- ✅ **Tự own minimal external-backend patch** (ref `daiimus/ghostty` External.zig; Lakr233 InMemorySession + build.yml làm reference), build XCFramework qua Zig, pin upstream SHA. KHÔNG depend fork wiedymi (yếu nhất). → [12]
- ✅ **KHÔNG dùng SwiftTerm** — libghostty-only (best-only, no fallback). SwiftTerm chỉ còn là *citation* cho POSIX PTY pattern (forkpty/DispatchIO) trong [12] Part B. → [12]
- ✅ **Route mọi phím qua `ghostty_surface_key`** (Ghostty tự encode kitty/DECCKM); KHÔNG dùng bypass path Lakr233. → [12]
- ✅ **KHÔNG xây full Mosh shadow-framebuffer predictor (v1).** Opaque ghostty → bắt buộc duplicate VT parser (desync-risk); Claude Code TUI dùng alt-screen → predictor OFF ở đó; lợi ích chỉ ở shell prompt & NetBird RTT thấp Mosh tự withhold. **Glitch-window caret (cột cursor)** = tuỳ chọn rẻ Phase 2. → [17]
- ✅ **External-IO chỉ ở fork** (verified: KHÔNG có ở upstream): `wiedymi/ghostty:custom-io` (VVTerm ship) + `daiimus/ghostty:ios-external-backend` (Geistty ship, có External.zig+resize+tests). Pattern đã thực chiến. → [17]
- ✅ **Threading (C) = SOLVED:** feed_data/refresh/draw **chỉ main thread**; TCP-rx bg thread → `await MainActor.run`; CVDisplayLink cb → `DispatchQueue.main.async`. Tránh actor-suspension escape. → [18 C]
- ✅ **Echo-latency PATH 1 = MEASURED** (2 máy NetBird P2P): round-trip p50 **9.2ms** / p99 17.8ms → feels-local, **predictor KHÔNG cần** (xác nhận quyết định bỏ Mosh). → [18 §0]
- 🔬 Spike còn: alt-screen e2e, binary-size XCFramework iOS, shell-integration OSC e2e. → [12], [17]

## Host PTY
- ✅ **`openpty()` + `posix_spawn(createSession=true)`** — forkpty unsafe từ Swift. → [12]
- ✅ `setBlocking(true)` xóa O_NONBLOCK trước spawn (bug Happy #301). → [14], [15]
- ✅ **Reconnect (H) = SOLVED — ET `BackedWriter/BackedReader`** over plain TCP (64MB cap, 4MB offline gate: BUFFERED_ONLY=tiếp/SKIPPED=pause-drain), **KHÔNG port CryptoHandler** (raw bytes over WireGuard), seq dùng **int64**, server quyết RETURNING_CLIENT. UIKit `didEnterBackground`+`beginBackgroundTask`. KHÔNG cần tmux. → [18 H], [17]
- ✅ **No-buffer relay + QoS `USER_INTERACTIVE`** thread PTY→TCP (đừng chèn ring-buffer; bài học NoMachine NX). → [17]
- ✅ **iOS UIKit native-feel table-stakes:** key-repeat `DispatchSourceTimer` (350/50ms), IME-proxy `UITextView` riêng (CJK), floating-cursor `updateFloatingCursor` (5pt→arrow), accessory bar gated keyboard-visible. → [17]

## Claude Code integration
- ✅ **`TERM=xterm-ghostty`** (kitty keyboard + DEC2026). Chấp nhận rủi ro paste bug #54700; toggle fallback `xterm-256color`. → [14]
- ✅ **Fullscreen mode** (`CLAUDE_CODE_NO_FLICKER=1`) cho remote PTY. → [14]
- ✅ **Auth = Subscription OAuth + `claude setup-token`** (token 1 năm headless); hoặc reuse `~/.claude/.credentials.json`. **KHÔNG** tự chạy PKCE (scope `user:inference` quota uncertain). `CLAUDE_CODE_ENTRYPOINT=remote_mobile`. → [14], [15]
- ✅ **Ô input ngoài = A + B1.** A: shell input box + block (`COMMAND_FINISHED` callback + tự sniff `ESC[?1049h/l`). B1: Claude Code giữ TUI + overlay compose-box ghi PTY (DelayedEnter). **Dedup ring buffer bắt buộc** (compose-box + PTY cùng feed). → [14]
- ✅ **KHÔNG làm B2 (SDK pane).** TUI = Claude Code thật (skills/slash/mọi feature native 100%); structured view = **read-only inspector [16]** (không drive agent). → [14], [16]
- ✅ **Skills + custom slash commands chạy trong SDK** by default (settingSources mặc định load `.claude/`; chỉ cần `cwd`=project root). Built-in TUI-only command → native equivalent. → [14]
- ⏸️ **Orchestration (herdr/agent-teams) = be a client** (speak NDJSON, tránh AGPL embed), KHÔNG build product. → [14], [15]

## Inspector (read-only)
- ✅ **Read-only**, data = **tail JSONL transcript** (path từ SessionStart hook) + hooks (PostToolUse/SubagentStop). NWConnection thứ 2 length-prefixed. → [16]
- ✅ **Subagent content ở file riêng** (`subagents/agent-<hash>.jsonl`) — phải watch dir + dùng `SubagentStop.agent_transcript_path`. → [16]
- ✅ **CoT/thinking = placeholder-only** (Opus 4.x field thinking rỗng/omitted; KHÔNG theo flag undocumented). → [16]
- ⏸️ Workflow panel + agent teams inbox = defer (research preview). → [16]

## Codec (GUI video path — Phase 4)
- ✅ **HEVC Main 8-bit 4:2:0 + constant-quality** (Quality≈0.6, Apple Silicon). 10-bit = optional. → [09]
- ✅ **4:4:4 dropped** (Apple HW không encode được); text crisp đã đi PTY path. AV1/VVC không HW-encode → loại. → [09]
- ✅ `AllowFrameReordering=false`, infinite GOP + on-demand IDR/LTR. ⚠️ `AllowOpenGOP=false`/`MaxFrameDelayCount=0` **chưa verify là part SDK canonical recipe** (giữ belt-and-suspenders). → [02], [09], [17]
- ✅ **4-flag low-latency recipe**: Specification `EnableLowLatencyRateControl` (✅ verified HEVC trên Apple Silicon) + `RequireHardwareAcceleratedVideoEncoder`, Property `RealTime`+`ExpectedFrameRate`+`PrioritizeEncodingSpeedOverQuality`. Đặt Specification key lúc **tạo session** (không SetProperty). → [17]
- ✅ **NV12 capture zero-copy** (`420YpCbCr8BiPlanarVideoRange`) → tránh BGRA→NV12 convert. KHÔNG set `max_ref_frames=1` (bẫy H.264 → all-IDR). → [17]
- ✅ **Lossy-first → lossless-upgrade = 2 VTCompressionSession** (📏 MEASURED M1 Max): **Session A** live **low-latency-RC** (`EnableLowLatencyRateControl`+`AverageBitRate`+`DataRateLimits=[12_000_000/8,1.0]`=12Mbps+`SpatialAdaptiveQPLevel=Disable`, omit ProfileLevel) — **đo 7.5ms** (constant-quality 24ms quá chậm → KHÔNG dùng cho live); **Session B** on-demand `Quality=1.0`+`AllowTemporalCompression=false` (**không có `Lossless` key — -12900**; all-intra là crisp tối đa). → [18 E], [17]
- 🔬 Spike: **low-latency-RC (cần target bitrate) vs constant-quality** cho text legibility; `kVTCompressionPropertyKey_Lossless` khả dụng + frame-size; ForceLTRRefresh type, mach_timebase M2/M3/M4, fringing 4:2:0. → [12 Phase 0], [17]

## PATH 2 native-feel (GUI video) — từ [17]
- ✅ **Client-side cursor rendering (impact CAO NHẤT):** `showsCursor=false` strip cursor khỏi capture; host sample `NSEvent` ~120Hz gửi position+shape qua **socket UDP riêng <64B** (KHÔNG multiplex video); client composite Metal-quad ở display-refresh → **pointer latency = RTT**. (Parsec US 9,798,436 + Moonlight + Selkies.) → [17]
- ✅ **Idle-skip cụ thể:** đọc `SCStreamFrameInfo.status==.idle` → return ngay; heartbeat IDR ~1s. → [17]
- ✅ **Loss recovery = LTR-refresh + ~20% Reed-Solomon FEC** thay forced-IDR (cần ACK client→host, fallback IDR 2-RTT); seq-number 4B/packet. → [17]
- ✅ **Frame pacing client = `CADisplayLink`/VSync** (KHÔNG decode-completion); show-last-frame khi queue rỗng; `CVMetalTextureCache` zero-copy; `CAMetalLayer.maximumDrawableCount=2`. → [17]
- ✅ **Window-geometry channel riêng** (move/resize/title) → client `NSWindow` reposition trước frame video kế. → [17]
- ✅ **1 `VTCompressionSession`/window**, gate `RequireHardwareAcceleratedVideoEncoder=true`. 📏 **MEASURED 2 máy: ~6 window 1080p@30fps / encode-engine** (M2 Pro 1-engine→~6 @184fps; M1 Max 2-engine→~8–10 @340fps; 32 session ceiling). Research "2–4" SAI. Client chỉ decode → encode chỉ áp khi làm host. 1–3 window = non-issue. Query `UsingHardware` 1 lần lúc tạo (poll = crash mediaserverd; -12900 nếu low-latency); recreate khi resize; retry -12905. → [18 G]
- ✅ **Coordinate mapping (B) = SOLVED**: `kCGWindowBounds`→normalize→`postToPid` (cần TCC "Post Event"); fix multi-monitor bằng flip Cocoa-space trước `NSScreen.intersection`; window-move = AX `kAXWindowMovedNotification`(END)+poll `CGWindowListCopyWindowInfo`(drag). Tag `eventSourceUserData` filter self-inject. → [18 B], [05]
- ✅ **macOS 26 multi-NALU — ĐÃ ĐO = 1 NALU/CMSampleBuffer** (downgraded từ watch-item; vẫn iterate NALU defensively). → [18]
- ✅ **F decode latency — MEASURED p99 1.1ms** (synchronous, KHÔNG 2-frame-buffer). → [18 F]
- ✅ **D cursor-strip = MEASURED PASS** (client M2 Pro): `showsCursor=false` strip sạch cursor khỏi per-window capture (diff 120px=cursor, có ở true/không ở false). → [18 D]
- ✅ **Phase 0 hết spike gating** — toàn bộ rủi ro architecture-defining đã đo PASS trên 2 máy thật. Còn lại chỉ là spike triển khai (alt-screen e2e, iOS A-series re-confirm). → [18 §0]

## FPS / latency
- ✅ **Cap fps GUI video-path ~24–30** (không 60/120) — đủ mượt cho scroll/gõ, giảm băng thông + latency + CPU. `minimumFrameInterval = CMTime(1,30)` + idle-skip (near-zero khi tĩnh). → [12], [09]
- 🔬 **queueDepth = tension chưa chốt:** [11]/[12] dùng **2–3** (latency thấp nhất, default thực=8); [17] nêu Sunshine dùng **5** (chống rớt frame khi GPU tải nặng 60–120fps). Profile ta (24–30fps, 1 window, idle, HW HEVC ~5–18ms) → **giữ 2–3**, spike dưới contention thật. → [17], [11]
- ✅ **Terminal path latency = network RTT** (~1–5ms LAN-direct), không vsync/encode/decode. → [13]
- ✅ **Floor-analysis [11] chỉ áp dụng GUI video-path.** Motion-to-photon <16ms / 120fps / ProMotion / beam-racing = **over-engineering cho coding → DROP**. GUI path target **40–80ms**. → [11], [12]

## Distribution
- ✅ **Host non-sandboxed** (spawn shell + CGEvent cho GUI path) → Developer-ID + notarize, **ngoài Mac App Store**. Client viewer có thể lên MAS. → [06], [12]

## Input injection (GUI video path — Phase 4 only)
- ✅ **Activate-then-control, MỘT cửa sổ tại một thời điểm (phải focus).** KHÔNG cần inject vào cửa sổ nền (né luôn R1/R2 cooperative-activation macOS 14). Raise + focus cửa sổ target rồi post CGEvent; tag `eventSourceUserData` để filter self-inject. → [05], [17]
- ✅ Chỉ áp dụng GUI video-path; terminal path né hoàn toàn (input = byte → PTY stdin). → [05]
- 🔬 Còn lại = **coordinate mapping** client video-region → host window/screen (Retina + y-flip + window-move). → [17 §3.9]

## Security / auth
- ✅ **KHÔNG auth tầng app — plain.** Chỉ dùng cá nhân, trong NetBird/Tailscale mesh → biên giới = WireGuard membership + NetBird ACL (deny-by-default per-port). Bỏ pairing/token để giảm latency. **Accepted residual risk:** PTY nhận byte = RCE bounded bởi mesh membership; nếu một peer mesh bị chiếm thì host bị lộ — chấp nhận cho personal-use. → [13]
