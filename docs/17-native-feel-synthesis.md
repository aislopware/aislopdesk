# 17 — Best-solution synthesis: latency thấp nhất + cảm giác "máy thật" (TUI & GUI per-window)

> **STATUS: CURRENT.** Tổng hợp từ nghiên cứu lại 7 "họ" giải pháp OSS + thương mại (15 agents, ~1.48M tokens) để chốt thiết kế **tốt nhất** cho 2 path, ưu tiên (a) latency thấp nhất và (b) cảm giác **như đang dùng máy local**, không phải remote. Corpus: [research/17-tui-gui-best-solution.json](research/17-tui-gui-best-solution.json). Quyết định rút ra đã đẩy vào [DECISIONS.md](DECISIONS.md); doc này là phần **why + cơ chế chi tiết**.
>
> Triết lý xuyên suốt (xem [00](00-overview.md)): **một lựa chọn tốt nhất, không fallback.**

## TL;DR (headline)

1. **PATH 1 (terminal) đã gần như local sẵn** ở RTT 5–20ms của NetBird. Raw VT byte-stream qua **plain TCP + `TCP_NODELAY`** + **libghostty external-IO** = full-fidelity, không round-trip protocol. **KHÔNG xây Mosh shadow-framebuffer predictor cho v1** (xem §2.4). Thêm: **dual data/control channel** + **ET-style replay buffer** để reconnect không mất byte.
2. **PATH 2 (GUI per-window), quyết định đắt giá nhất = client-side cursor rendering**: tách con trỏ khỏi video, gửi vị trí+bitmap qua side-channel UDP riêng, composite trên client ở display-refresh → **pointer latency = RTT**, độc lập hoàn toàn với encode/decode. Đây là ranh giới giữa "feels remote" và "feels local".
3. **PATH 2 text nét cho cửa sổ editor**: **lossy-first → lossless-upgrade** (encode quality ~0.65 gửi ngay, rồi re-encode dirty-rect bằng `kVTCompressionPropertyKey_Lossless` khi idle) — vừa nhanh vừa pixel-perfect khi user dừng đọc.
4. **Rủi ro chưa giải của PATH 2** = **map toạ độ video-region của client → window/screen của host** cho CGEvent injection (Retina scaling + window moves). Phải spike trước khi commit PATH 2.

---

## 1. Phương pháp & nguồn

Fan-out 7 họ, mỗi họ **survey → deep-dive verify** (đối chiếu source code/RFC/patent), rồi synthesis:

| # | Họ | Cốt lõi rút ra |
|---|----|----------------|
| 0 | Terminal/TUI protocols (Mosh, Eternal Terminal, tmux/zellij, WezTerm mux) | Mosh predictive echo + ET replay buffer + dual-channel |
| 1 | iOS terminal clients (Blink, VVTerm, Geistty, SwiftTerm, Termius) | libghostty external-IO (fork thật) + UIKit native-feel table-stakes |
| 2 | GUI thương mại (Parsec, Jump Fluid, Splashtop, AnyDesk, NoMachine NX) | VideoToolbox low-latency recipe + cursor side-channel (Parsec patent) |
| 3 | GUI open-source (Moonlight/Sunshine, RustDesk, Chrome RD, Selkies) | **Client-side cursor** + LTR/FEC loss recovery + frame pacing |
| 4 | Per-window remoting (RDP RemoteApp, X11, Xpra, waypipe, SCKit per-window) | **Lossy-first→lossless-upgrade** + idle-skip + window-geometry channel |
| 5 | Apple-native (Sidecar, ARD High-Perf, ScreenCaptureKit, VideoToolbox) | 4-flag recipe + NV12 zero-copy + concurrent-session limit |
| 6 | Feels-native cross-cut (prediction, cursor, jitter, pacing, FEC, coalescing) | Xếp hạng kỹ thuật theo impact (§4) |

Mọi claim đã verify ngược về source. Các **correction** đáng chú ý (survey sai → đã sửa) nằm rải trong §2–§3 với chữ "⚠️".

