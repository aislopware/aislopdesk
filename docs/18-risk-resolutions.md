# 18 — Risk resolutions: cách giải từng rủi ro + spike plan

> **STATUS: CURRENT.** Mọi rủi ro/spike còn mở đã được research ra **cách giải cụ thể** (19 agents, ~1.62M tokens) rồi **skeptic đập gãy + verify ngược primary source**. Corpus: [research/18-risk-resolutions.json](research/18-risk-resolutions.json).
>
> **Kết luận: 0 blocker.** 9 rủi ro → **SOLVED** (code pattern verified) / **MEASURED** (đã đo số thật trên M1 Max — xem §0) / **BOUNDED** (spike còn lại, có decision-rule + fallback). 2 rủi ro **dissolve bằng quyết định scope** (A, I). PATH 1 **build-ready ngay**; PATH 2 code-ready, gần hết spike.

## 0. Phase 0 — de-risk gate (giải hết rủi ro TRƯỚC khi build production)

> **Nguyên tắc (sửa lỗi phương pháp):** KHÔNG park một ẩn số "có thể giết kiến trúc" ở phase sau — nếu Phase 4 mới vỡ thì công Phase 1–3 lãng phí. **Phase 0 chạy MỌI spike architecture-defining trước; chỉ build production khi pass.** Phase 0 rẻ (harness nhỏ, không phải dựng cả pipeline).

**Phần lớn Phase 0 đã chạy NGAY trên máy này** (Apple M1 Max · macOS 26.5 · arm64 — đúng host-class target, kèm macOS 26 từng là watch-item). Harness + số thô tái lập: [research/spikes/vtbench/](research/spikes/vtbench/RESULTS.md).

> **Đo trên 2 máy thật cùng NetBird:** HOST = M1 Max, CLIENT = M2 Pro (cả hai macOS 26.5). ⚠️ Encode HW **treo qua SSH** → chạy từ Terminal.app GUI.

| Spike | Trạng thái | Số đo | Gate |
|-------|-----------|-------|------|
| **Network RTT (NetBird P2P)** | ✅ **MEASURED** | **avg 11.1ms** (min 8.5/max 14.5), **0% loss**, **P2P trực tiếp qua internet** (NAT hole-punch, không same-LAN) | nền của mọi latency ✓ |
| **F** decode latency | ✅ **MEASURED — PASS (host+client)** | host M1 Max **p99 1.1ms**; **client M2 Pro p99 0.92ms** — synchronous HW, KHÔNG 2-frame-buffer | p99 < 1 frame ✓ |
| **G** concurrent encoders | ✅ **MEASURED (2 máy)** | 32 session/host; **~6 window 1080p@30fps / encode-engine** (M2 Pro 1-engine→~6 @184fps; M1 Max 2-engine→~8–10 @340fps). Research "2–4" SAI. Client chỉ decode → vô tư | đủ window ✓ |
| **E** live encoder | ✅ **MEASURED** | low-latency-RC **7.5ms** vs constant-quality **24ms** (chậm 3×) → **live PHẢI low-latency-RC** | encode < frame ✓ |
| **E** Session-B lossless | ✅ **MEASURED** | `Lossless` key **không support** (-12900) → dùng `Quality=1.0`+`AllowTemporalCompression=false` (all-intra) | — |
| macOS 26 multi-NALU | ✅ **MEASURED — downgraded** | **1 NALU/CMSampleBuffer** (cả IDR) trong config single-slice → không phải corruption risk | iterate NALU vẫn nên làm |
| **D** cursor strip | ✅ **MEASURED — PASS** | client M2 Pro: capture per-window 2 lần, `showsCursor=false` strip sạch (diff chỉ 120px = cursor, present ở true/absent ở false) | 0 pixel cursor ✓ |
| **C** libghostty threading | ✅ SOLVED (source) | main-thread contract (đọc VVTerm) — không cần hardware | — |
| **H** iOS reconnect | ✅ SOLVED (source) | ET BackedWriter/Reader pattern — không cần hardware | — |
| PATH 1 echo-latency | ✅ **MEASURED** | app-level TCP single-byte round-trip qua mesh: **p50 9.2ms · p99 17.8ms** (max 139ms 1 outlier). Feels-local; **xác nhận KHÔNG cần Mosh predictor** | echo < ~50ms ✓ |