---

## 2. PATH 1 — Terminal: thiết kế tốt nhất

### 2.1 Transport: raw TCP + `TCP_NODELAY` (bắt buộc) + dual channel

- Raw PTY byte-stream qua **plain TCP** (đã chốt [13]). **ADD mới: bật `TCP_NODELAY` ngay sau `connect()`** trên mọi socket. Nagle gom các write 1-ký-tự có thể cộng **tới 200ms** vào echo — đây là omission duy nhất xuất hiện ở cả các stack terminal được khảo sát. Một dòng `setsockopt`, impact **cao**.
- **Dual channel**: kênh data (PTY bytes) tách khỏi kênh control (`TIOCSWINSZ` resize + intent/disconnect). Bài học từ Zellij: một burst output của Claude Code không được làm trễ resize-ack. Effort thấp (kênh framed thứ 2 hoặc sub-stream multiplex).
- **No-buffer relay** (bài học NoMachine NX): đừng chèn ring-buffer giữa `posix_spawn`→TCP write; relay lockless, thread relay đặt **`QOS_CLASS_USER_INTERACTIVE`**.

### 2.2 Renderer: libghostty external-IO — sự thật về fork

- `ghostty_surface_feed_data` / `ghostty_surface_set_write_callback` **KHÔNG có ở upstream Ghostty HEAD** (đã verify: `include/ghostty.h` 1208 dòng, không có 2 hàm này). Chỉ tồn tại ở fork:
  - **`wiedymi/ghostty` branch `custom-io`** — VVTerm ship trên đây (`scripts/build.sh` clone đúng ref này).
  - **`daiimus/ghostty` branch `ios-external-backend`** — Geistty ship trên đây; thêm `External.zig` (~379 dòng) + có resize callback + tests.
- Quyết định ([12]/[DECISIONS]) **tự own minimal patch, ref `daiimus/External.zig`** vẫn đúng và nay được xác nhận là pattern **đã chứng minh trên 2 app iOS đang chạy**. `use_custom_io = true` chuyển termio backend từ `Exec.zig` (PTY) sang `External.zig` (không spawn shell local).
- **Data IN**: bytes TCP đến → `ghostty_surface_feed_data(...)` → `ghostty_surface_refresh` + `ghostty_surface_draw` qua **coalescing `DispatchQueue.main.async` guard** (pattern `scheduleCustomIORedraw` của VVTerm). **Data OUT**: keypress → C write-callback (fire **synchronous trên main thread** từ key-encoder của Ghostty) → schedule `Task(.userInitiated)` ghi TCP.
- ⚠️ **Spike threading bắt buộc**: `ghostty_surface_refresh/draw` có thể drive an toàn từ background TCP-receive thread, hay **mọi thứ phải funnel qua `@MainActor`**? (Geistty/VVTerm đều gọi feed trên `@MainActor`.) Quyết định coalescing-redraw + tính khả thi của fork phụ thuộc câu này.
- Build XCFramework cần **Zig + Apple Silicon** lúc build → chi phí build-infra phải tính trước.

### 2.3 Reconnect: ET-style replay buffer (chọn thay vì tmux)

- **Eternal Terminal `BackedWriter`**: host giữ circular buffer **64MB** (`MAX_BACKUP_BYTES`, verified) các packet PTY output gắn **sequence number** đơn điệu. Client reconnect → gửi last-seq nó đã nhận → host `recover(lastValidSeq)` replay phần đuôi. **Lossless resume**, không cần UDP, không cần tmux phía host.
- **Tại sao KHÔNG phụ thuộc tmux cho reconnect**: họ iOS đề xuất tmux cho session-persistence, nhưng làm reconnect *phụ thuộc* tmux = **dependency cứng** (host phải cài tmux + quản lý named session). Theo best-only, ta **own** replay buffer trong app → reconnect không cần tmux. (Process-survival thì dùng persistent daemon giữ master FD — [12 §6]; tmux vẫn là **tuỳ chọn v2** thuần tiện cho server-side scrollback + pane mapping, không bắt buộc.)
- ⚠️ Spike: validate handshake reconnect qua một chu kỳ iOS background→foreground thật (gồm `beginBackgroundTask` suspend timing) để xác nhận resume byte-exact.