→ **Phase 0 HOÀN TẤT — 0 ẩn số còn lại.** TẤT CẢ đo trên 2 máy thật (host M1 Max, client M2 Pro, macOS 26.5, P2P internet): network 11ms · echo PATH 1 9.2ms · decode 0.9–1.1ms · encode 7ms · concurrency ~6/engine · NALU=1 · **cursor-strip PASS**. Predictor không cần (xác nhận bằng số). **Không còn rủi ro architecture-defining nào treo. PATH 1 + PATH 2 đều an toàn để commit.**

## Bảng tổng

| Risk | Verdict | Cách giải (1 dòng) |
|------|---------|--------------------|
| **A** input vào cửa sổ nền | ✅ **Dissolved (scope)** | Bạn chốt **activate-then-control, 1 cửa sổ/lần, phải focus** → focus target → frontmost → `CGEventPost` universal. **Né SkyLight private API + né Chromium-bg-fail + né macOS 26 fragility.** |
| **B** coordinate mapping | ✅ SOLVED | `kCGWindowBounds`(top-left CG)→normalize→`CGEvent.postToPid`; fix multi-monitor bằng flip sang Cocoa space trước `NSScreen.intersection`; window-move = AX `kAXWindowMovedNotification` (fire ở END) + poll `CGWindowListCopyWindowInfo` khi đang drag |
| **C** libghostty threading | ✅ SOLVED | feed_data/refresh/draw **chỉ main thread**; TCP-rx bg thread → `await MainActor.run`; CVDisplayLink cb (bg) → `DispatchQueue.main.async` trước khi chạm view state |
| **D** cursor strip | 🔬 BOUNDED (low) | `showsCursor=false`+`showsMouseClicks=false` — confirmed sạch trong OBS/Ensemble + SDK không có cursor key; 1 harness-run (TCC) xác nhận |
| **E** rate-control vs quality | ✅ **MEASURED+SOLVED** | **2 session**: A live **low-latency-RC** (đo 7.5ms; constant-quality 24ms quá chậm) + bitrate cap 12Mbps · B on-demand `Quality=1.0`+`AllowTemporalCompression=false` (KHÔNG có `Lossless` key) |
| **F** decode latency | ✅ **MEASURED — PASS** | đo p99 **1.1ms** HW synchronous, KHÔNG 2-frame-buffer; render qua `CVMetalTextureCache`+`CAMetalLayer` (KHÔNG `AVSampleBufferDisplayLayer`) |
| **G** concurrent encoders | ✅ **MEASURED** | 32 session/host; ~**8–10 window 1080p@30fps** đồng thời (throughput ~340fps); gate `RequireHardwareAcceleratedVideoEncoder=true` |
| **H** iOS reconnect | ✅ SOLVED | Port ET `BackedWriter/BackedReader` (64MB cap, 4MB offline gate) over plain TCP, **KHÔNG CryptoHandler**; UIKit `didEnterBackground`+`beginBackgroundTask` |
| **I** PTY = RCE / auth | ✅ **Dissolved (scope)** | Bạn chốt **plain, không auth** (personal-use, trong mesh) → biên = NetBird/WireGuard membership + ACL. Accepted residual risk |

---

## PATH 1 risks (build-ready, không cần hardware)

### C — libghostty threading (SOLVED)
- `ghostty_surface_feed_data` / `_refresh` / `_draw` **bắt buộc gọi trên main thread** (xác nhận đọc source VVTerm). `@MainActor` của Swift **không** lan sang C symbol — phải tự đảm bảo call-site ở main.
- **TCP receive loop** chạy background thread → trước khi feed: `await MainActor.run { terminal.feedData(data) }`.
- **CVDisplayLink callback** fire trên bg thread → `DispatchQueue.main.async` trước khi chạm view state.
- `ghostty_surface_draw` acquire `draw_mutex` (serialize với CVDisplayLink `drawFrame(false)` của renderer) → không hard-crash nếu lệch thread, nhưng vẫn giữ contract main-thread.
- ⚠️ Bẫy: **actor-suspension escape** — sau `await` trong một `@MainActor` func, nếu hop sang executor khác thì mất isolation; giữ chuỗi feed→refresh→draw không bị suspend ở giữa.