### 2.4 Predictive echo: tại sao KHÔNG full Mosh (CHANGE) + glitch-caret (tuỳ chọn)

Đây là kết luận quan trọng và **ngược trực giác**:

- Mosh `PredictionEngine` (speculative local echo trên **shadow VT framebuffer**) là kỹ thuật kinh điển làm gõ "tức thì" trên link chậm (mosh.org: median SSH 503ms vs mosh gần như tức thì, EV-DO ~500ms RTT). Nhưng:
  1. `ghostty_surface_t` là **`void*` opaque** (verified — không có hàm đọc cell ở C API). Muốn predict, **bắt buộc** dựng một **VT parser thứ 2** chạy song song giữ shadow framebuffer → gánh nặng maintenance + nguy cơ **desync** (parser kém hoàn chỉnh hơn libghostty → misprediction + snap giật).
  2. Mosh **tự tắt prediction trong app full-screen** dùng cursor-positioning (vim/emacs/htop). **Claude Code TUI cũng dùng alt-screen + cursor-positioning** → prediction sẽ **OFF** ngay trong chính Claude Code. Lợi ích chỉ còn ở **bare shell prompt**.
  3. Ở **adaptive mode**, Mosh **withhold prediction trên link nhanh** (SRTT_TRIGGER_HIGH=30ms → tương ứng raw SRTT ~60ms). NetBird 5–20ms RTT → prediction gần như luôn bị tắt theo thiết kế của chính Mosh.
- ⚠️ Correction từ verify source (đừng để doc khác chép sai): ngưỡng underline gate trên **`send_interval`** (= `ceil(SRTT/2)` clamp [20,250]ms), **không** phải raw SRTT; `FLAG_TRIGGER_HIGH=80` ⇒ raw SRTT ~160ms. **CR (0x0d) CÓ gọi `become_tentative()`** (không bị loại trừ); chỉ CSI `C`/`D` (←/→) là predict, mọi CSI khác → tentative.
- **Quyết định**: **không** xây full shadow-framebuffer predictor cho v1 — saving 5–20ms chỉ áp ở shell prompt không bõ desync-risk. **Tuỳ chọn rẻ (Phase 2)**: **glitch-window speculative caret** — chỉ theo dõi **cột cursor**, nhích caret mờ khi không có echo trong ~150–250ms ("đã nhận input" feedback lúc Claude Code stall) mà không cần shadow VT parser. 80% lợi ích với ~0 desync-risk.
- ⚠️ Spike #1 (quyết định luôn việc trên): **đo echo-latency end-to-end thật trên NetBird mesh** (PTY relay → TCP → shell echo → libghostty render) ở cả 5ms và 20ms RTT. Một con số này quyết định predictor có bao giờ cần không.

### 2.5 iOS native-feel: table stakes (ADD)

Thiếu bất kỳ mục nào dưới đây là "chạy được" nhưng **không** giống app iOS native (verified từ Blink/VVTerm/SwiftTerm):

- **Key-repeat = `DispatchSourceTimer`** thủ công: UIKit chỉ bắn `pressesBegan`/`pressesEnded` **một lần**, không tự repeat. Dùng delay đầu **350ms**, repeat **50ms** (20Hz) → bắn lại key event. Thiếu cái này, giữ arrow/Delete không lặp — phá pattern navigation phổ biến nhất.
- **IME proxy = `UITextView` ẩn riêng**, KHÔNG implement `UITextInput` trên cùng view nhận `pressesBegan` (thứ tự responder không xác định → vỡ nhập **CJK**; Claude Code có user Nhật). Ctrl/Alt+letter route thẳng `ghostty_surface_key`; còn lại qua IME proxy → `ghostty_surface_text`.
- **Floating cursor** (`updateFloatingCursor(at:)`): drag ngang > **5pt** → arrow ←/→ (SwiftTerm verified). Trên iPhone không hardware-keyboard, đây là **cách duy nhất** di chuyển cursor. (Lưu: SwiftTerm gate drag dọc chỉ trong alt-screen.)
- **Accessory bar** (Ctrl/Esc/Tab/arrows) chỉ hiện khi software keyboard hiện (phát hiện hardware-kbd qua keyboard frame height < ~150pt).
- iOS giết TCP vài giây sau background → đã giải bằng **ET replay buffer** (§2.3) + `beginBackgroundTask` (`MIN(backgroundTimeRemaining*0.9, 300s)`).

---

## 3. PATH 2 — GUI per-window: thiết kế tốt nhất (Phase 4)

> PATH 2 là pipeline **tách hẳn** PATH 1 — đừng hợp nhất libghostty surface với video. (Bài học âm bản từ họ iOS: libghostty chỉ render cell-grid của chính nó.)

### 3.1 Capture: SCContentFilter(window:) + NV12 zero-copy + queueDepth

- **`SCContentFilter(window:)`** per-window: trên macOS 14+ capture **backing store** của window → đúng kể cả khi bị che (verify trên OS đích).
- **`pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12)** → hand-off **zero-copy** sang `VTCompressionSession`, **tránh bước BGRA→NV12** (đường FFmpeg-wrapped như Lumen phải convert vì đi qua avcodec). ⚠️ Lumen thực ra dùng `32BGRA` + capture **virtual display** chứ không per-window — đừng chép mù config của Lumen.
- **`showsCursor = false`** ở `SCStreamConfiguration` → cursor bị **loại khỏi frame** (đây là cách per-window-correct; **KHÔNG** dùng `CGDisplayHideCursor` system-wide). Là tiền đề cho client-side cursor (§3.3).
- **queueDepth — tension thật, để spike, không chốt mù:**
  - [11]/[12] (workflow latency 73-agent): default thực = **8**; dùng **2–3** cho latency thấp nhất (mỗi slot = 1 frame-interval latency tiềm năng).
  - Workflow này: **5** (giá trị Sunshine/Apple-sample đã chứng minh); cho rằng "3 là minimum" là community-inference chưa verify.
  - **Reconcile**: 5 là giá trị Sunshine tune cho **game-stream 60–120fps GPU tải nặng**. Profile của ta = **24–30fps, 1 window, phần lớn idle, HW HEVC ~5–18ms** → budget release `minimumFrameInterval × (queueDepth−1)` ở depth-3/30fps = 66ms ≫ 18ms encode → **giữ 2–3 cho latency thấp hơn**. ⚠️ Spike đo dưới GPU contention thật; nếu rớt frame thì nâng lên 5.
- **Release constraint (verified WWDC22 s10155)**: phải release surface trong `minimumFrameInterval × (queueDepth−1)`; release `CMSampleBuffer` surface **ngay** sau khi đưa `CVPixelBuffer` cho encoder.

### 3.2 Encode: VTCompressionSession 4-flag low-latency recipe (ADD/refine)

Native `VTCompressionSession` (KHÔNG FFmpeg wrapper), HEVC 8-bit 4:2:0 (`kVTProfileLevel_HEVC_Main_AutoLevel`):

- **Specification keys** (đặt trong dict lúc **tạo session**, không qua `SetProperty` — đây là cái bẫy phổ biến):
  - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` — ✅ **verified hợp lệ cho HEVC trên Apple Silicon** (host của ta). (FFmpeg `videotoolboxenc.c`: `TARGET_CPU_ARM64 && AV_CODEC_ID_HEVC`.) Giải toả nghi vấn cũ "HEVC low-latency có khả dụng?".
  - `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = true` — hard-fail thay vì âm thầm rớt về software.