### H — iOS reconnect byte-exact (SOLVED)
- Port **Eternal Terminal `BackedWriter`/`BackedReader`** over plain TCP: ring `MAX_BACKUP=64MB`, **offline gate 4MB** — `BUFFERED_ONLY`=tiếp tục buffer, `SKIPPED`=pause PTY drain (đừng để build dài lúc client offline làm tràn → mất output).
- ⚠️ **KHÔNG port `CryptoHandler`** của ET (libsodium secretbox + nonce). Ta plain over WireGuard → buffer lưu **raw bytes**. Ghi rõ kẻo người sau thêm nhầm lớp crypto reset-nonce.
- Wire sequence number dùng **int64/varint** (ET proto2 là int32 — truncation trên session siêu dài).
- Lifecycle: **UIKit `didEnterBackground`** (KHÔNG SwiftUI `scenePhase`) + `beginBackgroundTask` để pause PTY drain; reconnect tạo `NWConnection` mới sau `.failed` với pending-receive để phát hiện socket chết. Handshake: **server quyết định `RETURNING_CLIENT`** (verified `Connection.cpp:96-141`).

### I — security (Dissolved bằng quyết định: plain, no-auth)
- Quyết định của bạn: **không auth tầng app**, plain để giảm latency, personal-use trong NetBird/Tailscale. Biên giới = mesh membership + ACL.
- Research *có* tìm ra giải pháp nếu sau này cần (Ed25519 per-client allowlist + one-time HMAC pairing, socket bind chỉ vào NetBird IP qua `NWParameters.requiredLocalEndpoint`) — **để dành**, không làm v1. (Nếu làm: `Curve25519.Signing.PrivateKey()`, `isValidSignature` trả Bool **không** `try`, Ed25519 **không** vào Secure Enclave — SE chỉ P-256.)
- **Accepted residual risk:** một PTY nhận byte = RCE bounded bởi mesh; peer mesh bị chiếm → host lộ. OK cho personal-use.

---

## PATH 2 risks (Phase 4 — code-ready, gated 3 spike)

### A — input injection (Dissolved bằng quyết định: activate-then-control)
- Quyết định của bạn: **điều khiển 1 cửa sổ tại một thời điểm, phải focus**. → raise + focus cửa sổ target (public API: `NSRunningApplication(...).activate` + AX `kAXRaiseAction` / set `kAXFocusedWindow`), nó thành **frontmost**, rồi `CGEventPost(kCGHIDEventTap)` hoặc `postToPid`. Tag `eventSourceUserData` filter self-inject.
- **Vì sao đây là lựa chọn tốt hơn cả cách "inject vào cửa sổ nền":** research tìm ra cách inject nền bằng **SkyLight private API** (cua-driver/yabai `SLPSPostEventRecordTo`+`SLEventPostToPid`) — NHƯNG nó (1) dùng **private symbol** (fragile, dlopen/dlsym), (2) **fail với Chromium/Electron trên macOS 14** (keyboard bị drop nền), (3) **chưa verify trên macOS 26 Tahoe**. Activate-then-control dùng **public API**, chạy **universal cho mọi loại app** (kể cả Metal/OpenGL viewport mà cách nền không làm được), và **né hết 3 vấn đề trên**. → **SPIKE 1 (nặng nhất) bị xoá.**

### B — coordinate mapping (SOLVED)
Pipeline: client-pixel → normalize → host-window-point → `CGEvent.postToPid`. Ba fix bắt buộc:
1. **TCC**: `postToPid` cần permission **"Post Event"** (không chỉ Accessibility) — kiểm tra riêng.
2. **Multi-monitor backingScale flip** (bug trên màn phụ): `kCGWindowBounds` là CG top-left, `NSScreen.frame` là Cocoa bottom-left → **flip `cocoaY = primaryHeight − y − h`** trước `NSScreen.frame.intersection` để lấy đúng `backingScaleFactor`.
3. **Window-move sync**: AX `kAXWindowMovedNotification` chỉ fire **khi kết thúc** move → trong lúc drag, **poll `CGWindowListCopyWindowInfo`** per-frame để client `NSWindow` không lệch. (`SCContentFilter(desktopIndependentWindow:)` capture origin (0,0) → toạ độ trong-window là chính.)