- **Property keys** (qua `VTSessionSetProperty`): `RealTime=true`, `ExpectedFrameRate=30`, `PrioritizeEncodingSpeedOverQuality=true` (đúng 4-flag recipe của Apple), `AllowFrameReordering=false` (no B-frame), `MaxKeyFrameInterval=INT_MAX` (IDR on-demand).
- ⚠️ **Corrections vs doc 09/DECISIONS**:
  - `MaxFrameDelayCount=0` và `AllowOpenGOP=false` mà ta đang liệt như "canonical SDK recipe" thực ra **không được verify là part của recipe SDK** — vô hại nhưng đừng claim là chuẩn Apple. Giữ như belt-and-suspenders, đánh dấu verify.
  - **`EnableLowLatencyRateControl` cần target bitrate** (bitrate-based, không phải constant-quality). ✅ **ĐÃ GIẢI bằng đo ([18 §0]):** live frame dùng **low-latency-RC** (đo 7.5ms) — KHÔNG constant-quality (đo 24ms, quá chậm). Crisp-upgrade tách sang **Session B** `Quality=1.0` all-intra. Hết tension (2 session, mỗi cái 1 rate-controller).
  - **KHÔNG set `max_ref_frames=1` cho H.264** (verified Sunshine `video.cpp`): trên Apple-Silicon VideoToolbox H.264, nó biến **mọi frame thành IDR** → bandwidth ~3×. HEVC không bị (an toàn). Bẫy nếu sau này thử H.264.
  - **Đừng query `UsingHardwareAcceleratedVideoEncoder` khi low-latency mode bật** (trả -12900).

### 3.3 Client-side cursor rendering — kỹ thuật impact CAO NHẤT (ADD)

Xác nhận **độc lập bởi 3 họ** (Parsec, Moonlight, Selkies). Là khác biệt đơn lẻ giữa "feels remote" và "feels local":

1. Host: `showsCursor=false` (cursor không vào video) — §3.1.
2. Host: sample `NSEvent` mouse position ~**120Hz**; gửi **position (CGPoint host-space) + shape (`NSCursor` image + hotspot)** qua **socket UDP riêng <64-byte**, **KHÔNG multiplex chung socket video** (nếu chung, video backpressure sẽ làm trễ cursor).
3. Client: composite cursor là **Metal quad / `CALayer`** đè lên decoded frame, ở **display-refresh**.
- ⟹ **Pointer latency = RTT thuần** (5–20ms), tách hoàn toàn khỏi encode/decode (thường 30–50ms).
- ⚠️ Correction: patent Parsec đúng là **US 9,798,436** (survey ghi nhầm). moonlight-qt hiện chỉ toggle `SDL_ShowCursor()` chứ không có cursor-shape-over-side-channel riêng — pattern đầy đủ lấy từ **Selkies**.
- ⚠️ Spike: xác nhận `showsCursor=false` **thực sự** loại cursor khỏi per-window `CMSampleBuffer` trên macOS đích (cursor có thể đã composite vào IOSurface).

### 3.4 Lossy-first → lossless-upgrade — text nét cho editor (ADD)

Giải bài toán "nhanh vs đọc được" cho coding (mở rộng quyết định "4:4:4 dropped, text nét chỉ qua PTY" — nay **GUI window cũng có text pixel-perfect** sau khi user dừng):

1. Mỗi `SCFrameStatus.complete`: encode bằng **Session A low-latency-RC** (KHÔNG constant-quality) gửi **ngay** → first-frame ~RTT. 📏 **Đo M1 Max ([18 §0]): low-latency-RC 7.5ms vs constant-quality 0.65 = 24ms** → live frame bắt buộc low-latency-RC.
2. Tích luỹ **dirty-rect union**; start `DispatchSourceTimer` (GCD) delay **~200–600ms** = `max(batch_delay×5, 200ms)`. ⚠️ **KHÔNG phải 1000ms** — 1000ms là `LOCKED_BATCH_DELAY` của Xpra cho iconic/idle window, không phải refresh-timer.
3. Frame mới đến trước khi timer fire → **cancel & reschedule** (logic `cancel_refresh_timer` của Xpra).
4. Timer fire sau idle thật → re-encode dirty-union. **Cập nhật [18 E]: dùng SESSION RIÊNG (Session B)** all-intra `Quality=1.0`+`AllowTemporalCompression=false` (không nhồi vào session live — low-latency-RC cần bitrate, xung khắc constant-quality). Encode dạng **INTRA slice** → loss UDP của bản upgrade không corrupt decode state.
5. **Window chrome** (title/scroll bar, height < ~40px) → luôn lossless ngay pass đầu.
- ⚠️ Spike: xác nhận khả dụng `kVTCompressionPropertyKey_Lossless` + đo kích thước frame lossless cho window editor 1080p (để size UDP send-queue).

### 3.5 Idle-skip + damage tracking (refine)

- Trong `didOutputSampleBuffer` đọc `SCStreamFrameInfo.status`; nếu `== .idle` → **return ngay** (không IOSurface, không encode, không send). Đây là **damage-check zero-cost** (tương đương X11 DAMAGE DeltaRectangles) và giữ **encoder slot trống** để frame thật kế tiếp (do keystroke) được HW ngay. >90% frame trong phiên coding là tĩnh.
- Heartbeat **IDR ~mỗi 1s** trên window idle (để client reconnect/loss-recover bắt được frame).

### 3.6 Transport + loss: UDP seq + FEC + LTR (refine)

- Plain UDP qua NetBird (no DTLS/QUIC — WireGuard đã ChaCha20-Poly1305; inner-crypto thuần overhead). **4-byte sequence number/packet** cho ordering/loss-detect.
- **Reed-Solomon FEC ~20% parity/frame** (default Sunshine).
- **Ưu tiên LTR-frame recovery hơn forced-IDR**: `kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh` khi mất → tránh spike bandwidth/latency của keyframe. Cần **kênh ACK client→host** nhỏ (rẻ ở RTT của ta), fallback IDR sau timeout 2-RTT. ⚠️ Correction: hướng invalidation là **client→server** (client gửi RFI range; server mark ref-frame invalid).
- Cap encode-queue **2–3 frame in-flight**; drop oldest; **không bao giờ** backpressure thread callback của SCKit.

### 3.7 Frame pacing client (ADD)

- Drive hiển thị client từ **`CADisplayLink` (VSync)**, KHÔNG từ decode-completion. Queue rỗng → **giữ last decoded frame** (Moonlight pacer: `TIMER_SLACK ~3ms`, time-critical thread). Late frame thì **skip**, không queue → tránh tích luỹ latency.
- Decode session `RealTime=true`; **`CVMetalTextureCache`** zero-copy CVPixelBuffer→Metal; **`CAMetalLayer.maximumDrawableCount=2`** giữ display latency ~1 vsync.
- ⚠️ Spike: đo decode latency `VTDecompressionSession` trên Apple-Silicon client thật — xác nhận **single-frame**, không bị âm thầm 2-frame-buffer (`RealTime=true` **không** đảm bảo điều này) → quyết định budget motion-to-photon 30fps có giữ được không.

### 3.8 Window-geometry metadata channel (ADD)

Kênh metadata **riêng** mang window **move/resize/title** → client `NSWindow` reposition **ngay, trước frame video kế**. Mọi giải pháp per-window remoting (RDP RemoteApp/RAIL, X11, Xpra) đều có. ⚠️ Correction RAIL (MS-RDPERP §1.3.2.5): move bằng chuột **không** gửi Client-Window-Move PDU — chỉ gửi mouse-button-up, server suy ra vị trí; PDU chỉ cần cho move bằng keyboard.

### 3.9 Input: CGEvent + RỦI RO map toạ độ (KEEP + spike #1 của PATH 2)