### D — cursor strip (MEASURED — PASS, client M2 Pro)
- 📏 **Đo:** harness `cursor-strip.swift` (`SCScreenshotManager` + `SCContentFilter(desktopIndependentWindow:)`) chụp 1 cửa sổ app thật 2 lần, con trỏ warp vào giữa: `showsCursor=true` vs `false`. **diff = 120px (0.006%)** = đúng cursor (present ở true, absent ở false) → **`showsCursor=false` strip sạch cursor khỏi per-window capture.**
- `config.showsCursor = false` (+ `showsMouseClicks = false`). Khớp evidence OBS/Ensemble + SDK `SCStreamFrameInfo` không có cursor key.
- ⚠️ Gotcha đã gặp khi đo: (1) CLI phải init `NSApplication.shared`+`setActivationPolicy(.accessory)` kẻo assert `CGS_REQUIRE_INIT`; (2) lọc `windowLayer==0`+`owningApplication` kẻo trúng cửa sổ "Backstop" (wallpaper); (3) cần TCC Screen-Recording → chạy GUI, không SSH.
- ⚠️ **Off-screen starvation** (vẫn đúng): `showsCursor=false` + window off-screen → SCK ngừng giao frame (chỉ khi mouse-move). Use-case chính (window đang focus) → không sao.

### E — rate-control vs quality (MEASURED + SOLVED — **cập nhật [17 §3.4]**)
Giải xung đột "low-latency-RC cần bitrate vs constant-quality" bằng **2 VTCompressionSession**. **Đo trên M1 Max chốt rõ live frame phải dùng cái nào:**
- **Session A (live stream) = low-latency-RC** (KHÔNG constant-quality): `EnableLowLatencyRateControl=true` (Spec key) + `AverageBitRate` (SInt32) + `DataRateLimits=[12_000_000/8, 1.0]` (= 1.5MB/1s = **12Mbps hard cap**; **/8 không phải /4**) + `SpatialAdaptiveQPLevel=Disable` (SDK bắt buộc khi low-latency, macOS 15+, wrap availability). **Omit `ProfileLevel`**.
  - 📏 **Đo:** low-latency-RC encode **p50 7.5ms**; constant-quality 0.65 encode **p50 24ms** (chậm 3×, sát budget 33ms). → live frame **bắt buộc** low-latency-RC. (Sửa framing cũ "encode Quality 0.65 gửi ngay".)
  - 📏 Querying `UsingHardwareAcceleratedVideoEncoder` khi low-latency = **-12900** (đừng query trong mode này — confirmed).
- **Session B (on-demand crisp):** `Quality=1.0` + `AllowTemporalCompression=false` (all-intra) — encode dirty-rect union khi window idle.
  - 📏 **Đo:** `Quality=1.0` + `AllowTemporalCompression=false` đều accepted; **`Lossless` property key KHÔNG support (-12900)** → không có lossless HEVC key, dùng `Quality=1.0` all-intra (lưu: 4:2:0 `Quality=1.0` vẫn subsample chroma — đây là crisp tối đa, không phải lossless tuyệt đối).
- ⚠️ Bỏ claim "Sidecar dùng ..." (không có primary source).