- `CGEventPost(kCGHIDEventTap, ...)` cho click/key (cần Accessibility cấp trước launch; non-sandbox; ngoài MAS — đã chốt [06]). `CGWarpMouseCursorPosition` cho absolute move. **Tag mọi event bằng `eventSourceUserData`** để host filter event tự-inject (tránh loop).
- **Mouse-move coalescing**: drain pending moves, cộng dồn delta, gửi 1 lần (pattern `SDL_PeepEvents` của Moonlight).
- ✅ **Coordinate mapping = SOLVED ([18 B]):** `kCGWindowBounds`(top-left CG)→normalize→`postToPid` (cần TCC **"Post Event"**); fix multi-monitor bằng **flip sang Cocoa-space** (`primaryH − y − h`) trước `NSScreen.frame.intersection` để lấy đúng `backingScaleFactor`; window-move = AX `kAXWindowMovedNotification`(fire ở END) + poll `CGWindowListCopyWindowInfo` khi đang drag. Tag `eventSourceUserData` filter self-inject.
- **Input nền:** quyết định **activate-then-control 1 cửa sổ/lần (phải focus)** → cửa sổ target thành frontmost → `CGEventPost` universal (mọi loại app), né SkyLight private-API. ([18 A])

### 3.10 Giới hạn số window đồng thời (ADD constraint)

- **2–4 `VTCompressionSession` HEVC HW đồng thời** trên Apple Silicon trước khi rớt về software → **cận trên số window GUI remote đồng thời**. ⚠️ Spike benchmark con số chính xác trên hardware đích.
- 1 `VTCompressionSession` per tracked window (giữ encoder-state qua frame; tránh bug per-buffer flicker của waypipe).

---

## 4. Native-feel techniques — xếp theo impact

| Kỹ thuật | Path | Impact | Effort |
|----------|------|--------|--------|
| **Client-side cursor** (strip + side-channel UDP + composite ở refresh) | GUI | **Cao** — pointer = RTT, tách khỏi codec; ranh giới local/remote | Trung bình |
| **`TCP_NODELAY`** mọi socket PATH 1 | TUI | **Cao** — Nagle có thể +200ms/keystroke | Trivial |
| **libghostty external-IO** over raw TCP | TUI | **Cao** — full-fidelity, event-driven redraw, 0 round-trip | TB-cao (own fork) |
| **`SCFrameStatus.idle` skip** + heartbeat IDR | GUI | **Cao** — >90% frame tĩnh; giữ encoder slot trống | Thấp |
| **Lossy-first → lossless-upgrade** | GUI | **Cao** — nhanh + text pixel-perfect khi dừng | Trung bình |
| **VideoToolbox 4-flag low-latency + NV12 zero-copy** | GUI | **Cao** — encode ~5–18ms, no reorder, no BGRA convert | Trung bình |
| **ET replay buffer** reconnect | TUI | **Cao** — resume byte-exact qua iOS background | Trung bình |
| **CADisplayLink pacing + show-last-frame** | GUI | TB-cao — hết judder, latency ~1 vsync | Thấp-TB |
| **iOS UIKit table-stakes** (key-repeat/IME/floating-cursor/accessory) | TUI | TB-cao — "works" → "native iOS" | Trung bình |
| **Dual data/control channel** | TUI | TB — burst output không trễ resize | Thấp |
| **Glitch-window speculative caret** (cột cursor) | TUI | TB — feedback lúc stall, ~0 desync-risk | Thấp |
| **LTR + ~20% Reed-Solomon FEC** thay forced-IDR | GUI | TB — tránh spike; near-irrelevant ở loss NetBird nhưng cost ~0, cứng WiFi | Trung bình |
| **QoS `USER_INTERACTIVE`** thread PTY-relay & capture+encode | cả 2 | TB — giữ path latency-critical được schedule trước | Trivial |

---

## 5. Gap analysis vs quyết định hiện tại

> **KEEP** = đúng, giữ. **CHANGE** = sửa/làm rõ. **ADD** = bổ sung mới. (Đã đẩy vào [DECISIONS.md](DECISIONS.md).)

**PATH 1**
- KEEP — raw VT byte qua plain TCP + libghostty; no app-crypto; input = byte→PTY stdin (né input-injection).
- CHANGE — **không** xây full Mosh predictor cho v1 (opaque ghostty → duplicate parser; lợi ích chỉ ở shell prompt). Glitch-caret là tuỳ chọn Phase 2.
- CHANGE — libghostty external-IO **chỉ có ở fork** (wiedymi `custom-io` / daiimus `ios-external-backend`); commit own patch là tracked dependency (đã đúng hướng).
- ADD — `TCP_NODELAY`; ET 64MB seq replay-buffer (chọn thay tmux); dual data/control channel; QoS USER_INTERACTIVE relay; iOS UIKit table-stakes.

**PATH 2**
- KEEP — `SCContentFilter(window:)`; HEVC 8-bit 4:2:0; plain UDP; fps cap 24–30 + idle-skip; CGEvent injection (chấp nhận Accessibility/non-sandbox/ngoài-MAS).
- CHANGE — **`EnableLowLatencyRateControl` MEASURED cho HEVC trên Apple Silicon** (7.5ms; CQ 24ms quá chậm → live = low-latency-RC, crisp = Session B). queueDepth: giữ **2–3** (latency) thay vì 5 của Sunshine, có spike.
- ADD — client-side cursor (impact cao nhất); 4-flag recipe + RequireHWEncoder + NV12 zero-copy; lossy-first→lossless-upgrade; CADisplayLink pacing; LTR+FEC thay forced-IDR; window-geometry channel; coordinate-mapping là rủi ro #1; giới hạn 2–4 VTCompressionSession đồng thời.

---

## 6. Open spikes → **phần lớn đã giải, xem [18](18-risk-resolutions.md)**

8 spike ở bản đầu đã được research ra cách giải + skeptic-verify ([18]): #2 threading, #3 coordinate, #7 reconnect, #8 rate-control = **SOLVED**; #5 cursor-strip, #4 decode, #6 concurrent-encoder = **BOUNDED** (spike có decision-rule). Còn lại **đo trên hardware** (Phase 4, đều kỳ vọng PASS):

1. **Echo-latency PATH 1 thật trên NetBird** ở 5ms & 20ms RTT → quyết định predictor có cần không. *(quan trọng nhất cho PATH 1; chưa giải vì cần đo)*
2. **SPIKE F** decode→display p99 < 1 frame (33ms@30fps) trên client thật.
3. **SPIKE G** N `VTCompressionSession` HW/chip @1080p/1440p → cận window đồng thời.
4. **SPIKE D** `showsCursor=false` sạch cursor per-window (window on-screen).

> **Rủi ro #1 cũ (CGEvent coordinate / input nền) đã hết:** quyết định **activate-then-control 1 cửa sổ/lần** ([18 A]) loại bỏ SkyLight private-API + Chromium-bg-fail + macOS 26 fragility.

---

## 7. Nguồn

Corpus đầy đủ (7 họ × survey+deepdive + synthesis, kèm URL source/patent/RFC verified): **[research/17-tui-gui-best-solution.json](research/17-tui-gui-best-solution.json)**.

Điểm tựa chính: Mosh `terminaloverlay.{h,cc}` + `transportsender`; Eternal Terminal `BackedWriter/BackedReader`; WezTerm `renderable.rs`; VVTerm + Geistty (libghostty external-IO thực chiến) + `wiedymi/daiimus ghostty` forks; Blink/SwiftTerm (iOS UIKit); Sunshine `video.cpp`/`sc_capture.m` + Moonlight `RtpVideoQueue`; Parsec patent US 9,798,436; Xpra auto-refresh; FFmpeg `videotoolboxenc.c`; WWDC22 s10155 (SCKit) + WWDC21 (VideoToolbox LTR).