### F — decode latency (MEASURED — PASS)
- 📏 **Đo trên M1 Max / macOS 26.5:** `VTDecompressionSession` `decodeFlags=[]` (synchronous), 1080p HEVC, HW: **p50 0.73ms, p99 1.12ms, max 3.15ms**. → **single-frame, KHÔNG 2-frame-buffer** (ẩn số đáng sợ nhất → giải). ≪ 33ms budget.
- Decode session: feed `CVPixelBuffer` → Metal qua `CVMetalTextureCacheCreateTextureFromImage` + `CAMetalLayer` — **KHÔNG `AVSampleBufferDisplayLayer`** (thêm ≥1 frame buffering, Moonlight #1885).
- Version-gate `RequireHardwareAcceleratedVideoDecoder` sau `@available(iOS 17)`; iOS ≤16 HW-decode HEVC là default trên A-series. iOS background-suspend hang → async invalidate session.
- **Còn lại (client iOS/iPadOS):** đo lại p99 trên A-series client thật + cộng `nextDrawable`+vsync cho full motion-to-photon. Decode component đã chứng minh ~1ms → motion-to-photon do display-pacing chi phối (đã hiểu rõ, [17 §3.7]). PASS rule giữ p99 < 1 frame.

### G — concurrent encoders (MEASURED 2 máy — non-issue)
- 📏 **Đo:** session-creation ceiling = **32** cả 2 máy (thứ 33 fail -12903). Sustained throughput (encode back-to-back, low-latency-RC, 1080p):
  - **M1 Max (2 engine): ~340fps → ~8–10 window @30fps.**
  - **M2 Pro (1 engine): ~184fps → ~6 window @30fps** (K=6=31fps/stream edge; K=8 vỡ).
- 📏 **Rule đo được: ~6 live 1080p30 window / video-encode-engine** (1-engine base/Pro→~6, Max→~10, Ultra→~20). Throughput ∝ engine-count.
- ⚠️ **Research "2–4 concurrent" SAI** — nhầm *engine throughput* với *session count*. Với coding tool (1–3 window) → **non-issue mọi chip**. Máy ở vai trò **client chỉ decode** (~0.9ms) → encode throughput chỉ áp khi làm **host**.
- Vẫn gate mỗi encoder bằng `RequireHardwareAcceleratedVideoEncoder=true` (fail-fast nếu quá tải). Query `UsingHardwareAcceleratedVideoEncoder` **đúng 1 lần** lúc tạo (poll = crash `mediaserverd`; và -12900 nếu low-latency). Recreate session khi resize. Warm-up + retry 50–100ms cho race **-12905** (XPC).

---

## Non-blocking watch items

- ✅ **macOS 26 multi-NALU — đã ĐO, downgraded:** trên macOS 26.5 M1 Max, HEVC emit **1 NALU/CMSampleBuffer** (cả IDR; param set ở format desc). Không phải corruption risk trong config single-slice. **Vẫn iterate length-prefixed NALU** (AVCC chuẩn, cost ~0) cho an toàn — nhưng không còn là cảnh báo.
- macOS 26 Tahoe per-window background-input chưa verify — **moot với ta** (đã dùng activate-then-control, không đi đường đó).
- macOS 14 + Chromium/Electron backgrounded keyboard bị drop — **moot với ta** (focus trước khi gõ).

---

## Spike plan — ĐÃ CHẠY HẾT (xem §0)

> **Tất cả spike Phase-0 đã đo xong** trên 2 máy thật (host M1 Max + client M2 Pro, macOS 26.5, P2P internet): network RTT, echo PATH 1, decode (host+client), encode, concurrency, NALU, **cursor-strip**. Harness tái lập: [research/spikes/vtbench/](research/spikes/vtbench/RESULTS.md).

Còn lại chỉ là **spike triển khai** (không phải de-risk kiến trúc), làm trong lúc build:
- libghostty: alt-screen e2e, binary-size XCFramework iOS, shell-integration OSC.
- (iOS client) đo lại decode+vsync trên A-series iPhone/iPad khi có thiết bị (decode đã PASS trên M-series; chỉ xác nhận A-series).
- echo app-level đã đo trên macOS↔macOS; đo lại trên iOS client khi có app.

> **PATH 1 + PATH 2: 0 spike gating còn lại → an toàn build.**

---

## Nguồn
Corpus đầy đủ (9 risk × solve+verify + synthesis, primary-source verified): **[research/18-risk-resolutions.json](research/18-risk-resolutions.json)**. Điểm tựa: trycua/cua-driver + yabai (SkyLight, *để dành*); Eternal Terminal `BackedWriter/BackedReader/Connection`; VVTerm/Geistty (libghostty threading); OBS `mac-sck-video-capture.m`; Moonlight (decode pacing); FFmpeg `videotoolboxenc.c`; iOS/macOS 26.5 SDK headers (VideoToolbox/ScreenCaptureKit); Apple forum threads (cursor starvation 720228, socket reclaim TN2277).
