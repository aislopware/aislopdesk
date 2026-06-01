# 11 — Absolute Latency (nghiên cứu đa tầng sâu nhất)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Floor analysis này CHỈ áp dụng cho GUI video-path** và phần lớn là **over-engineering cho profile coding** ([12](12-coding-profile.md)): motion-to-photon <16ms, 120fps/ProMotion, beam-racing → **DROP**. Terminal path latency = network RTT (~1–5ms LAN), không vsync. **Giữ lại các correction API** (queueDepth default 8, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, tắt AWDL, idle-skip/dirtyRects) — vẫn đúng cho GUI path. **Lưu ý NetBird ([13](13-netbird-transport.md)):** `serviceClass`/DSCP và `requiredInterfaceType=.wiredEthernet` trong doc này **KHÔNG áp dụng** (chạy trên WireGuard tunnel — DSCP bị zero, utun là `.other`).

> Tổng hợp từ workflow **73-agent** (15 dimension + 14 gap + adversarial verify, ~6M tokens). Mục tiêu: **floor latency tuyệt đối** glass-to-glass cho stack Apple/LAN/per-window. Raw corpus đầy đủ: [research/latency-research-corpus.json](research/latency-research-corpus.json).

## Tóm tắt floor (cần Phase-0 validate)

| Kịch bản | Floor lý thuyết | Realistic |
|---|---:|---:|
| 60fps, wired GigE | ~14 ms | ~22–26 ms |
| 120fps, wired (ProMotion 2 đầu) | ~10 ms | ~14–16 ms |
| 60fps, Wi-Fi 6/6E (light load) | — | +2–5 ms so với wired |
| 120fps, Wi-Fi 6E (6GHz) | — | ~17–26 ms |

Hai stage **dominant** là **capture (chờ compositor vsync ở host)** và **render + scanout (vsync ở client)** — network gần như biến mất trên wired GigE (one-way <0.1 ms). Mọi con số là **dẫn xuất**, chưa đo trên stack native Swift này → xem checklist Phase-0 ở cuối.

> ⚠️ **CORRECTIONS quan trọng cho thiết kế cũ** (chi tiết ở §"Verified API claims"):
> - `minimumFrameInterval`: **macOS 15+ default âm thầm = 1/60** (cap 60fps kể cả ProMotion) → **phải set tường minh**; dùng `(1/fps)×0.9` (OBS PR#11896), **KHÔNG** `kCMTimeZero` (refuted).
> - `queueDepth`: default thực là **8** (không phải 3); **2 hợp lệ** cho latency thấp.
> - HEVC: `AllowOpenGOP` mặc định **true** → **phải set `false`**; `MaxFrameDelayCount=0` ép one-in-one-out.
> - Capture 10-bit: `'x420'` (`420YpCbCr10BiPlanarVideoRange`) **KHÔNG** được `SCStreamConfiguration` hỗ trợ; HDR cần **macOS 15 preset** hoặc `'xf44'` (4:4:4).
> - **AWDL / peer-to-peer (`includePeerToPeer`) GÂY HẠI** cho video (spike 40–336 ms) → tắt; dùng AP ch44/149 hoặc băng 6GHz.
> - **VRR / adaptive-sync cần fullscreen** → app single-window (windowed) KHÔNG hưởng lợi.
> - **Slice / sub-frame pipelining KHÔNG khả dụng** qua public VideoToolbox API (output frame-granular) → bỏ khỏi thiết kế.

## Mục lục
- [Latency budget & theoretical floor](#latency-budget--theoretical-floor)
- [Per-stage absolute-minimum configuration](#per-stage-absolute-minimum-configuration)
- [Ranked techniques by latency impact](#ranked-techniques-by-latency-impact)
- [Verified API claims, corrections & Phase-0 validation list](#verified-api-claims-corrections--phase-0-validation-list)

---

## Latency budget & theoretical floor

Phần này phân rã ngân sách glass-to-glass (G2G) thành từng stage rời rạc cho stack `ScreenCaptureKit -> VideoToolbox HEVC -> Network.framework UDP/QUIC -> VideoToolbox decode -> Metal/CAMetalLayer`. Mục tiêu là chỉ ra chính xác từng millisecond nằm ở đâu, stage nào chiếm ưu thế (dominant), và floor thực tế tuyệt đối có thể đạt trên Apple Silicon + LAN.

Một số nguyên tắc nền tảng cần nắm trước khi đọc bảng:

- **Vsync là sàn không thể nén ở hai đầu.** Capture phụ thuộc một chu kỳ WindowServer compositor vsync (8.33 ms @120Hz, 16.67 ms @60Hz); display phụ thuộc một chu kỳ scanout vsync ở client (trung bình nửa frame, worst-case một frame). Đây là hai khoản chi không thể loại bỏ bằng API, chỉ có thể giảm bằng cách nâng refresh rate.
- **Trên wired LAN, network gần như biến mất khỏi ngân sách.** GigE serialization của một frame 1500-byte là ~12 µs; one-way LAN total < 0.1 ms. Network KHÔNG phải là dominant stage trên wired — pipeline bị chi phối bởi display timing ở cả hai đầu.
- **Số overlay của Moonlight luôn báo THẤP hơn G2G thật.** Christoff Visser / Greendayle đo được Virtual Desktop báo thiếu ~40 ms so với motion-to-photon thực; overlay bắt được network+decode nhưng bỏ sót capture compositor delay, compositor buffering, và display scanout. Mọi con số "tự báo cáo" trong corpus đều phải hiểu là cận dưới.

---

### Bảng quy ước & hằng số nền

| Hằng số | Giá trị | Nguồn |
|---|---|---|
| Vsync period @60Hz | 16.67 ms | Định nghĩa (1/60) |
| Vsync period @120Hz | 8.33 ms | Định nghĩa (1/120) |
| Scanout contribution trung bình (nửa frame) | 8.3 ms @60Hz / 4.2 ms @120Hz | blurbusters.com (display-compositor-macos) |
| GigE one-way LAN | < 0.1 ms | basicitnetworking / Cloudflare (~60 µs trên 10GbE localhost) |
| Wi-Fi 6/6E one-way (light load) | 0.5–2.5 ms | routerhaus / Cudy (5GHz 5–15ms RTT; 6GHz 3–8ms RTT) |
| mach tick Apple Silicon | 41.67 ns (numer=125, denom=3) | Eclectic Light, xác nhận M1; **claim_to_verify cho M2/M3/M4** |

---

### Budget @60fps — WIRED GigE (display 60Hz cả hai đầu)

| Stage | Floor | Realistic | Dominant? | Ghi chú & nguồn |
|---|---:|---:|:---:|---|
| **Capture (SCK compositor vsync)** | 0 | ~16.67 ms | ◆ DOMINANT | Một chu kỳ WindowServer compositor; không nén được. CPU cost chỉ ~1.9% một core (WWDC22 10156). Đặt `minimumFrameInterval`, `queueDepth=3`, skip idle frames để tránh backlog. |
| **Encode (VideoToolbox HEVC HW)** | ~3.3 ms | 15–18 ms | ◆ có thể dominant | HEVC ~18 ms/frame @1080p60 trên M4 (Lumen README, self-reported); H.264 ~15 ms. Ceiling lý thuyết ~3.3 ms từ throughput ~300fps @1080p — **nhưng đây là throughput, KHÔNG phải single-frame latency** (open question, chưa có số đo chính thức từ Apple). Vẫn nằm trong budget 16.67 ms. |
| **Transmit (UDP/QUIC, wired)** | < 0.1 ms | < 0.5 ms | ✗ | Serialization ~12 µs/1500B + NIC + propagation. QUIC-TLS thêm AES-128-GCM ~6.5 µs/frame trên M1 (negligible). Plain UDP ~0 crypto. |
| **Decode (VideoToolbox HEVC HW)** | ~1 ms | 1–3 ms | ✗ | M2 Mac 2–3 ms, drop tới 1.2 ms khi renderer không phải bottleneck (Moonlight #1249). M2 iPad ~1 ms (#1087, "felt" — chưa đo bằng Instruments). `flags=0` sync decode, không set `EnableTemporalProcessing`. |
| **Render + vsync (Metal direct)** | 4.2 ms | 8.3–16.7 ms | ◆ DOMINANT | Scanout trung bình 8.3 ms, worst-case 16.67 ms @60Hz. Metal direct path (CVMetalTextureCache -> CAMetalLayer), KHÔNG dùng AVSampleBufferDisplayLayer (thêm ≥1 frame buffering, Moonlight #1885). `maximumDrawableCount=2` (hợp lệ trên iOS/iPadOS — refuted claim "không khuyến nghị"), `displaySyncEnabled` + `CAMetalDisplayLink preferredFrameLatency=1`. |
| **TỔNG G2G video** | **~13 ms** | **~22–36 ms** | | Floor = 16.67 (capture) + 3.3 (encode ceiling) + 0.1 (net) + 1 (decode) + nhưng vì capture+render hai vsync chiếm phần lớn, floor thực tế ≈ **14 ms**; realistic ≈ **22 ms** |

Realistic 22 ms khớp với corpus realworld-floor: "Theoretical glass-to-glass floor at 60fps wired Apple Silicon: ~14–26 ms (capture 1ms + encode 2–4ms + network <0.1ms + decode 1–3ms + display 8.3–16.7ms)".

> **Lưu ý quan trọng về capture stage:** Con số 16.67 ms cho capture giả định trường hợp xấu (pixel đổi ngay sau khi compositor vừa lấy frame). Trung bình là nửa vsync. Floor lý thuyết corpus dùng "1 ms capture" thực ra là *callback overhead* của SCK sau khi compositor đã composite — KHÔNG bao gồm thời gian chờ compositor vsync. Đây là điểm gây nhầm lẫn lớn nhất: vsync-to-callback latency của SCK trên Apple Silicon **chưa từng được Apple công bố** (open question quan trọng nhất của capture-floor dimension).

---

### Budget @120fps — WIRED GigE (display 120Hz/ProMotion cả hai đầu)

| Stage | Floor | Realistic | Dominant? | Ghi chú & nguồn |
|---|---:|---:|:---:|---|
| **Capture (SCK compositor vsync)** | 0 | ~8.33 ms | ◆ DOMINANT | Một chu kỳ @120Hz. **PHẢI set `minimumFrameInterval` tường minh** — macOS 15+ default đã âm thầm đổi thành 1/60, cap capture ở 60fps ngay cả trên ProMotion (confirmed: macOS 14.5 SDK = default 0, macOS 15.5 SDK = default 1/60). OBS PR#11896 dùng `(1/target_fps × 0.9)`, KHÔNG dùng `kCMTimeZero` (claim "kCMTimeZero" đã bị refuted — header comment đó không tồn tại). |
| **Encode (VideoToolbox HEVC HW)** | ~3.3 ms | 8–18 ms | ◆ DOMINANT (tight) | Budget chỉ còn 8.33 ms/frame. HEVC ~18 ms (Lumen M4) **vượt budget 120fps** → cần verify encode thực sự < 8.33 ms hoặc chấp nhận encode overlap nhiều frame. Đây là ràng buộc chặt nhất ở 120fps. |
| **Transmit** | < 0.1 ms | < 0.5 ms | ✗ | Như trên. |
| **Decode** | ~1 ms | 1–3 ms | ✗ | 2.37–2.69 ms trung bình M4 Pro với Metal renderer (Moonlight #1696). |
| **Render + vsync (Metal direct)** | 4.2 ms (worst 8.33) | 4.2–8.3 ms | ◆ DOMINANT | Scanout nửa frame = 4.2 ms @120Hz. `CAMetalDisplayLink preferredFrameLatency=1` (chỉ 1.0 hoặc 2.0 hợp lệ — xác nhận từ SDK doc). Beam-racing: render frame mới nhất ngay trước `targetTimestamp`. |
| **TỔNG G2G video** | **~10 ms** | **~14–16 ms** | | Floor corpus: "~10–16 ms (capture 1ms + encode 2–4ms + network <0.1ms + decode 1–3ms + display 4.2–8.3ms)" |

---

### Budget @60fps — Wi-Fi 6/6E (light load)

| Stage | Realistic (Wi-Fi) | Δ so với wired | Ghi chú |
|---|---:|---:|---|
| Capture | ~16.67 ms | 0 | Không đổi (host-side) |
| Encode | 15–18 ms | 0 | Không đổi |
| **Transmit** | **2–5 ms** | **+2–5 ms** | Wi-Fi 5GHz 5–15ms RTT → ~2.5–7.5ms one-way; 6GHz 3–8ms RTT → ~1.5–4ms one-way, jitter giảm ~80% (Cudy). **Bắt buộc `serviceClass=.interactiveVideo`** (→ AC_VI), bật WMM trên AP, KHÔNG bật `includePeerToPeer` (AWDL spike 40–336 ms). |
| Decode | 1–3 ms | 0 | Không đổi (client-side) |
| Render+vsync | 8.3–16.7 ms | 0 | Không đổi |
| **TỔNG G2G video** | **~24–41 ms** | **+2–5 ms** | Wi-Fi thêm ~2–5 ms trong điều kiện lý tưởng |

> **Cảnh báo AWDL (latency bomb).** AWDL chạy ngầm trên mọi máy Apple, hop kênh ~mỗi 10–12s gây spike 50–200 ms (networkweather; Visser/RIPE91 đo 20ms ±25ms variance, RTT 3–90ms). **Mitigation bắt buộc:** cấu hình AP dùng AWDL social channel 5GHz ch44 hoặc ch149 (confirmed qua reverse-engineering OWL/Seemoo, Apple chưa xác nhận chính thức), hoặc dùng băng 6GHz. Nếu không, Wi-Fi budget có thể vọt lên +50–200 ms theo chu kỳ.

---

### Budget @120fps — Wi-Fi 6E (light load, 6GHz)

| Stage | Realistic | Ghi chú |
|---|---:|---|
| Capture | ~8.33 ms | Cần `minimumFrameInterval` tường minh |
| Encode | 8–18 ms | Ràng buộc chặt nhất ở 120fps |
| Transmit | 1.5–4 ms | 6GHz ưu việt hơn 5GHz (không AWDL contention, kênh sạch) |
| Decode | 1–3 ms | |
| Render+vsync | 4.2–8.3 ms | |
| **TỔNG G2G video** | **~17–26 ms** | 6GHz là lựa chọn Wi-Fi tốt nhất cho 120fps |

---

### Input-to-photon (vòng tròn đầy đủ điều khiển từ xa)

Đây là chuỗi 6 stage khác với G2G video một chiều: client capture input → gửi → host inject → host display đổi → quay về client như video. Quan trọng nhất: **cursor cục bộ tách khỏi vòng video**.

| Stage | macOS host cursor | iOS touch client | Ghi chú & nguồn |
|---|---:|---:|---|
| **1. Client input capture** | 1–3 ms (USB HID 1ms @1000Hz; passive CGEventTap +0.1–0.3ms) | 8–17 ms @120Hz (touch 240Hz HW, UIKit coalesce tới frame boundary) | iOS 120Hz touch-to-UIKit **chưa có số đo chính thức**; ước "8–17ms" bằng cách chia đôi 60Hz là *methodologically unsound* (DXOMARK đo iPhone 15 Pro Max ~67ms end-to-end, KHÔNG giảm một nửa so với 60Hz). Dùng `coalescedTouches`/`predictedTouches`. |
| **2. Network send** | 0.05–0.2 ms wired | như trên | Gửi button event ngay, batch motion ~1ms cadence. |
| **3. Host inject (CGEventPostToPid)** | 0.2–2 ms | — | KHÔNG phải "Mach IPC round-trip" như giả định ban đầu (refuted) — là CoreGraphics/WindowServer multi-hop injection, **chưa có benchmark Apple Silicon**. So sánh: XPC/UDS small-msg ~11µs trên Intel → đường full nhiều hop hơn. |
| **4. Activate-then-control** | 0.1–0.3 ms (2 Mach msg, một lần/session) | — | `SLPSPostEventRecordTo` flip active state không raise window (tránh Space-switch 100–300ms). **Lưu ý:** trên macOS 14 hàm này có thể SIGABRT do `CGSEncodeEventRecord` serialize sai buffer fill 0xFF (paneru #123) — cần guard theo OS version. Tahoe 26: CGEventPost từ unsigned daemon bị chặn → cần code-sign hoặc DriverKit virtual HID. |
| **5. Return video (host display→client)** | 3–15 ms | 3–15 ms | = toàn bộ pipeline encode→net→decode ở trên (không tính lại scanout hai lần). |
| **6. Client display** | 8–13 ms @120Hz | 8–17 ms @120/60Hz | Như render+vsync ở trên. |

**Kết quả input-to-photon:**
- **KHÔNG có cursor cục bộ:** ~14–36 ms G2G (wired, 120Hz, không tính cursor) — khớp corpus.
- **CÓ cursor overlay cục bộ:** cursor xuất hiện trong **~2–5 ms** (input capture + draw, từ kênh input chứ KHÔNG qua video roundtrip); xác nhận window update (frame video thể hiện kết quả) trong ~15–25 ms. **Đây là tối ưu giá trị cao nhất cho perceived responsiveness** — RDP/PCoIP/NoMachine đều làm vậy. Đặt `SCStreamConfiguration.showsCursor = false`, vẽ cursor client-side từ stream input.

Trên LAN RTT ~1ms < một frame period, **KHÔNG cần motion prediction/extrapolation** (chỉ dành cho WAN RTT > 20ms).

---

### Floor thực tế tuyệt đối & đối chiếu hệ thống thực

**Floor lý thuyết Apple Silicon + wired LAN (Metal direct render, HEVC HW, low-latency mode):**

| Cấu hình | Floor G2G video | Realistic G2G video |
|---|---:|---:|
| **120fps wired, display 120Hz** | **~10 ms** | **~14–16 ms** |
| **60fps wired, display 60Hz** | **~14 ms** | **~22–26 ms** |
| **120fps Wi-Fi 6E** | ~12 ms | ~17–26 ms |
| **60fps Wi-Fi 6** | ~16 ms | ~24–41 ms |

**Đâu là nơi mỗi millisecond đi:** Ở cả hai cấu hình wired, **hai stage vsync (capture compositor + display scanout) chiếm phần lớn floor** — khoảng 12.5 ms (@60Hz: 8.3+4.2 nếu tính trung bình, tới 33ms nếu cả hai worst-case) so với chỉ ~4 ms cho encode+decode kết hợp và < 0.5 ms cho network. **Encode là stage có thể dominant duy nhất mà ta kiểm soát được bằng API** (low-latency RC, no B-frames, MaxFrameDelayCount=0). Network gần như miễn phí trên wired. Kết luận: **muốn nén floor, phải nâng refresh rate (60→120Hz) chứ không phải tối ưu network** — chuyển 60→120Hz tiết kiệm ~8ms ở capture + ~4ms ở scanout = ~12ms.

**Đối chiếu hệ thống thực (số đo có nguồn):**

| Hệ thống | Số công bố | Phạm vi đo | Đánh giá độ tin cậy |
|---|---:|---|---|
| **Parsec** | 4–8 ms @240fps wired LAN | encode+transmit+decode **display-to-display**, KHÔNG gồm input injection, đo bằng camera 1000fps | Là demo stress-test cực hạn (Parsec khuyến nghị thực tế 60fps); KHÔNG phải full G2G. ~7ms overhead @60fps so với local. |
| **Parsec encode** | NVENC H.264 median 5.8 ms | fleet median **mọi GPU Nvidia** (không riêng Pascal), 2018, KHÔNG phải benchmark có kiểm soát | Apple Silicon Media Engine encode latency **chưa có benchmark chính thức nào** |
| **Moonlight + Sunshine** | ~10–20 ms total @60fps wired | community measured, overlay | Overlay báo thiếu — G2G thật cao hơn |
| **Moonlight decode (Apple Silicon)** | M2 iPad ~1ms, M2 Mac 2–3ms | "felt"/overlay, không phải Instruments | M2 Mac 4–6ms qua FFmpeg+VT+AVSampleBufferDisplayLayer; xuống ~2.7ms với Metal |
| **Lumen (Sunshine fork, M4)** | encode H.264 ~15ms / HEVC ~18ms @1080p60; 1ms encode-to-network | README self-reported, methodology không nêu | Con số encode self-reported, chưa độc lập kiểm chứng |
| **ALVR (VR)** | target < 50ms motion-to-photon; thực tế 70–140ms wireless | đo Greendayle | Domain VR có thêm compositor+tracking; không trực tiếp so sánh được |
| **NeSt-VR (paper)** | VF-RTT 4–5 ms Wi-Fi | đo, peer-reviewed | Chỉ stage transmission round-trip |

---

### Cảnh báo & điểm bất định cần ghi nhớ

1. **macOS 26 Tahoe decode regression.** Moonlight #1696 báo decode latency vọt lên ~80ms trên Intel/macOS 26, ~20ms trên M4 với Metal renderer; tắt Metal renderer → ~2.7ms. Nguyên nhân nghi là CAMetalDisplayLink "presentation wait timed out" chứ không phải HW decode. **Phải test trên macOS 26 target trước khi tin floor ~14ms.**

2. **Encode single-frame latency là open question lớn nhất chưa giải.** Con số ~3.3ms ceiling là từ *throughput* (~300fps @1080p HEVC), KHÔNG phải latency một frame. Apple chưa công bố. Ở 120fps (budget 8.33ms) đây là ràng buộc có thể vỡ — cần đo thực tế trên target hardware bằng `CACurrentMediaTime()` trước `VTCompressionSessionEncodeFrame` và trong output handler.

3. **HEVC low-latency rate control trên Apple Silicon là empirical, KHÔNG documented.** `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` được Apple document chỉ cho H.264 (WWDC21); HEVC support chỉ được xác nhận qua FFmpeg patch (`TARGET_CPU_ARM64`), không có bảo đảm chính thức. Query `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` trả `kVTPropertyNotSupportedErr` (-12900) trong low-latency mode — đây là API incompleteness, KHÔNG phải bằng chứng software fallback. Error gating thật cho thiếu HW là -12902.

4. **SCK capture vsync-to-callback latency chưa từng được đo công bố.** Toàn bộ stage capture (8.33/16.67 ms) là suy luận từ kiến trúc compositor, không phải số Apple. `SCStreamFrameInfoDisplayTime` cùng clock domain với `CACurrentMediaTime()` (cả hai gốc `mach_absolute_time` — confirmed), nhưng có forum report về negative latency (May 2025) có thể là bug stamping riêng, cần `mach_timebase_info` convert đúng.

5. **AVSampleBufferDisplayLayer extra-frame buffering là quan sát macOS (GPU rời).** Δ "1+ frame" từ Moonlight #1885 đo trên Radeon Pro 580; **chưa có benchmark iOS** so sánh Metal vs AVSampleBufferDisplayLayer. Trên iOS Moonlight chỉ dùng AVSampleBufferDisplayLayer (không có Metal path để A/B). Dù vậy, khuyến nghị Metal direct vẫn đứng vững vì tránh được compositor queue.

6. **`maximumDrawableCount=2` HỢP LỆ trên iOS/iPadOS** (claim "Apple không khuyến nghị" đã bị refuted — chỉ có cảnh báo `nextDrawable` trả nil cao hơn, áp dụng mọi nền tảng). Đây là lựa chọn đúng để tối thiểu G2G; cần xử lý nil drawable + drop frame.

---

## Per-stage absolute-minimum configuration

Phần này liệt kê cấu hình **chính xác đến từng symbol** cho mỗi stage của pipeline glass-to-glass. Mỗi setting kèm rationale một dòng. Spelling của tất cả symbol VideoToolbox và ScreenCaptureKit dưới đây đã được verify trực tiếp từ `MacOSX.sdk` (Xcode đang cài: SCK `SCStream.h`, VT `VTCompressionProperties.h`). Symbol nào **chưa verify được** từ header sẽ được đánh dấu rõ ràng `[UNVERIFIED]`.

> Quy ước: `[VERIFIED-SDK]` = đã xác nhận từ header trên máy; `[VERIFIED-CORPUS]` = corpus xác nhận nhưng không tự kiểm header lần này; `[UNVERIFIED]` = chỉ có nguồn gián tiếp/cộng đồng, cần test runtime; `[PRIVATE]` = symbol private/undocumented, dùng có rủi ro.

---

### 1. Capture — ScreenCaptureKit

Dùng `SCStream` với `SCContentFilter(desktopIndependentWindow:)`. Đây là đường capture single-window public duy nhất khả dụng trên macOS 14+ (CGDisplayStream / CGWindowListCreateImage đã obsoleted ở SDK macOS 15) [capture-floor].

| Setting | Giá trị | Rationale |
|---|---|---|
| `SCContentFilter(desktopIndependentWindow:)` `[VERIFIED-CORPUS]` | window mục tiêu | Filter chuyên cho single-window, display-independent, không composite các window khác → ít công việc trong WindowServer capture path. |
| `config.minimumFrameInterval` `[VERIFIED-SDK]` (`SCStream.h:222`, type `CMTime`) | `CMTimeMake(1, targetFPS)` (vd `CMTimeMake(1, 120)`); **không** dùng float xấp xỉ | Trên macOS 15+ default **đã đổi thành 1/60** kể cả ProMotion → cap silent ở 60fps. **Đã verify (corpus, confirmed):** đặt giá trị này tường minh là bắt buộc. **Lưu ý correction quan trọng:** claim ban đầu rằng `kCMTimeZero` enable native refresh rate đã bị **REFUTED** — OBS PR #11896 thực tế dùng `target_frame_period × 0.9` (concrete CMTime), **không** dùng `kCMTimeZero`, và không có SDK header nào nói `kCMTimeZero` → native refresh. Khuyến nghị: đặt đúng `1/targetFPS`, hoặc `1/(targetFPS × 1.1)` (interval ngắn hơn ~10%) theo OBS empirical fix nếu thấy drop frame. `kCMTimeZero` là untested cho mục đích này. |
| `config.queueDepth` `[VERIFIED-SDK]` (`SCStream.h:279`, type `NSInteger`) | `3` (cho LAN low-latency) | **Correction (corpus REFUTED claim "range 3–8, default 3"):** header thực tế nói **default = 8** và chỉ có giới hạn mềm trên `"should not exceed 8 frames"`, **không có** floor cứng = 3. Production code dùng `queueDepth=1` và `=2` thành công (daylight-mirror giảm 3→2 cắt P95 RTT 21.6→18.8ms). Mỗi surface thừa = thêm tối đa 1 frame-interval backlog. Deadline release IOSurface = `minimumFrameInterval × (queueDepth−1)`; ở 120fps queueDepth=3 → 16.7ms. Chọn 2–3 cho min latency nếu encode kịp deadline. |
| `config.pixelFormat` `[VERIFIED-SDK]` (`SCStream.h:234`, type `OSType`) | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`'420v'`) 8-bit | NV12 đi thẳng vào VideoToolbox HW encoder, **không** color-conversion pass. BGRA buộc 1 GPU blit (~0.5–2ms ở 4K). |
| `config.pixelFormat` (HDR/10-bit) | **Correction:** dùng preset, **không** assign `'x420'` trực tiếp | **REFUTED:** `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`, 4:2:0 video-range) **không** nằm trong danh sách pixelFormat được document của SCK. Header liệt kê đúng 6 giá trị, trong đó 10-bit YCbCr duy nhất là `'xf44'` (4:4:4 full-range). Đường HDR chính thức: dùng `SCStreamConfiguration` preset (`SCStreamConfigurationPresetCaptureHDRLocalDisplay`, macOS 15.0+ `[VERIFIED-SDK SCStream.h:194`]) — preset tự set `captureDynamicRange`, `pixelFormat`, `colorSpace`, `colorMatrix`. |
| `config.showsCursor` `[VERIFIED-SDK]` (`SCStream.h:254`, `BOOL`) | `false` | Không composite cursor vào frame; client tự vẽ overlay cursor từ input stream (xem stage Input). |
| `config.captureResolution` `[VERIFIED-SDK]` (`SCStream.h:325`, `SCCaptureResolutionType`, macOS 14.0+) | `.nominal` (= `SCCaptureResolutionNominal`) | Point resolution thay vì 2× Retina; trên 4K Retina giảm 4× pixel count → encode + memory bandwidth giảm tương ứng. |
| `config.ignoreShadowsSingleWindow` `[VERIFIED-SDK]` (`SCStream.h:320`, `BOOL`, macOS 14.0+) | `true` | Strip window shadow composited bởi WindowServer → giảm bounding box capture. |
| `config.captureDynamicRange` `[VERIFIED-SDK]` (`SCStream.h:370`, `SCCaptureDynamicRange`, macOS 15.0+) | `SCCaptureDynamicRangeSDR` (default) cho SDR | HDR chỉ Apple Silicon; để SDR khi stream SDR để tránh kích hoạt EDR pipeline downstream. |
| `addStreamOutput(_:type:sampleHandlerQueue:)` `[VERIFIED-CORPUS]` | `DispatchQueue(label:..., qos: .userInteractive)` | Callback delivery priority cao, giảm scheduling jitter dưới tải. |

**Trong callback `stream(_:didOutputSampleBuffer:of:)`:**
- Đọc `SCStreamFrameInfoStatus` ngay đầu; chỉ xử lý khi `SCFrameStatusComplete`/`SCFrameStatusStarted`, return ngay với `SCFrameStatusIdle`/`Blank`/`Suspended` để tránh queue buildup từ idle callbacks.
- Lấy capture timestamp từ attachment `SCStreamFrameInfoDisplayTime` `[VERIFIED-SDK SCStream.h:401`, macOS 12.3+] — **đây là mach_absolute_time ticks** (header `SCStream.h:398–399` ghi rõ "mach absolute time when the event occurred"). **Correction (corpus REFUTED):** `displayTime` **cùng clock domain** với `CACurrentMediaTime()` (cả hai đều dựa trên `mach_absolute_time()`); chỉ cần convert ticks → seconds qua `mach_timebase_info` (Apple Silicon: numer=125, denom=3), **không** cần cross-domain conversion.
- `stream.synchronizationClock` `[VERIFIED-SDK SCStream.h:453`, `CMClockRef`, macOS 13.0+] để align DTS/PTS với encoder.

> **Lưu ý load-bearing:** một pixel đổi trong app → IOSurface composited mà SCK thấy có floor không thể giảm = một chu kỳ vsync của WindowServer (8.33ms @120Hz, 16.67ms @60Hz). Đây **không** phải con số Apple công bố — suy ra từ kiến trúc compositing. Không có public path nào thấp hơn SCK trên macOS 14+.

---

### 2. Encode — VideoToolbox

Codec mặc định project: HEVC Main 10, 4:2:0, no B-frames, infinite GOP + on-demand IDR, low-latency RC.

**Trong `encoderSpecification` dict tại `VTCompressionSessionCreate` (đặt TRƯỚC khi tạo session, KHÔNG qua `VTSessionSetProperty`):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` `[VERIFIED-SDK VTCompressionProperties.h:1202`, macOS 11.3+] | `kCFBooleanTrue` | One-in-one-out pipeline, no frame reorder, faster RC. **Quan trọng (UNCERTAIN→corrected):** Apple **chỉ document H.264** cho key này (WWDC21 + header không nhắc HEVC). HEVC trên Apple Silicon hoạt động thực tế theo FFmpeg patch (gated `TARGET_CPU_ARM64 && AV_CODEC_ID_HEVC`, merged 2025) nhưng **không phải guarantee của Apple** — có rủi ro silent regression qua OS update. Verify runtime bằng `VTCopySupportedPropertyDictionaryForEncoder`. |
| `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Fail fast nếu không có Media Engine thay vì fallback software (chậm 5–20×). |

**Manual HEVC low-latency config (vì `EnableLowLatencyRateControl` chỉ document cho H.264) — qua `VTSessionSetProperty` sau khi tạo session:**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_RealTime` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Không defer frame để batch optimize. |
| `kVTCompressionPropertyKey_AllowFrameReordering` `[VERIFIED-CORPUS]` | `kCFBooleanFalse` | Tắt B-frames; bắt buộc cho LAN remote. |
| `kVTCompressionPropertyKey_AllowOpenGOP` `[VERIFIED-SDK VTCompressionProperties.h:197`, macOS 10.14+] | `kCFBooleanFalse` | **HEVC mặc định `kCFBooleanTrue`** (header `:190–191` xác nhận, đã verify confirmed) → phải tắt tường minh để IDR là decodable độc lập, không cross-GOP dependency. |
| `kVTCompressionPropertyKey_MaxFrameDelayCount` `[VERIFIED-SDK VTCompressionProperties.h:576`, macOS 10.8+] | `0` | **Correction (corpus REFUTED "0=default"):** default là `kVTUnlimitedFrameDelayCount = -1` (`enum` tại `:577`, đã verify), cho phép buffer tùy ý. Đặt `0` → frame N phải emit trước khi call encode frame N return = synchronous immediate emit. Câu "A value of zero implies default behavior" thuộc property **kế bên** `MaxH264SliceBytes` (`:586`), không phải property này. |
| `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` `[VERIFIED-SDK VTCompressionProperties.h:324`, macOS 11.0+] | `kCFBooleanTrue` | HW encoder mặc định ưu tiên quality; đảo lại để giảm encode time (header `:62–65` liệt kê trong recipe ultra-low-latency). |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` `[VERIFIED-CORPUS]` | giá trị rất lớn (`INT_MAX`) | Infinite GOP; IDR chỉ on-demand qua `kVTEncodeFrameOptionKey_ForceKeyFrame`. |
| `kVTCompressionPropertyKey_ExpectedFrameRate` `[VERIFIED-CORPUS]` | target fps (60 hoặc 120) | Giúp encoder pre-config internal timing. |
| `kVTCompressionPropertyKey_MaximumRealTimeFrameRate` `[VERIFIED-SDK VTCompressionProperties.h:668`, macOS 15.0+] | `120` | Hint peak burst rate để encoder không under-config pipeline cho burst. |

**Rate control (mutually-exclusive với low-latency mode):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_AverageBitRate` `[VERIFIED-CORPUS]` | `<target_bps>` | Soft target; auto-bitrate **không** hỗ trợ trong low-latency mode. |
| `kVTCompressionPropertyKey_DataRateLimits` `[VERIFIED-CORPUS]` | `[bytes, seconds]` | Hard cap chống burst overflow làm stall network. |
| **KHÔNG đặt** `kVTCompressionPropertyKey_ConstantBitRate` | — | Mutually exclusive với `EnableLowLatencyRateControl` → `kVTPropertyNotSupportedErr`. |
| `kVTCompressionPropertyKey_MaxAllowedFrameQP` `[VERIFIED-SDK VTCompressionProperties.h:1214`, macOS 12.0+] | `36–40` cho screen-share | Cap kích thước frame; QP ≤40 giữ text legible, chống IDR phình làm spike transmission. |
| `kVTCompressionPropertyKey_SpatialAdaptiveQPLevel` `[VERIFIED-SDK VTCompressionProperties.h:1540`, **macOS 15.0+, macOS-only**] | `kVTQPModulationLevel_Disable` | Header `:1524` ghi rõ "ignored when EnableLowLatencyRateControl is set to true" — disable để đúng/không tốn thời gian phân tích QP. |

**LTR recovery (thay IDR định kỳ):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_EnableLTR` `[VERIFIED-SDK VTCompressionProperties.h:1247`, macOS 12.0+] | `kCFBooleanTrue` | LTR-P frame nhỏ hơn IDR nhiều → recovery rẻ hơn khi mất gói. Header **codec-agnostic** (không giới hạn H.264) → khả dụng với HEVC trên Apple Silicon (corpus REFUTED claim "chưa confirmed"). |
| `kVTEncodeFrameOptionKey_ForceLTRRefresh` `[VERIFIED-SDK VTCompressionProperties.h:1277`] | xem rationale | **Mâu thuẫn trong chính header (confirmed):** type annotation ghi `// CFNumberRef, Optional` nhưng `@abstract` (`:1265`) nói "Set this option to kCFBooleanTrue". Runtime chưa rõ → **test cả `kCFBooleanTrue` lẫn `@(1)` (CFNumberRef)** để xác định cái nào encoder chấp nhận. |
| `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens` `[VERIFIED-CORPUS]` | CFArray CFNumberRef | Client feed-back token đã ACK trong per-frame options. |

**H.264 fallback only:**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_H264EntropyMode` `[VERIFIED-CORPUS]` | `kVTH264EntropyMode_CABAC` (với High profile) | CABAC ~7% better compression; trên HW decoder Apple Silicon chênh latency decode CABAC vs CAVLC là sub-ms. |
| `kVTCompressionPropertyKey_MaxH264SliceBytes` `[VERIFIED-SDK VTCompressionProperties.h:588`, H.264-only, macOS 10.8+] | `~1300` (MTU-aligned) | Mỗi slice 1 packet UDP; **không có equivalent cho HEVC** trong VideoToolbox. |

**Khởi tạo & pre-warm:**
- `VTCompressionSessionPrepareToEncodeFrames(session)` `[VERIFIED-CORPUS]` — gọi MỘT lần sau set properties, trước frame đầu, để loại bỏ first-frame allocation spike (resource alloc, ref buffer, HW queue init).
- macOS 26+: nếu có, dùng `kVTCompressionPreset_VideoConferencing` `[VERIFIED-SDK VTCompressionProperties.h:1606`, macOS 26.0+] — header `:1602` ghi rõ "requires setting kVTVideoEncoderSpecification_EnableLowLatencyRateControl to kCFBooleanTrue". Query qua `kVTCompressionPropertyKey_SupportedPresetDictionaries` trước khi apply.

> **Số đo (corpus, uncertain):** H.264 1080p60 ~15ms/frame, HEVC ~18ms/frame trên M4 (Lumen README — self-reported, methodology không rõ). Apple **không** công bố per-frame encode latency. WWDC21: "up to 100ms reduction" ở 720p30 là loại bỏ reorder buffer, **không** phải raw encode time.

---

### 3. Transport — Network.framework + BSD sockets

LAN-only, không NAT. Lựa chọn nền tảng: plain UDP cho video (encryption overhead ~0) hoặc QUIC datagram nếu Wi-Fi cần congestion control.

**Network.framework (`NWParameters`):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `parameters.serviceClass = .interactiveVideo` `[VERIFIED-CORPUS]` | video flow | Map tới `NET_SERVICE_TYPE_VI` → Wi-Fi 802.11e **AC_VI** (UP 5). **Correction (corpus UNCERTAIN):** trên macOS đây **chỉ** set Wi-Fi L2 User Priority, **KHÔNG** set IP-header DSCP trừ khi interface có Cisco Fastlane (cần MDM). Public C enum `nw_service_class_interactive_video` = **2** (không phải `NET_SERVICE_TYPE_VI`=3); translation table là private. |
| `parameters.serviceClass = .responsiveData` `[VERIFIED-CORPUS]` | input/control flow | Channel điều khiển độ trễ thấp riêng. |
| `parameters.requiredInterfaceType = .wiredEthernet` `[VERIFIED-CORPUS]` ⚠️ **KHÔNG dùng trên NetBird** (utun=`.other`, sẽ hỏng — [13](13-netbird-transport.md)) | — | Pin Ethernet, tránh fallback cellular/Wi-Fi và Happy Eyeballs probing. |
| `parameters.includePeerToPeer = false` `[VERIFIED-CORPUS]` (default) | — | **Không** bật `true`: kích hoạt AWDL → channel-hopping gây spike 40–336ms (DTS warning thread/751839). Hạ tầng Wi-Fi tốt hơn AWDL khi có. |
| `parameters.multipathServiceType = .disabled` `[VERIFIED-CORPUS]` | — | Tránh path-probing trên single-interface LAN. |
| `parameters.allowFastOpen = true` `[VERIFIED-CORPUS]` | — | Cho QUIC 0-RTT resumption khi reconnect; UDP không có handshake nên trivial. |
| `connection.shouldCalculateReceiveTime = true` `[VERIFIED-CORPUS]` | — | Kernel receive timestamp (`NWProtocolIP.Metadata.receiveTime`) cho đo latency một chiều. |

**QUIC datagram (nếu chọn QUIC, iOS 16+/macOS 13+):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `NWProtocolQUIC.Options.isDatagram = true` `[VERIFIED-CORPUS]` | — | Unreliable datagram, congestion-aware. |
| `quicOptions.maxDatagramFrameSize = 1200` `[VERIFIED-CORPUS]` | — | Dưới path MTU, tránh QUIC fragmenting. |
| `quicOptions.idleTimeout = 30000` (ms) `[VERIFIED-CORPUS]` + keepalive | — | Giữ connection sống qua network blip ngắn → reconnect không tốn handshake. |

**Per-packet & nhận:**
- `NWProtocolIP.Metadata().serviceClass = .interactiveVideo` cho video datagram; `.signaling` cho IDR-request/control để tránh head-of-line queuing.
- `NWProtocolIP.Metadata().ecn = .ect1` `[VERIFIED-CORPUS]` — ECT(1) là L4S codepoint (RFC 9331); chỉ có lợi nếu AP/switch có L4S AQM.
- **Receive pattern (critical):** trong completion handler của `connection.receiveMessage(completion:)`, xử lý xong rồi **gọi lại `receiveMessage` (chain, không loop)** trên serial queue. `NWConnection.receiveMessage` chỉ giao **1 datagram/callback** (DTS confirmed thread/116500, 2019) — gọi trong loop tạo unbounded queued reads.
- `connection.maximumDatagramSize` `[VERIFIED-CORPUS]` — query sau `.ready` (thường 1472 trên Ethernet); fragment slice ≤ giá trị này, IP fragmentation thêm 1–5ms jitter và gấp đôi loss probability.

**BSD socket path (nếu cần batch receive — `NWConnection` không có batch-receive):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `setsockopt(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_VI)` `[VERIFIED-CORPUS]` (`=3`) | hoặc `NET_SERVICE_TYPE_RV`=5 | Wi-Fi AC_VI. `RV` (5) được XNU `socket.h` mô tả "Responsive Multimedia A/V — E.g. screen sharing". |
| `setsockopt(IPPROTO_IP, IP_TOS, dscp<<2)` `[VERIFIED-CORPUS]` | AF41 = `34<<2` | **Đây là cách đáng tin cậy duy nhất set DSCP trên Ethernet** (corpus correction): kernel **không** zero-out user-set `ip_tos` trên non-Fastlane interface. `SO_NET_SERVICE_TYPE` một mình không set DSCP. |
| `setsockopt(SOL_SOCKET, SO_NOSIGPIPE, 1)` `[VERIFIED-CORPUS]` (`=0x1022`) | — | macOS không có `MSG_NOSIGNAL`; bắt buộc tránh SIGPIPE giết process. |
| `setsockopt(IPPROTO_IP, IP_BOUND_IF, if_nametoindex("en0"))` `[VERIFIED-CORPUS]` | — | Equivalent của Linux `SO_BINDTODEVICE`; pin wired NIC, tránh VPN/Wi-Fi routing. |
| `sendmsg_x` (syscall 481) / `recvmsg_x` (syscall 480) `[PRIVATE, VERIFIED-CORPUS]` | `struct msghdr_x` array | Batch UDP, gộp N syscall → 1. **Stable & callable trên macOS 14+** (confirmed: syscall numbers trong public `usr/include/sys/syscall.h`, symbols exported từ `libSystem.B.tbd`). **PRIVATE:** `msghdr_x` chỉ ở `socket_private.h`, phải tự forward-declare. **macOS 13 hang bug → chỉ dùng macOS 14+.** |

> **Số đo:** Wired GigE one-way <0.1ms (1500-byte serialize ~12µs). Network.framework user-space path: ~30% ít CPU receive vs BSD socket (WWDC18 715) — **nhưng** trên **macOS 14** bị disable & fallback BSD socket khi built-in firewall **bật** (DTS confirmed 14.4.1); trên **macOS 15.3+** firewall không còn ép fallback (corpus correction). Verify bằng `sudo skywalkctl flow -n -P <pid>`.

---

### 4. Decode — VideoToolbox

`VTDecompressionSession`, render thẳng ra Metal (xem stage Render), **không** qua đường internal-queue gây buffer.

| Symbol | Giá trị | Rationale |
|---|---|---|
| `VTDecompressionSessionDecodeFrame(..., flags: 0, ...)` `[VERIFIED-CORPUS]` | flags = `0` | Clear cả `kVTDecodeFrame_EnableAsynchronousDecompression` và `kVTDecodeFrame_EnableTemporalProcessing` → synchronous: callback fire trước khi call return, loại bỏ internal queue/reorder buffer. **Lưu ý (corpus uncertain):** HW decoder có thể dispatch nội bộ async và set `kVTDecodeInfo_Asynchronous` trong infoFlags callback dù caller thread vẫn block — đây là behavior chưa document, không phải vi phạm guarantee. |
| **KHÔNG đặt** `kVTDecodeFrame_EnableTemporalProcessing` | — | Bit này cấp phép decoder delay callback để sort display-order → thêm pipeline depth dù stream không có B-frame. |
| `kVTDecompressionPropertyKey_RealTime` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Default = true (header confirmed unchanged tới macOS 26.5) nhưng đặt tường minh; QoS real-time cho decode pipeline. **KHÔNG** đặt đồng thời `kVTDecompressionPropertyKey_MaximizePowerEfficiency` (undefined behavior). |
| `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` (trong decoderSpecification dict) | Fail cứng thay vì silent software fallback (HEVC Main10 software >30ms). |
| Verify sau create: `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | == `kCFBooleanTrue` | Xác nhận Media Engine đang chạy. |

**imageBufferAttributes (destination):**

| Key | Giá trị | Rationale |
|---|---|---|
| `kCVPixelBufferMetalCompatibilityKey` `[VERIFIED-CORPUS]` | `true` | Bắt buộc IOSurface-backed → zero-copy `CVMetalTextureCacheCreateTextureFromImage`. |
| `kCVPixelBufferPoolMinimumBufferCountKey` `[VERIFIED-CORPUS]` | `3`–`6` | ALVR visionOS dùng 3 tối thiểu; đủ buffer in-flight chống pool exhaustion stall. |
| pixel format | match decoder native (`420YpCbCr8...VideoRange` 8-bit / `420YpCbCr10BiPlanarVideoRange` 10-bit) | **KHÔNG** request format khác → tránh VT-internal conversion blit. **Correction:** copy/conversion là **Apple-documented** (WWDC14 session 513: format mismatch → "extra buffer copy"), không phải "undocumented". |
| **KHÔNG đặt** `kCVPixelBufferPixelFormatTypeKey` (nếu nhắm visionOS) | — | ALVR ghi: "setting pixelFormat *at all* causes a copy to uncompressed MTLTexture buffer" trên visionOS 2. Trên macOS: chỉ format-incompatible mới trigger `VTPixelTransferSession` blit — chưa confirmed cho native-format request. |

**Encode-side bitstream để decode 1-in-1-out (set khi encode):**
- H.264 SPS VUI: `bitstream_restriction_flag=1`, `num_reorder_frames=0`, `max_dec_frame_buffering=1`. Thiếu các field này, HW decoder Apple buffer 4 frame/keyframe với MAIN profile (W3C WebCodecs #732).
- HEVC SPS: `sps_max_num_reorder_pics[0]=0`.

**Recovery:** lỗi decode → check `VTDecompressionSessionCanAcceptFormatDescription`; nếu OK, request IDR và giữ session sống (request IDR = 1 RTT LAN <1ms). **Tránh** teardown+recreate session (~30–100ms stall, corpus inferred — không phải Apple-published).

> **Số đo:** ~1–3ms HW decode trên M-series (Moonlight #1087/#1249). Regression macOS 26 Tahoe 80ms (#1696) là vấn đề render path (Metal/AVSampleBufferDisplayLayer presentation timeout), **không** phải HW decode engine.

---

### 5. Render — Metal + display (macOS & iOS)

**Dùng `CAMetalLayer` + `CVMetalTextureCache`, KHÔNG dùng `AVSampleBufferDisplayLayer`** cho đường low-latency (AVSBDL thêm ≥1 frame buffering, Moonlight #1885).

**macOS (`CAMetalLayer`):**

| Symbol | Giá trị | Rationale |
|---|---|---|
| `CAMetalLayer.displaySyncEnabled = false` `[VERIFIED-CORPUS]` | (vsync-off) | Present ngay khi GPU xong, bỏ toàn bộ vsync wait (tới 16.7ms@60Hz); chấp nhận tearing. Hoặc `true` + `CAMetalDisplayLink` cho vsync-on low-latency. |
| `CAMetalLayer.maximumDrawableCount = 2` `[VERIFIED-CORPUS]` | `2` (macOS) | **Correction (corpus REFUTED):** Apple **KHÔNG** nói "2 không khuyến nghị cho iOS" — ràng buộc duy nhất là giá trị ∈ {2,3}, áp dụng đồng đều mọi platform. 3 drawables → backlog 16–50ms; 2 → hội tụ ~16ms. Cảnh báo duy nhất từ Apple engineer: value 2 tăng khả năng `nextDrawable` trả nil. |
| `CAMetalLayer.framebufferOnly = true` `[VERIFIED-CORPUS]` (default) | — | Cho phép lossless compression + compositor fast path. |
| `CAMetalLayer.presentsWithTransaction = false` `[VERIFIED-CORPUS]` (default) | — | KHÔNG sync với CA transaction (thêm tới 1 CA frame); chỉ bật khi cần đồng bộ Metal + UIKit overlay. |
| `CAMetalDisplayLink` `[VERIFIED-SDK QuartzCore header]` (macOS 14.0+ / iOS 17.0+) | thay CVDisplayLink | **Correction (corpus REFUTED):** header là `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))` — **KHÔNG** giới hạn Apple Silicon. Moonlight tự thêm guard `isAppleSilicon()` là lựa chọn riêng của họ, không phải yêu cầu API. |
| `CAMetalDisplayLink.preferredFrameLatency = 1.0` `[VERIFIED-CORPUS]` | `1.0` | **Correction (corpus confirmed):** đơn vị là **frames** (Float); giá trị hợp lệ chỉ `1.0` hoặc `2.0`. `1.0` = 1 display cycle = min API cho phép. System có thể vượt latency yêu cầu (windowed macOS). |
| `CAMetalDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps)` `[VERIFIED-CORPUS]` | lock stream fps | Chống ProMotion downclock gây jitter. |
| `commandBuffer.waitUntilScheduled` (KHÔNG `waitUntilCompleted`) `[VERIFIED-CORPUS]` | — | `Completed` block tới khi pixel vào framebuffer (5–15ms stall trong direct mode); `scheduled` chỉ chờ submit (Zed 120fps blog). |

**iOS/iPadOS:**

| Symbol | Giá trị | Rationale |
|---|---|---|
| Info.plist `CADisableMinimumFrameDurationOnPhone = true` `[VERIFIED-CORPUS]` | — | **Bắt buộc** unlock ProMotion 120Hz trên iPhone; thiếu → cap 60Hz dù gọi API. |
| `CAMetalLayer.opaque = true` (= `CALayer.isOpaque`) `[VERIFIED-CORPUS]` | `true` | **Uncertain:** Flutter/Impeller đo presentation delay giảm 21–26ms → ~13ms, nhưng đây là **một** observation đơn lẻ, **không** phải Apple-documented guarantee; cơ chế là compositor skip alpha-blending. Đặt vì rẻ và an toàn. |
| `CAMetalLayer.maximumDrawableCount = 2` `[VERIFIED-CORPUS]` | `2` | Min pipeline depth (xử lý nil drawable). Hợp lệ trên iOS (xem correction ở trên). |
| `CAMetalDisplayLink.preferredFrameRateRange = CAFrameRateRange(minimum:60, maximum:60, preferred:60)` `[VERIFIED-CORPUS]` | cho stream 60fps trên client 120Hz | 60 chia chẵn 120 → mỗi frame double-pump 16.67ms, zero judder. **Tránh** preferred:120 cho stream 60fps (chỉ double-scan, tốn điện vô ích). |
| `UIUpdateLink` `[VERIFIED-CORPUS]` (iOS 18+, UIKit path) | `requiresContinuousUpdates = true` | Low-latency mode cho UIKit-hosted; với pure Metal `CAMetalLayer` dùng `CAMetalDisplayLink`. |

**Zero-copy decode→render (cả 2 platform):**
- `CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)` một lần lúc startup.
- Mỗi frame biplanar YCbCr: gọi `CVMetalTextureCacheCreateTextureFromImage` 2 lần — planeIndex 0 (`.r8Unorm` 8-bit / `.r16Unorm` 10-bit) cho Y; planeIndex 1 (`.rg8Unorm` / `.rg16Unorm`) cho CbCr. Cùng IOSurface, zero GPU copy.
- Pin IOSurface khi GPU đang dùng: giữ strong ref `CVMetalTexture` trong `commandBuffer.addCompletedHandler` (CVMetalTextureCache quản use-count nội bộ), hoặc thủ công `IOSurfaceIncrementUseCount`/`Decrement`.

**Beam-racing pacing:** trong callback `CAMetalDisplayLink`, render **frame mới nhất** có sẵn (không chờ frame khớp đúng `targetTimestamp`), commit trước `targetTimestamp`. Moonlight tính `waitTimeMs = ((targetTimestamp − CACurrentMediaTime())*1000)/2` để chờ frame mới nhất tới sát deadline.

**Color/EDR — bỏ compositor color-match pass:**
- `CAMetalLayer.colorspace = nil` `[VERIFIED-CORPUS]` — pass-through, bỏ color-match pass (Apple WWDC16 605: "fastest approach"). Hoặc match `NSScreen.colorSpace` native (Chromium research: "no additional GPU power"). Đặt sRGB-tagged trên P3 display → "nontrivial-but-not-excessive" cost mỗi frame.
- `CAMetalLayer.wantsExtendedDynamicRangeContent = false` `[VERIFIED-CORPUS]` cho SDR — tránh EDR processing pass (WWDC21 10161 "extra processing pass... increases latency and bandwidth"). Khả dụng iOS 16+.
- `CAMetalLayer.edrMetadata = nil` — không gán `CAEDRMetadata` (thêm 1 compositor pass).
- SDR path: `pixelFormat = .bgra8Unorm` (32 bit/px). HDR path: `.bgra10a2Unorm` (32 bit/px, bằng 8-bit) + PQ/HLG colorspace, **không** `.rgba16Float` (64 bit/px, gấp đôi bandwidth). Chỉ 2 format hỗ trợ EDR: `rgba16Float` và `bgra10a2Unorm`.

> **macOS yêu cầu fullscreen cho Adaptive Sync/VRR scheduling** (WWDC21 10147, confirmed): app single-window/windowed **không** hưởng VRR scheduling — chỉ fullscreen window (`NSFullScreenWindowMask`) mới qua được `NSScreen.minimumRefreshInterval/maximumRefreshInterval` path.

---

### 6. Input — CGEvent / Accessibility injection + local cursor

Mô hình activate-then-control. Host inject input vào window đích không cần raise; client vẽ cursor local.

| Symbol / kỹ thuật | Cấu hình | Rationale |
|---|---|---|
| **Local cursor overlay** `[VERIFIED-CORPUS]` | client vẽ cursor từ input stream, KHÔNG encode vào video | Cursor feedback ~0–2ms thay vì chờ video roundtrip ~15–25ms. Đây là tối ưu cảm nhận-độ-trễ giá trị nhất. Host: `config.showsCursor = false`. |
| `CGEventPostToPid(pid, event)` `[VERIFIED-CORPUS]` (macOS 10.11+) | KHÔNG `CGEventPost` | Giao event thẳng tới PID đích, không vào global HID stream, không di chuyển system cursor, không cần window foreground. **Correction (corpus uncertain):** đây **không** phải "Mach IPC round-trip" thuần — route qua CoreGraphics→WindowServer→app event tap (≥2 hop). Latency thực trên Apple Silicon **chưa đo được** (không có benchmark public); ước tính 50–200µs là unsubstantiated. |
| `SLPSPostEventRecordTo` `[PRIVATE, VERIFIED-CORPUS]` (SkyLight, dlopen/dlsym) | gọi 2 lần (PSN cũ + PSN đích) | Activate-without-raise: flip AppKit-active state cho input routing, tránh Space-switch 100–300ms. **Cảnh báo:** paneru #123 cho thấy SIGABRT trên macOS 14.2.1 — nhưng root cause là `CGSEncodeEventRecord` serialize buffer sai (0xFF fill → ObjC class pointer), **không** phải `SLPSPostEventRecordTo` bị restrict. Fix: skip `make_key_window()` trên macOS 14. Tahoe 26 chưa rõ. |
| DriverKit virtual HID `[VERIFIED-CORPUS]` | `com.apple.developer.driverkit.userclient-access` entitlement | Inject ở IOHIDSystem layer (đường hardware thật), bypass `CGXSenderCanSynthesizeEvents()` gate. **Cần thiết trên macOS Tahoe 26**: unsigned daemon `CGEventPost` bị drop cho modifier+key combos → 2–3s input lag (input-leap #2367). |
| `CGEventTap` `[VERIFIED-CORPUS]` (client capture) | `kCGHIDEventTap`, `kCGHeadInsertEventTap`, `kCGEventTapOptionListenOnly` | Passive tap ở HID level (sớm nhất trong userspace), không bị `tapDisabledByTimeout` (vì listen-only). QoS `.userInteractive` cho run loop. |
| `kTCCServicePostEvent` + Accessibility | entitlement | Bắt buộc cho `CGEventPostToPid` trên macOS 14+. App **phải code-signed** (không bare daemon) để qua Tahoe 26 gate. |

**Protocol input:**
- Button/key event: gửi **ngay** (zero queuing), datagram riêng.
- Motion event: batch ở cadence 1ms (khớp USB HID 1000Hz polling). KHÔNG batch button với motion.
- iOS touch: `event.coalescedTouches(for:)` `[VERIFIED-CORPUS]` lấy hết sample 240Hz/120Hz; gửi tất cả thay vì sample cuối. `event.predictedTouches(for:)` cho extrapolation.
- **KHÔNG** motion prediction trên LAN: RTT <1 frame (8.3ms@120Hz) → prediction tốn complexity, lợi ~0ms. Local cursor overlay đã loại bỏ visual lag.

---

### 7. Threading — RT scheduling (Apple Silicon)

Ba cơ chế chồng nhau; với Apple Silicon **os_workgroup là cơ chế chính** cho guaranteed P-core scheduling.

| Symbol / API | Cấu hình | Rationale |
|---|---|---|
| `thread_policy_set(..., THREAD_TIME_CONSTRAINT_POLICY, ...)` `[VERIFIED-CORPUS]` | `period`, `computation`, `constraint`, `preemptible` ở mach ticks | Đưa thread vào kernel RT band, bypass QoS decay. 60fps: `period=16_666_666ns × denom/numer`, `computation=period/2`, `constraint=period×0.85`, `preemptible=1`. Convert ns→ticks bằng `mach_timebase_info` (Apple Silicon numer=125, denom=3). **Phải gọi TRƯỚC `os_workgroup_join`.** |
| `os_workgroup_interval_create("...", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL)` `[VERIFIED-CORPUS]` | + `os_workgroup_interval_start/finish` mỗi frame | Báo deadline cho performance controller → giữ P-cluster active giữa các frame, chống off-ramp+on-ramp tần số. **PREREQUISITE confirmed:** thread join phải có `THREAD_TIME_CONSTRAINT_POLICY` trước, nếu không `EINVAL` ("thread is not realtime") — **chỉ áp dụng cho workgroup type `WORK_INTERVAL_TYPE_COREAUDIO`**; workgroup type khác EINVAL chỉ nghĩa "cancelled". |
| `pthread_attr_setschedpolicy(SCHED_RR)` + priority `47–48` `[VERIFIED-CORPUS]` | chỉ render/encode thread | Chống priority decay; **không tương thích QoS** (opt-out vĩnh viễn). Chỉ dùng cho thread có time window cố định, không chạy 100% liên tục. |
| `DispatchQueue(qos: .userInteractive)` `[VERIFIED-CORPUS]` | SCK callback queue, VT callback queue | P-core preference + priority inheritance. Đủ làm baseline; combine với `THREAD_TIME_CONSTRAINT_POLICY` cho thread critical nhất. |
| `mach_wait_until(deadline)` `[VERIFIED-CORPUS]` | KHÔNG `usleep()` trên RT thread | **Correction (corpus uncertain):** con số "<600µs 99.9%" thực ra từ một comment GitHub micropython #8621 (hardware không rõ), **không** phải Apple forum thread/120403; Apple TN2169 chỉ đặt soft floor 500µs trên máy idle. Trên Apple Silicon thread mặc định rơi vào E-core → cần affinity/workgroup. |
| `os_unfair_lock` `[VERIFIED-CORPUS]` | thay `dispatch_semaphore` cho cross-thread signaling | Tham gia QoS priority inheritance (boost low-QoS holder); semaphore không donate priority. |
| **KHÔNG** `yield()`/`sched_yield()` `[VERIFIED-CORPUS]` | — | **Confirmed (XNU source):** tank priority về 0 (DEPRESSPRI=MINPRI=0), defer tới 10ms. **Áp dụng cả SCHED_RR** (= TH_MODE_FIXED, không miễn trừ). Một yield trên hot thread = blow frame deadline. |
| **KHÔNG** `THREAD_AFFINITY_POLICY` trên Apple Silicon `[VERIFIED-CORPUS]` | — | Trả `KERN_NOT_SUPPORTED` (46) trên ARM. Dùng workgroup + RT policy để steer P-core thay vì pin core. |

**Swift caveat `[VERIFIED-CORPUS]`:** tránh Swift trên RT hot path — CoW mutation, `swift_beginAccess` exclusivity check (16-byte heap alloc), nested function capture, thrown error đều có thể alloc → stall RT thread. Viết inner loop bằng C/ObjC hoặc allocation-free Swift.

> **Không có public os_workgroup riêng cho ScreenCaptureKit hoặc VideoToolbox** (chỉ có audio workgroup qua `kAudioDevicePropertyIOThreadOSWorkgroup`). Pipeline video tự tạo interval workgroup riêng.

---

### 8. Memory — zero-copy (Apple Silicon unified memory)

Toàn pipeline SCK→VT encode→network→VT decode→Metal giữ zero-copy vì mọi stage thao tác cùng IOSurface vật lý.

| Kỹ thuật | Cấu hình | Rationale |
|---|---|---|
| SCK → encoder zero-copy `[VERIFIED-CORPUS]` | `CMSampleBufferGetImageBuffer()` → thẳng vào `VTCompressionSessionEncodeFrame` | IOSurface từ SCK là cùng memory HW encoder DMA. **Bắt buộc** pixelFormat YCbCr (`'420v'`/10-bit) khớp encoder; BGRA buộc conversion pass (WWDC22 "let VideoToolbox handle encoding without color space conversion step"). |
| `VTCompressionSessionGetPixelBufferPool()` `[VERIFIED-CORPUS]` | nếu cần GPU pre-process trước encode | Pool vend buffer đúng format + IOSurface config encoder mong đợi → không conversion. |
| Decoder → Metal zero-copy `[VERIFIED-CORPUS]` | `kCVPixelBufferMetalCompatibilityKey: true` + `CVMetalTextureCacheCreateTextureFromImage` | IOSurface decoder ghi = MTLTexture shader đọc; trên unified memory không PCIe copy. |
| **TRÁNH** `CVPixelBufferCreateWithBytes`/`CreateWithPlanarBytes` `[VERIFIED-CORPUS]` | — | Tạo CPU-memory-only buffer **không** IOSurface-backed (QA1781 confirmed) → CVMetalTextureCache fail, buộc copy. Luôn dùng pool với `kCVPixelBufferIOSurfacePropertiesKey: [:]`. |
| `autoreleasepool { }` `[VERIFIED-CORPUS]` | bọc toàn body SCK callback + VT decode handler | Obj-C object (CMSampleBuffer, CVMetalTexture, NSData) tích lũy trên dispatch queue pool, drain burst gây pause 5–30ms (forum thread/725744). |
| `DispatchData(bytesNoCopy:count:deallocator:)` `[VERIFIED-CORPUS]` | thay `Data(bytes:count:)` cho `NWConnection.send` | `Data` init always copy; `DispatchData` no-copy với custom deallocator release CMSampleBuffer ref. **Uncertain:** chưa rõ Network.framework có copy nội bộ vào kernel send buffer hay không. |
| Pool sizing `[VERIFIED-CORPUS]` | ≥4–6 buffer (2 frame encoder pipelining + 1 Metal render) | Tránh `kCVReturnWouldExceedAllocationThreshold` → CPU stall chờ buffer = 1 frame period. |

**Private symbol (rủi ro cao):**
- `MTLPixelFormatYCBCR8_420_2P = 500`, `MTLPixelFormatYCBCR10_420_2P = 505` `[PRIVATE]` — single-plane YCbCr texture binding, bỏ matrix-multiply trong shader. **Confirmed là Apple-internal SPI** (WebKit define dưới `#else` của `USE(APPLE_INTERNAL_SDK)`, ALVR label "private"). Raw value 500 đúng. **macOS availability KHÔNG confirmed** từ public source (chỉ có circumstantial: MTLTools.framework string table, CMImaging/NRFV4 dylib). MoltenVK map Vulkan YCbCr → `MTLPixelFormat::Invalid` trên macOS. Dùng = SPI không guarantee qua OS version.

---

### Tóm tắt ngân sách glass-to-glass (wired LAN, Apple Silicon)

| Stage | 120 fps | 60 fps |
|---|---|---|
| Capture (1 vsync compositor floor) | ~8.3ms | ~16.7ms |
| Encode (HEVC HW, corpus-uncertain) | ~2–4ms (Apple chưa công bố per-frame) | ~2–4ms |
| Network (wired GigE one-way) | <0.1ms | <0.1ms |
| Decode (HW Media Engine) | ~1–3ms | ~1–3ms |
| Render + display scanout (avg half-frame) | ~4.2ms (Metal direct) | ~8.3ms |
| **Floor thực tế (corpus)** | **~14–16ms** | **~22–26ms** |

Wi-Fi 6/6E thêm 1–3ms (lý tưởng) tới 2–5ms (thực tế). Cursor qua local overlay: feedback ~2–5ms độc lập với pipeline video. Các con số encode/decode đánh dấu **uncertain** vì Apple không công bố per-frame latency chính thức; nguồn duy nhất là self-reported (Lumen) hoặc community (Moonlight).

---

## Ranked techniques by latency impact

Bảng dưới đây xếp hạng tất cả các đòn bẩy giảm latency từ **win lớn nhất → cận biên**, dựa trên toàn bộ corpus. Cột "est. ms saved / impact" lấy số liệu đo được/dẫn nguồn khi có; khi corpus chỉ mô tả định tính, đã ghi rõ. Cột "risk" phản ánh các phán quyết adversarial (refuted/uncertain) trong corpus — các claim đã bị bác bỏ hoặc còn nghi ngờ được đánh dấu rõ ràng.

> Quy ước: ms tiết kiệm phụ thuộc mạnh vào frame rate và điểm vận hành. Trừ khi ghi rõ, số liệu ở 60 fps (frame = 16.67 ms) / 120 fps (frame = 8.33 ms).

| # | Technique | Est. ms saved / impact | Apple support | Difficulty | Risk |
|---|-----------|------------------------|---------------|------------|------|
| 1 | **Low-latency rate control encode** — `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (H.264) + manual HEVC config (`AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `RealTime=true`) | **~100 ms** ở 720p30 so với default buffering mode (WWDC21 session 10158) — chủ yếu từ loại bỏ frame reordering/B-frame reorder buffers | native (H.264); HEVC **empirically functional** trên Apple Silicon | low | **MED** — HEVC support do FFmpeg patch (commit d87210745e, gated `TARGET_CPU_ARM64`) chứng minh, **KHÔNG** phải Apple documentation; WWDC21 chỉ nói H.264. SDK header không có codec restriction. Rủi ro silent regression qua OS update. `kVTPropertyNotSupportedErr (-12900)` khi query HW-accel là API incompleteness, KHÔNG phải bằng chứng software fallback (galad87, forum 751291) |
| 2 | **Wired Gigabit Ethernet thay vì Wi-Fi** | **2–30 ms** loại bỏ overhead + toàn bộ Wi-Fi jitter; wired one-way <0.1 ms vs Wi-Fi 6/6E 0.5–2 ms (typical), spike 4–20 ms khi nhiễu | native | low | **LOW** — vật lý link-layer; không có downside ngoài yêu cầu cáp |
| 3 | **Client-side cursor overlay** (vẽ cursor từ input channel, KHÔNG encode vào video; `SCStreamConfiguration.showsCursor=false`) | **~15–25 ms** cho phản hồi thị giác cursor trên LAN (loại bỏ toàn bộ video round-trip cho cursor); cursor xuất hiện ~0–2 ms sau input vs ~17–30 ms qua video | native | medium | **LOW** — RDP/PCoIP/NoMachine đều làm vậy; cần out-of-band cursor-shape sharing |
| 4 | **Metal direct render thay vì AVSampleBufferDisplayLayer** (client) — `CVMetalTextureCacheCreateTextureFromImage` → `CAMetalLayer` | **8–33 ms** (1–2 frame buffering); ở 120 Hz là ≥8.3 ms, 60 Hz ≥16.7 ms (Moonlight #1885) | native | medium | **MED** — bằng chứng định tính ("one or more extra frames"), đo trên macOS dGPU (Radeon Pro 580); **chưa có benchmark iOS** Metal-vs-AVSBDL và Moonlight-iOS không có Metal fallback (corpus uncertain). Trên Apple Silicon unified memory không có GPU copy penalty nên lợi ích càng rõ |
| 5 | **120fps / ProMotion end-to-end** (host `minimumFrameInterval=1/120` + client `CAMetalDisplayLink` 120 Hz) | **~8.3 ms** giảm worst-case vsync wait (16.67→8.33 ms); cộng ~4 ms average capture-to-encode | native | low–medium | **MED** — yêu cầu host display 120 Hz (M1 Pro/Max+) VÀ encode hoàn tất trong 8.3 ms hoặc SCK drop frame. macOS 15 đổi default `minimumFrameInterval` thầm lặng thành 1/60 (confirmed); phải set explicit. Lưu ý: dùng `1/target_fps × 0.9` (OBS PR#11896) — **KHÔNG dùng `kCMTimeZero`** (claim đó bị refuted: OBS không dùng kCMTimeZero, không có SDK header xác nhận) |
| 6 | **Avoid AVSampleBufferDisplayLayer audio synchronizer** / dùng PTS-based fire-and-forget AV sync | **~1000 ms** tránh buffering của `AVSampleBufferRenderSynchronizer` (~1 s buffer ahead) | native | medium | **LOW** — nếu vô tình dùng synchronizer mode sẽ phá toàn bộ video latency work. Số ~1 s là community-reported, chưa có Apple official figure (claim_to_verify) |
| 7 | **VideoToolbox HW decode + verify** (`RequireHardwareAcceleratedVideoDecoder=true`, `RealTime=true`) | **5–17 ms** (HW ~1–3 ms vs SW 8–20 ms); HEVC Main10 SW fallback >30 ms | native | low | **LOW** — `flags=0` synchronous completion **confirmed** trong SDK header (không phân biệt HW/SW). `RealTime` default đã là true (confirmed qua macOS 26.5) nhưng nên set explicit; KHÔNG set cùng `MaximizePowerEfficiency` (undefined behavior) |
| 8 | **Display drop policy "always-newest"** (Moonlight pacer: cap 3 frames, drop oldest-first mỗi vsync, target 1) | **8.3–25 ms** (mỗi frame thừa trong queue = 1 frame interval; backlog 3 frame = 25 ms ở 120 fps) | native | medium | **LOW** — verified trong moonlight-qt pacer.cpp |
| 9 | **THREAD_TIME_CONSTRAINT_POLICY + os_workgroup cho hot threads** | Tránh **5–20 ms** scheduler-induced stall; thay usleep variance 500–5000 µs bằng `mach_wait_until` <600 µs (99.9%) | native | medium | **MED** — `os_workgroup_join` cần RT policy trước (EINVAL "not realtime" **confirmed** nhưng chỉ với `WORK_INTERVAL_TYPE_COREAUDIO`). Số "<600 µs 99.9%" là **misattributed** (từ micropython issue #8621, hardware unspecified, không phải Apple forum 120403) và chưa reproduce trên Apple Silicon (uncertain). `yield()` tank priority về 0 tới 10 ms — **confirmed** áp dụng cả SCHED_RR. Swift heap allocations có thể stall RT thread |
| 10 | **SCK queueDepth tuning** (=3 cho min latency capture-side; cân nhắc 5 nếu GPU load spike) | Tránh backlog **lên tới 116 ms** (queueDepth=8 default ở 60 fps); với =3 max backlog 16.6 ms | native | low | **LOW** — "3–8 strict range" là **refuted**: default thực là **8** (không phải 3), không có minimum documented; queueDepth=1/2 chạy được trong production. "3" chỉ là conservative community default từ nhầm lẫn với CGDisplayStream cũ |
| 11 | **SCK `420v` YCbCr pixel format thay vì BGRA** (zero-copy vào VideoToolbox) | **~0.5–3 ms** loại bỏ một GPU color-conversion pass ở 4K | native | low | **LOW** — WWDC22 confirmed "lowest CPU cost"; loại bỏ một full DRAM round-trip |
| 12 | **Zero-copy IOSurface end-to-end** (SCK→VT→VT→Metal, không memcpy; `kCVPixelBufferMetalCompatibilityKey`) | **15–60 µs/frame** copy tránh được; + tránh deferred autorelease spike 5–30 ms (autoreleasepool wrapping) | native | low–medium | **LOW** — WWDC21: 62% bandwidth reduction. Lưu ý: **KHÔNG set `kCVPixelBufferPixelFormatTypeKey`** trên decode imageBufferAttributes nếu khớp native format (mismatch trigger VTPixelTransferSession copy — confirmed via WWDC14 session 513). Hành vi visionOS 2 "set pixelFormat at all = copy" **chưa confirm trên macOS 14+** (uncertain) |
| 13 | **Opus RESTRICTED_LOWDELAY 5ms frame** (audio) | **~15 ms** so với Opus 20ms default (7.5 ms vs 22.5 ms algorithmic delay) | partial (libopus, không native) | medium | **LOW** — Sunshine dùng chính config này. Hoặc PCM trên LAN = 0 ms codec delay (~3.1 Mbit/s stereo, trivial trên wired) |
| 14 | **CoreAudio HAL buffer reduction** (`kAudioDevicePropertyBufferFrameSize=64–128`) | **~8 ms** (512→128 frames: 10.67→2.67 ms; →64: 1.33 ms) | native | medium | **LOW** — phải set trước khi allocate render resources; min phụ thuộc driver |
| 15 | **LTR recovery thay vì full IDR** (`EnableLTR`, `ForceLTRRefresh`) | **30–100 ms** tránh được mỗi recovery (LTR-P nhỏ hơn IDR 10–30×, không bandwidth spike) | native | medium | **MED** — `EnableLTR` codec-agnostic, HEVC+LTR trên Apple Silicon **confirmed khả thi** (SDK header không restrict, FFmpeg ARM64 path). `ForceLTRRefresh` type mâu thuẫn nội bộ trong header: annotation nói `CFNumberRef`, doc comment nói `kCFBooleanTrue` — phải test cả hai ở runtime (confirmed inconsistency) |
| 16 | **Skip idle frames + dirtyRects** (SCK) | **high** — tránh encoder queue buildup từ idle callbacks; dirtyRects giảm encode time cho partial updates | native | low–medium | **LOW** |
| 17 | **`maximumDrawableCount=2`** (giảm pipeline depth) | **8–34 ms** (count=3 cho 16–50 ms variable latency; count=2 hội tụ ~8–16 ms) | native | low–medium | **LOW** — "không khuyến nghị cho iOS/iPadOS" là **refuted**: Apple chỉ giới hạn range [2,3], không có prohibition iOS-specific. Trade-off thực: `nextDrawable` có thể trả nil → cần frame-drop logic |
| 18 | **NWParameters `requiredInterfaceType` + `includePeerToPeer=false`** (pin LAN, tránh path eval) | Tránh **50–200 ms** path-evaluation + tránh **40–336 ms** AWDL spike | native | low | **LOW** — đảm bảo không fallback cellular/AWDL |
| 19 | **serviceClass = .interactiveVideo** (Wi-Fi WMM AC_VI) | **~10× jitter** trên Wi-Fi congested (AC_BE ~67 ms → AC_VI/VO ~7 ms); marginal khi light load | native | low | **MED** — chỉ set Wi-Fi 802.11e UP, **KHÔNG** set IP-header DSCP trừ Fastlane network (confirmed). Wired LAN dùng `IP_TOS` setsockopt trực tiếp nếu cần DSCP. `nw_service_class_interactive_video=2` ≠ `NET_SERVICE_TYPE_VI=3` (namespace khác, mapping private) |
| 20 | **Beat-frequency rate exact-match** (host display = client refresh, ví dụ cả hai 60.000 Hz) | **0–16.67 ms** oscillation (60 Hz) loại bỏ; beat period 60.000 vs 59.94 ≈ 16.7 s | native | medium | **MED** — yêu cầu force host display đúng 60.000 Hz (không 59.951); EDID có thể map nominal 60 thành 59.951 |
| 21 | **VTCompressionSessionPrepareToEncodeFrames** (pre-warm) + giữ session sống qua reconnect | First-frame: tránh init spike (ước 1–10 ms); reconnect: tránh **30–100 ms** session rebuild | native | low | **MED** — số first-frame spike chưa có public measurement (open question); 30–100 ms rebuild là inferred, chưa Apple-documented |
| 22 | **CAMetalDisplayLink `preferredFrameLatency=1`** | **~8–16 ms** (default là 2 frame trên iOS) | native | low | **LOW** — confirmed: chỉ chấp nhận 1.0 hoặc 2.0; system có thể vượt khi cần (windowed macOS). `CAMetalDisplayLink` **KHÔNG** giới hạn Apple Silicon (refuted: chỉ `@available(macOS 14)`; Moonlight tự thêm `isAppleSilicon()` guard) |
| 23 | **CAMetalLayer.opaque=true** (client) | **~8–13 ms** (21–26 ms → 13 ms, Flutter/Impeller #134959) | native | low | **HIGH-uncertainty** — số 13 ms là **single profiling observation**, không reproducible baseline; Flutter giải pháp thực là custom IOSurface layer (PR #48226), không phải flag này. `opaque` là CALayer property (skip alpha-blending), Apple không document latency guarantee |
| 24 | **`displaySyncEnabled=false`** (vsync-off, tearing) | **8.3–16.7 ms** (loại bỏ toàn bộ vsync wait) | native | low | **MED** — gây tearing trên non-adaptive-sync display; cân nhắc adaptive sync (fullscreen) thay thế |
| 25 | **CAMetalLayer.colorspace = nil** (bypass color-match compositor pass) | **sub-frame, non-zero** (Apple: "fastest approach"; định tính "nontrivial-but-not-excessive" GPU cost mỗi frame nếu mismatch) | native | low | **LOW** — không có Apple ms figure; trade-off: raw color trên P3 display. Hoặc match display native colorspace |
| 26 | **Disable EDR cho SDR streams** (`wantsExtendedDynamicRangeContent=false`) | **sub-frame** — WWDC21 10161: EDR tone mapping "involves an extra processing pass... increases latency and bandwidth" | native | low | **LOW** — không có ms figure; FP16 buffer 2× bandwidth vs bgra10a2 |
| 27 | **Adaptive sync (VRR) fullscreen** (`presentDrawable:afterMinimumDuration:`) | **3–8 ms** average trên 120 Hz adaptive display | native | medium | **MED** — **fullscreen là hard requirement** (WWDC21 10147 confirmed; Apple Support 102144 im lặng vì nói về OS-level feature, không phải app API). Single-window/windowed app KHÔNG hưởng lợi VRR scheduling |
| 28 | **kCMSampleAttachmentKey_DisplayImmediately** (nếu buộc dùng AVSampleBufferDisplayLayer) | Bound display latency ~1 scan period thay vì 1–3 frame accumulate | native | low | **MED** — hành vi "bypass all enqueued frames" từ forum 14212, chưa confirm trên macOS 14+ dưới sustained load (claim_to_verify) |
| 29 | **QUIC keepalive + 0-RTT resumption** (reconnect cold path) | **2–5 ms** (1-RTT LAN) hoặc **0 ms** (0-RTT/keepalive); tránh re-handshake | native | medium | **MED** — `allowFastOpen` confirmed cho TCP path; **QUIC 0-RTT property trong NWProtocolQUIC chưa verify** (claim_to_verify). 0-RTT không có forward secrecy, replay-susceptible (chấp nhận được cho control) |
| 30 | **sendmsg_x / recvmsg_x batch UDP** (raw socket) | **high throughput**, medium per-frame; gộp N syscall → 1 | partial (PRIVATE syscall) | medium | **MED** — syscall 480/481 **confirmed stable** macOS 14+ Apple Silicon; symbols exported từ libSystem; nhưng PRIVATE (msghdr_x chỉ trong socket_private.h, phải tự forward-declare). **macOS 13 hang** — chỉ dùng macOS 14+ |
| 31 | **Pre-trigger Local Network permission** (onboarding) | Tránh **vài giây** blocking trên first cold launch (iOS 14+ privacy gate) | native | low | **LOW** — correctness/cold-path fix, không phải steady-state |
| 32 | **Slice-based encoding / sub-frame pipelining** | **~10–12 ms** (Haivision; lý thuyết (N-1)/N × encode_time) — **NHƯNG không khả thi qua public VideoToolbox API** | **unsupported** (VideoToolbox = frame granularity) | exotic | **HIGH** — VideoToolbox output là **frame-granular**, callback 1 lần/frame. `MaxH264SliceBytes` chỉ H.264, không sub-frame callback. `kVTCompressionPropertyKey_NumberOfSlices`/`NumberOfSubFrameSections` là **private symbols** (confirmed tồn tại trong .tbd iOS 9.3–26.x) nhưng KHÔNG có public header, KHÔNG có call-site nào, hành vi khi gọi **hoàn toàn unknown** (uncertain). Manual NAL-split sau callback chỉ tiết kiệm ~0.1–1 ms trên LAN |
| 33 | **AES-128-GCM encryption (nếu cần)** vs ChaCha20 | Chọn AES-GCM: **~10 µs/frame** tiết kiệm vs ChaCha20 (4.6 GB/s vs 1.75 GB/s trên M1); AES toàn bộ **<0.1 ms/frame** = negligible | native (QUIC TLS 1.3 tự chọn AES-GCM) | low | **LOW** — QUIC luôn encrypted (không tắt được). Dùng CryptoKit không OpenSSL. Số throughput từ OpenSSL benchmark; coreCrypto internal chưa public-benchmarked (claim_to_verify) |
| 34 | **AWDL peer-to-peer (`includePeerToPeer=true`)** cho video stream | **NEGATIVE** — thêm 40–336 ms RTT spike chu kỳ ~5 s; AWDL channel-hop 50–200 ms mỗi 10–12 s | partial | low | **HIGH** — Apple DTS: P2P Wi-Fi "hundreds of ms"; infrastructure Wi-Fi tốt hơn. **TRÁNH cho video.** Wi-Fi Aware `WAPerformanceMode.realtime` chỉ iOS/iPadOS 26 (`@available(macOS, unavailable)` confirmed), cần entitlement |
| 35 | **DriverKit virtual HID injection** (vs CGEventPostToPid) | Tránh **2–3 s lag** macOS Tahoe 26 (CGEventPost từ unsigned daemon bị block); latency = physical HW path | native (cần entitlement) | exotic | **MED** — số "physical HW path latency" là Karabiner claim, chưa có measured comparison. Đơn giản hơn: dùng signed app + `kTCCServicePostEvent` |
| 36 | **CABAC vs CAVLC, profile selection, MaxH264SliceBytes MTU-align** | **marginal** (~7% bitrate CABAC; slice MTU-align ~1–3 ms) | native | low | **LOW** — trên Apple Silicon HW decoder, CABAC/CAVLC diff sub-ms; HEVC bắt buộc CABAC |
| 37 | **`preferNoChecksum`, batch send, BSD checksum offload** | **marginal** (~1–5 µs/packet; ~0 với HW offload) | native | low | **LOW** |
| 38 | **HEVC tiles / WPP control** | **N/A** — không có API surface | **unsupported** | exotic | **N/A** — Media Engine xử lý nội bộ; không có `kVTCompressionPropertyKey` cho tiles/WPP |
| 39 | **DPDK / kernel-bypass** | **N/A** trên macOS/iOS | **unsupported** | exotic | **N/A** — SIP + entitlement model chặn userspace NIC; NEPacketTunnelProvider chậm hơn, không nhanh hơn |
| 40 | **RFC 9150 integrity-only ciphers** | **~3 µs/frame** lý thuyết | **unsupported** (QUIC chỉ AEAD) | exotic | **N/A** — không áp dụng cho QUIC/Network.framework |

---

### Do these first (highest leverage, lowest risk)

Theo thứ tự ưu tiên triển khai cho stack mục tiêu (macOS host → macOS/iOS client, LAN, Apple Silicon):

1. **Wired Gigabit Ethernet** (#2) — nền tảng. Sub-0.1 ms one-way, zero jitter. ⚠️ Trên **NetBird** KHÔNG pin `requiredInterfaceType = .wiredEthernet` (utun=`.other` → hỏng); để mặc định, routing table tự lái 100.64/10 ([13](13-netbird-transport.md)). Giữ `includePeerToPeer = false`.
2. **Low-latency encode config** (#1) — `EnableLowLatencyRateControl` cho H.264; với HEVC set thủ công `RealTime=true`, `AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `PrioritizeEncodingSpeedOverQuality=true`, `MaxKeyFrameInterval=INT_MAX`. **Verify HEVC support ở runtime** qua `VTCopySupportedPropertyDictionaryForEncoder` (vì Apple chỉ document H.264).
3. **HW decode + verify** (#7) — `RequireHardwareAcceleratedVideoDecoder=true`, `flags=0` synchronous, `RealTime=true`, verify `UsingHardwareAcceleratedVideoDecoder`.
4. **Metal direct render path** (#4) — `CVMetalTextureCacheCreateTextureFromImage` → `CAMetalLayer`, tránh AVSampleBufferDisplayLayer. Đây là điểm phân biệt lớn so với Moonlight trên macOS.
5. **Client-side cursor overlay** (#3) — `showsCursor=false`, vẽ cursor local. Đòn bẩy "perceived responsiveness" lớn nhất; cursor cảm giác tức thì.
6. **Zero-copy IOSurface + `420v` pixel format** (#11, #12) — xuyên suốt pipeline; bọc per-frame callback trong `autoreleasepool {}`.
7. **Display drop policy "always-newest"** (#8) + **queueDepth=3** (#10) + **maximumDrawableCount=2** (#17) — chính sách queue zero-depth, drop oldest-first mỗi vsync.
8. **120fps/ProMotion nếu cả hai đầu hỗ trợ** (#5) — dùng `1/target_fps × 0.9` cho `minimumFrameInterval`, KHÔNG `kCMTimeZero`. Set explicit để tránh macOS 15 cap 1/60.
9. **RT threads cho capture/encode/network** (#9) — `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until`; QoS `.userInteractive`; tránh `yield()`; viết hot path bằng C/ObjC nếu Swift allocation gây stall.
10. **Audio: Opus 5ms hoặc PCM + HAL buffer 64–128 frames + PTS fire-and-forget sync** (#13, #14, #6) — tuyệt đối tránh `AVSampleBufferRenderSynchronizer`.

---

### Diminishing returns / probably skip

- **Slice/sub-frame pipelining** (#32) — **skip**. Không khả thi qua public VideoToolbox API (frame-granular output, confirmed). Private symbols `NumberOfSlices`/`NumberOfSubFrameSections` tồn tại nhưng hành vi unknown và rủi ro. Manual NAL-split sau callback chỉ ~0.1–1 ms trên LAN — không đáng độ phức tạp.
- **AWDL peer-to-peer cho video** (#34) — **skip, harmful**. Thêm latency thay vì giảm. Dùng infrastructure Wi-Fi/Ethernet.
- **HEVC tiles/WPP, DPDK kernel-bypass, RFC 9150 ciphers** (#38, #39, #40) — **skip**. Không có API surface trên Apple platforms.
- **CAMetalLayer.opaque=true** (#23) — **thử nhưng đừng tin số**. Số 13 ms là single observation chưa reproducible; set nó (rẻ, an toàn) nhưng đừng kỳ vọng guarantee.
- **DriverKit virtual HID** (#35) — **skip ban đầu**, chỉ cần nếu macOS Tahoe 26 chặn `CGEventPostToPid` cho use-case cụ thể. Signed app + `kTCCServicePostEvent` đủ cho hầu hết.
- **Adaptive sync/VRR** (#27) — **skip cho single-window windowed app**. VRR scheduling yêu cầu fullscreen (confirmed); app chia sẻ một cửa sổ thường không fullscreen nên không hưởng lợi.
- **DSCP marking qua serviceClass trên wired LAN** (#19) — **marginal trên wired**. Chỉ set Wi-Fi UP, không IP DSCP trừ Fastlane. Đáng làm cho Wi-Fi multi-client; gần như vô nghĩa trên dedicated wired LAN.
- **Encryption tuning ChaCha vs AES** (#33) — **negligible** trên Apple Silicon (<0.1 ms/frame với AES-GCM HW). Chỉ cần đảm bảo không vô tình chọn ChaCha20; QUIC tự lo. Trên LAN cô lập vật lý, cân nhắc plaintext video + encrypted control channel (Moonlight model).
- **`preferNoChecksum`, batch send micro-opts** (#37) — **marginal** với HW checksum offload hiện đại.

> **Lưu ý đo lường xuyên suốt:** overlay latency của các streamer (Moonlight stats, Virtual Desktop indicator) **under-report ~40 ms** vì bỏ qua capture delay, compositor buffering, và display scanout (Greendayle). Dùng LED+photodiode rig (~21 ns resolution) hoặc 240/1000 fps camera để đo glass-to-glass thực; nếu tổng các stage software lệch >1 ms so với hardware measurement thì có bug clock/instrumentation.

---

## Verified API claims, corrections & Phase-0 validation list

Phần này hợp nhất toàn bộ các phán quyết kiểm chứng đối kháng (adversarial verification) trong corpus thành một nguồn sự thật duy nhất cho khâu thiết kế. Mọi claim "load-bearing" — tức claim mà nếu sai sẽ làm hỏng kiến trúc hoặc thổi phồng/đánh giá sai ngân sách latency — đều được gắn verdict (`confirmed` / `refuted` / `uncertain`), confidence, và phát biểu đã sửa. **Quy tắc vàng: bất kỳ dòng nào có verdict `refuted` hoặc `uncertain` đều KHÔNG được phép là giả định cứng trong thiết kế — nó phải đi vào Phase-0 spike để xác nhận bằng đo đạc trên phần cứng mục tiêu (Apple Silicon, macOS 14+).**

### 1. Bảng tổng hợp verdict (load-bearing API claims)

#### 1.1 Capture — ScreenCaptureKit

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| C1 | `minimumFrameInterval = kCMTimeZero` bật native refresh delivery; SDK header nói vậy; OBS PR #11896 chứng minh | **refuted** | high | `kCMTimeZero` KHÔNG được OBS dùng và KHÔNG có header Apple nào nói vậy. OBS PR #11896 đặt `minimumFrameInterval = (1/target_fps) × 0.9` — một `CMTime` cụ thể, ngắn hơn ~10% so với chu kỳ frame, KHÔNG phải zero. Lý do: đặt đúng nghịch đảo fps làm rớt frame ([OBS PR #11896](https://github.com/obsproject/obs-studio/pull/11896)). **Thiết kế phải dùng giá trị 0.9× rõ ràng, không dùng kCMTimeZero.** |
| C2 | Default `minimumFrameInterval` đổi thành `1/60` trong macOS 15 (kể cả ProMotion) | **confirmed** | high | Đúng. SDK header diff: macOS 14.5 nói default = 0 (unthrottled); macOS 15.5 nói default = `1/60`. Apple đã cập nhật docstring header (nhưng không ghi trong release notes). Để capture ở native refresh phải set `minimumFrameInterval` rõ ràng ([macos-sdk diff](https://sourcegraph.com/github.com/alexey-lysiuk/macos-sdk), [OBS #11778](https://github.com/obsproject/obs-studio/issues/11778)). |
| C3 | `queueDepth` hợp lệ strictly 3–8, default 3 | **refuted** | high | Default là **8** (không phải 3). Header chỉ nói "should not exceed 8" (trần mềm) — KHÔNG có sàn cứng 3. Giá trị 1 và 2 chạy thành công trong nhiều project shipping (daylight-mirror giảm 3→2: P95 RTT 21.6ms→18.8ms). "3" là default của API cũ CGDisplayStream, bị nhầm. **Dùng queueDepth=2 cho latency tối thiểu là hợp lệ; 3 là mức bảo thủ.** ([SCStream.h:273-276](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth)) |
| C4 | `SCStreamFrameInfoDisplayTime` cùng clock domain với `CACurrentMediaTime()` (mach_absolute_time) | **confirmed** | high | Đúng. SCStream.h xác nhận đây là "mach absolute time"; `CACurrentMediaTime()` = `mach_absolute_time()` đổi sang giây. KHÔNG cần đổi domain — chỉ cần đổi đơn vị ticks→giây qua `mach_timebase_info`. Lỗi "negative latency" trên forum là bug runtime/PTS riêng, không phải mismatch domain ([SCStream.h:399](https://developer.apple.com/forums/thread/785046)). |

#### 1.2 Encode — VideoToolbox

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| E1 | `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` hoạt động với HEVC trên Apple Silicon, "được xác nhận bởi SDK comment" | **uncertain** → (chi tiết hơn ở E2) | high | Câu "SDK comment nói vậy" là SAI. Câu "supported only for H.264 on Intel… both on Apple Silicon" đến từ **commit message của tác giả FFmpeg (Cameron Gutman)**, KHÔNG phải header Apple. Doc chính thức của Apple (WWDC21) chỉ nói H.264. HEVC + low-latency RC chạy trên Apple Silicon theo bằng chứng thực nghiệm FFmpeg (PR #20453, gate `TARGET_CPU_ARM64`), nhưng **không có đảm bảo từ Apple** ([WWDC21 10158](https://developer.apple.com/videos/play/wwdc2021/10158/), [FFmpeg](https://www.mail-archive.com/ffmpeg-devel@ffmpeg.org/msg185545.html)). |
| E2 | Header SDK macOS 26.5 vẫn ghi "supported video codec type: H.264" | **refuted** | high | Header KHÔNG chứa cụm "supported video codec type: H.264" ở bất kỳ phiên bản nào (15.4 hay 26.5) — docblock của constant này hoàn toàn codec-agnostic. Cụm đó chỉ có trong transcript WWDC21. HEVC chạy được trên ARM64 theo FFmpeg. **Phải xác nhận runtime; rủi ro silent regression qua các bản OS.** |
| E3 | `kVTCompressionPropertyKey_EnableLTR` chưa rõ có chạy với HEVC low-latency không (WWDC chỉ demo H.264) | **refuted** | high | Header EnableLTR (macOS 12.0/iOS 15.0) hoàn toàn không hạn chế codec. FFmpeg production code xác nhận HEVC low-latency RC chạy trên ARM64 và EnableLTR áp dụng trong cùng session path. **HEVC + EnableLowLatencyRateControl + EnableLTR là tổ hợp khả thi cho macOS 14+/Apple Silicon**, nhưng nên validate runtime qua `VTCopySupportedPropertyDictionaryForEncoder`. |
| E4 | `kVTEncodeFrameOptionKey_ForceLTRRefresh` là `CFNumberRef` (không phải CFBoolean như WWDC nói) | **confirmed** | high | Đúng. Annotation inline trong header ghi `// CFNumberRef, Optional`, NHƯNG `@abstract` cùng header lại nói "Set this option to kCFBooleanTrue" — **mâu thuẫn nội bộ header Apple.** Runtime chưa được giải quyết bởi header. **Phải test cả `kCFBooleanTrue` và `@(1)` (CFNumberRef) ở runtime để biết encoder chấp nhận cái nào** ([VTCompressionProperties.h:1265-1277](https://developer.apple.com/videos/play/wwdc2021/10158/)). |
| E5 | `kVTCompressionPropertyKey_MaxFrameDelayCount = 0` nghĩa là "default behavior / no limit" | **refuted** | high | SAI — không có câu "value of zero implies default behavior" trong block MaxFrameDelayCount (câu đó thuộc property kế bên `MaxH264SliceBytes`). Theo công thức header: M=0 ⇒ "trước khi encode frame N trả về, frame N phải đã được phát ra" = **emit đồng bộ/ngay lập tức**. Default no-limit là `kVTUnlimitedFrameDelayCount = -1`, không phải 0. **Set `MaxFrameDelayCount = 0` để cưỡng chế one-in-one-out.** |
| E6 | `kVTCompressionPropertyKey_AllowOpenGOP` default = `kCFBooleanTrue` cho HEVC | **confirmed** | high | Đúng và không đổi qua macOS 15.4→26.5/iOS. **HEVC mặc định cho phép Open-GOP — PHẢI set `false` rõ ràng** cho recovery IDR sạch (single-window streaming cần mỗi IDR độc lập decode được) ([VTCompressionProperties.h:186-197](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_allowopengop)). |

#### 1.3 Slice-pipelining (private symbols)

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| S1 | `kVTCompressionPropertyKey_NumberOfSlices` tồn tại và "set được mà không crash" | **uncertain** | high | Symbol tồn tại trong .tbd từ iOS 9.3→26.x (CONFIRMED), nhưng là **PRIVATE** — không có khai báo trong header công khai. Câu "set được mà không crash" KHÔNG có bằng chứng nào; hành vi khi truyền vào `VTSessionSetProperty` (ignore/lỗi/crash) là **unknown**. Không dùng trong thiết kế trừ khi spike xác nhận. |
| S2 | `kVTCompressionPropertyKey_NumberOfSubFrameSections` có hiệu ứng quan sát được | **uncertain** | high | Symbol thật, exported từ iOS 13→26.5, nhưng không có header/doc/call-site OSS nào. Hiệu ứng khi set là unknown — không thể bác bỏ là "vô tác dụng" nhưng cũng không có bằng chứng nó hoạt động. **Bỏ khỏi thiết kế chính.** |
| S3 | `kVTSampleAttachmentKey_SliceAttachments` / `SliceDataLength` xuất hiện trong attachment dict output | **uncertain** | high | Là symbol PRIVATE đã export (resolve thành string "SliceAttachments"/"SliceDataLength"), nhưng KHÔNG có trong header công khai và **không xác nhận được runtime có populate hay không.** Không dựa vào để làm manual NAL splitting. **Kết luận kiến trúc: VideoToolbox output ở mức frame-granular; true sub-frame pipelining kiểu NVENC KHÔNG khả dụng qua public API — bỏ tiles/WPP/slice-callback khỏi thiết kế.** |

#### 1.4 Decode — VideoToolbox

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| D1 | `kVTDecompressionPropertyKey_RealTime` default = `kCFBooleanTrue` | **confirmed** | high | Đúng, verbatim trong header 15.4 & 26.5: "default is true; setting NULL ≡ kCFBooleanTrue". Đây là **hint, không phải hợp đồng** — vẫn nên set rõ ràng. **Không được set đồng thời `MaximizePowerEfficiency` (undefined behavior).** |
| D2 | `flags = 0` đảm bảo decode đồng bộ; nhưng forum 19046 nói vẫn có thể async với `kVTDecodeInfo_Asynchronous` | **uncertain** | medium | Đảm bảo header ("callback gọi xong trước khi DecodeFrame trả về") là CONFIRMED, áp dụng cho cả HW/SW. Phần claim về forum 19046 KHÔNG xác minh được (403). HW decoder Apple Silicon có thể dispatch nội bộ async và set `kVTDecodeInfo_Asynchronous` trong infoFlags của callback **trong khi thread gọi vẫn bị block** — khả dĩ về kiến trúc nhưng không có nguồn xác nhận. **Dùng flags=0 cho đồng bộ; nếu pipeline CPU work song song thì dùng async + semaphore.** |
| D3 | Set pixel format không khớp trong `destinationImageBufferAttributes` gây extra copy (nhưng "không được Apple ghi rõ") | **refuted** | high | Apple ĐÃ ghi rõ — WWDC14 Session 513: yêu cầu format không phải native (vd BGRA khi decoder xuất YUV) "force an extra buffer copy". Phỏng đoán "unified memory có thể tối ưu hóa cái này" là **không có bằng chứng** — unified memory bỏ PCIe transfer chứ KHÔNG bỏ chi phí compute của conversion. **Phải khớp format native decoder (`420YpCbCr8BiPlanarVideoRange` 8-bit / `420YpCbCr10BiPlanarVideoRange` 10-bit).** |

#### 1.5 Display / Compositor (macOS + iOS)

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| DP1 | `CAMetalDisplayLink` chỉ chạy Apple Silicon | **refuted** | high | Header khai báo `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))` — **KHÔNG có giới hạn Apple Silicon.** Chạy trên mọi Mac macOS 14+ (Intel hay AS). Guard `isAppleSilicon()` là lựa chọn riêng của Moonlight (lý do ProMotion frame-pacing), KHÔNG phải yêu cầu Apple. |
| DP2 | `CAMetalDisplayLink.preferredFrameLatency = 1.0` nghĩa là 1 display cycle | **confirmed** | high | Đúng — đơn vị là **frames**; 1.0 = một display cycle = mức tối thiểu API cho phép. **Chỉ chấp nhận giá trị 1.0 và 2.0** (Apple đánh dấu Important). Hệ thống có thể vượt mức yêu cầu (windowed macOS). Set = 1.0 cho streaming. |
| DP3 | Adaptive sync yêu cầu fullscreen (WWDC21) nhưng Apple Support 102144 không nhắc | **confirmed** | high | Cả hai vế đúng. WWDC21 session 10147 yêu cầu cửa sổ fullscreen (NSFullScreenWindowMask) cho Adaptive-Sync *scheduling* APIs; Support 102144 chỉ mô tả bật ở mức OS. **Hệ quả cho app single-window: app KHÔNG fullscreen sẽ KHÔNG được hưởng VRR scheduling — windowed fallback về fixed-rate compositor path.** |
| DP4 | `maximumDrawableCount = 2` "không được khuyến nghị cho iOS/iPadOS" (theo Apple) | **refuted** | high | Apple KHÔNG có guidance "not recommended for iOS/iPadOS". Ràng buộc duy nhất là giá trị ∈ {2,3}. Cảnh báo duy nhất từ engineer: count=2 tăng khả năng `nextDrawable` trả nil (drop frame) — trung lập nền tảng. **`maximumDrawableCount = 2` được hỗ trợ đầy đủ trên iOS/iPadOS và là lựa chọn đúng cho latency tối thiểu (kèm xử lý nil).** |
| DP5 | `CAMetalLayer.opaque = true` giảm presentation latency xuống ~13ms trên ProMotion | **uncertain** | high | Con số ~13ms là 1 lần đo profiling đơn lẻ của 1 engineer Flutter (issue #134959), không tái lập, không phải đặc tính được Apple đảm bảo. `opaque` kế thừa từ `CALayer.isOpaque`; Apple chỉ ghi nó cho phép bỏ alpha-blending. **Set isOpaque=true là rẻ và hợp lý, nhưng đừng coi "13ms" là số ngân sách — phải tự đo.** |
| DP6 | AVSampleBufferDisplayLayer thêm "1+ frame" buffering so với Metal trên iOS | **uncertain** | medium | Con số "1+ frame" đến từ báo cáo *chủ quan* trên **macOS** (discrete GPU, Moonlight #1885), KHÔNG phải đo trên iOS. Khác biệt kiến trúc compositor (macOS WindowServer vs iOS backboardd) khiến không chắc chuyển sang iOS. **Thiết kế chọn Metal-direct path để loại bỏ rủi ro; nếu dùng AVSampleBufferDisplayLayer phải set `kCMSampleAttachmentKey_DisplayImmediately = true` và đo so sánh trong spike.** |

#### 1.6 Transport — Network.framework / BSD sockets / Wi-Fi QoS

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| N1 | `serviceClass = .interactiveVideo` map sang `NET_SERVICE_TYPE_VI`; swiftinterface xác nhận; mô tả "inelastic flow, constant packet rate" | **uncertain** | medium | Mapping *cấu trúc hợp lý* nhưng KHÔNG xác minh được từ nguồn công khai (translation table nằm trong code Network.framework đóng). swiftinterface chỉ show tên case, KHÔNG show integer. Có enum C riêng `nw_service_class_interactive_video = 2` (≠ `NET_SERVICE_TYPE_VI = 3`). Mô tả "inelastic/constant packet rate" là của VO (voice), SAI — VI thực ra là "elastic flow, constant packet interval, variable rate". **Vẫn dùng `.interactiveVideo` cho video flow, nhưng đừng coi mapping integer là chắc chắn.** |
| N2 | `SO_NET_SERVICE_TYPE` set Wi-Fi 802.11e UP nhưng KHÔNG set IP-header DSCP trên macOS hiện đại | **confirmed** | high | Đúng cho Ethernet thường và Wi-Fi non-Fastlane. Cơ chế là gating theo `IFEF_QOSMARKING_ENABLED` (chỉ bật bởi Cisco Fastlane), KHÔNG phải regression theo version. **Quan trọng: để ghi DSCP trên LAN/Ethernet phải dùng `IP_TOS`/`IPV6_TCLASS` setsockopt trực tiếp** — kernel KHÔNG zero ip_tos do user set trên non-Fastlane interface. Trên Fastlane Wi-Fi, IP_TOS bị bỏ qua. |
| N3 | Network.framework user-space networking (Skywalk/flowsw, zero-copy) active macOS 12+ khi firewall tắt | **uncertain** | medium | (1) Điều kiện firewall **theo version**: macOS 14 firewall bật ⇒ fallback BSD sockets; macOS 15.3+ firewall không còn ép fallback. (2) "Zero-copy" là từ không chính xác — Apple mô tả là path tránh BSD socket qua channel objects, không gọi "zero-copy". (3) Firewall KHÔNG phải trigger duy nhất — iCloud Private Relay và NE VPN cũng fallback. **Verify bằng `sudo skywalkctl flow -n -P <pid>` trên máy mục tiêu.** |
| N4 | `sendmsg_x` (481) / `recvmsg_x` (480) ổn định và gọi được trên macOS 14+ Apple Silicon | **confirmed** | high | Đúng. Số syscall ổn định 10.10→26.5 SDK, symbol export từ libSystem, có trong public `syscall.h`. "PRIVATE" chỉ nghĩa struct `msghdr_x` nằm trong `socket_private.h` (phải tự forward-declare) và không có man page. **macOS 13 có bug hang ⇒ qualifier "macOS 14+" là load-bearing và chính xác** ([xnu syscalls.master:734-740](https://github.com/oven-sh/bun/blob/main/src/analytics/lib.rs)). |
| N5 | `net_qos_policy_restricted` default = 0 ⇒ mọi app được Wi-Fi L2 AC_VI marking không cần MDM | **refuted** | high | Default = 0 (CONFIRMED) nhưng ý nghĩa bị hiểu sai. restricted=0 chỉ *cho phép* socket nâng QoS khi nó *yêu cầu rõ ràng* service type cao; default traffic class là `SO_TC_BE` (AC_BE), KHÔNG tự lên AC_VI. App không set service type ⇒ ở AC_BE. **Phải set `.interactiveVideo`/`NET_SERVICE_TYPE_VI` rõ ràng để lên AC_VI.** |
| N6 | QUIC datagram TLS encryption overhead trên LAN ~0.1–0.5ms | **uncertain** | high | Con số là ước lượng tổng overhead xử lý user-space QUIC, KHÔNG phải "TLS encryption overhead". Chi phí AES-GCM thuần trên Apple Silicon là **sub-microsecond** (<0.001ms cho gói 1400 byte ở 4–11 GB/s HW-accel). Overhead chủ đạo là user-space packet processing, không phải cipher. **Phải tự benchmark NWConnection QUIC datagram vs plain UDP trên stack này.** |

#### 1.7 Realtime threads / scheduling

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| RT1 | `os_workgroup_join` trả EINVAL = "thread is not realtime" (phải set THREAD_TIME_CONSTRAINT_POLICY trước) | **confirmed** | high | Đúng, **nhưng giới hạn phạm vi**: chỉ áp dụng cho workgroup loại `WORK_INTERVAL_TYPE_COREAUDIO` (CoreAudio HAL workgroup). Với workgroup khác, EINVAL chỉ nghĩa "workgroup đã cancelled". Kernel check: `sched_mode != TH_MODE_REALTIME && saved_mode != TH_MODE_REALTIME`. Documentation gap là thật ([xnu work_interval.c:679-685](https://developer.apple.com/forums/thread/697874)). |
| RT2 | `mach_wait_until` trên RT thread < 600µs ở 99.9% (nguồn: forum thread/120403) | **uncertain** | high | **Sai nguồn**: con số đến từ comment không chính thức của @dlech trong micropython issue #8621 (hardware unspecified), KHÔNG phải forum 120403. Apple TN2169 chỉ nói sàn mềm 500µs trên máy idle, không cam kết percentile. Trên Apple Silicon còn nghi ngờ thêm vì thread mặc định rơi xuống E-core. **Phải tự đo với P-core affinity / Audio Workgroup enrollment.** |
| RT3 | `yield()`/`sched_yield()` tụt priority về 0 tới 10ms | **confirmed** | high | Đúng. XNU: `sched_yield()` → `swtch_pri(0)` → `thread_depress_abstime(1 × std_quantum)`; std_quantum=10ms ở 100Hz; DEPRESSPRI=MINPRI=0. **Áp dụng cả SCHED_RR (TH_MODE_FIXED) — không có exemption.** 10ms là cận trên (có thể được reschedule sớm hơn nếu hệ thống nhẹ tải). **Cấm tuyệt đối `yield()` trên hot media thread; dùng `mach_wait_until`.** |

#### 1.8 Zero-copy / memory

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| Z1 | `SCStreamConfiguration.pixelFormat` hỗ trợ `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` ('x420') cho window capture macOS 14+ | **refuted** | high | Format 10-bit YCbCr được header liệt kê là **'xf44' (4:4:4 full-range)**, KHÔNG phải 'x420' (4:2:0 video-range). 'x420' không có trong danh sách supported. HDR APIs (`captureDynamicRange`, `Preset`) yêu cầu **macOS 15.0**, không phải 14.0. **Cho 10-bit HDR dùng `SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)` (macOS 15+); gán trực tiếp 'x420' là undocumented.** |
| Z2 | Set `kCVPixelBufferPixelFormatTypeKey` trong VTDecompressionSession gây copy blit trên macOS (ALVR comment nói visionOS 2) | **uncertain** | medium | ALVR comment chỉ nói **visionOS 2** ("setting pixelFormat at all causes a copy"). Trên macOS, header xác nhận copy (qua `VTPixelTransferSession`) chỉ khi format **không tương thích** với native decoder output — KHÔNG phải vô điều kiện. Hành vi visionOS 2 (copy ngay cả với native format) có áp dụng cho macOS 14+ không thì chưa rõ. **Spike: thử omit pixelFormat key, để decoder xuất native, đo.** |
| Z3 | Private `MTLPixelFormatYCBCR8_420_2P = 500` (và họ hàng) khả dụng trên macOS 14+ Apple Silicon | **uncertain** | high | Giá trị raw 500 CONFIRMED; là **SPI nội bộ Apple** (WebKit định nghĩa dưới `#else of #if USE(APPLE_INTERNAL_SDK)`). KHÔNG có trong public enum, không có `API_AVAILABLE`. MoltenVK map các format YCbCr tương ứng về `Invalid` trên macOS. **Đây là undocumented SPI không có đảm bảo OS-version — chỉ dùng như tối ưu tùy chọn, có fallback shader 2-plane.** |

#### 1.9 Wi-Fi / AWDL

| # | Claim gốc | Verdict | Confidence | Phát biểu đã sửa / cần dùng |
|---|---|---|---|---|
| W1 | AWDL social channels 5GHz là ch 44 và ch 149 | **confirmed** | high | Đúng (ch 6 ở 2.4GHz, ch 44/149 ở 5GHz), từ reverse-engineering (Seemoo Lab, OWL). Apple chưa xác nhận chính thức. **Cấu hình AP dùng ch 44/149 để loại spike AWDL 50–200ms.** |
| W2 | Wi-Fi Aware (`WAPerformanceMode.realtime`) KHÔNG có trên macOS 26 | **confirmed** | high | Đúng — header swiftinterface macOS 26.4 có `@available(macOS, unavailable)` rõ ràng (compile-time). Subsystem chạy nội bộ (daemon wifip2pd) nhưng không expose API cho dev macOS. **Wi-Fi Aware chỉ dùng cho client iOS/iPadOS 26+, không cho macOS.** |

### 2. CORRECTIONS đối với thiết kế trước đây của dự án

Đây là các điểm trong corpus/stack mô tả ban đầu **mâu thuẫn với verdict** và phải sửa trước khi code:

1. **`minimumFrameInterval = kCMTimeZero` (C1, refuted).** Project context và summary capture-floor đề xuất `kCMTimeZero`. **SỬA:** dùng `config.minimumFrameInterval = CMTimeMake(1, targetFPS * 110/100)` (ngắn hơn ~10% theo OBS PR #11896). `kCMTimeZero` không được chứng minh và không có trong code OBS.

2. **`queueDepth` "minimum 3" (C3, refuted).** Nhiều technique trong corpus ghi "3 là minimum". **SỬA:** default thực là 8; sàn cứng không tồn tại; `queueDepth = 2` hợp lệ và cho latency thấp hơn (kèm xử lý IOSurface release nhanh). Dùng 2 hoặc 3 tùy đo đạc deadline release.

3. **`EnableLowLatencyRateControl` + HEVC "được SDK xác nhận" (E1/E2, refuted/uncertain).** **SỬA:** coi đây là hành vi *thực nghiệm* chỉ trên Apple Silicon (bằng chứng FFmpeg), KHÔNG phải đảm bảo Apple. Thiết kế phải có code-path dò runtime (`VTCopySupportedPropertyDictionaryForEncoder`) và fallback cấu hình HEVC low-latency thủ công (E3/E5/E6). Cảnh báo: `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` trả `kVTPropertyNotSupportedErr (-12900)` trong low-latency mode — đây KHÔNG phải bằng chứng mất HW accel; lỗi gating HW thật là `-12902`.

4. **`ForceLTRRefresh` type (E4, confirmed mâu thuẫn nội bộ).** **SỬA:** header tự mâu thuẫn (annotation `CFNumberRef` vs abstract `kCFBooleanTrue`). Code phải thử cả hai và chọn cái encoder chấp nhận ở runtime — không hardcode một loại.

5. **`MaxFrameDelayCount = 0` ý nghĩa (E5, refuted).** **SỬA:** 0 = emit đồng bộ one-in-one-out (đúng cho low-latency), KHÔNG phải "default/no-limit". Đây thực ra là điều ta MUỐN — chỉ cần đảm bảo không hiểu nhầm thành "để encoder tự do buffer".

6. **`AllowOpenGOP` cho HEVC (E6, confirmed).** **SỬA:** HEVC mặc định `true` — PHẢI set `false` rõ ràng. Nếu thiết kế cũ giả định "GOP đóng mặc định", đó là sai.

7. **Slice-pipelining/tiles/WPP (S1–S3, uncertain).** **SỬA:** loại bỏ kỳ vọng sub-frame pipelining kiểu NVENC. VideoToolbox output ở mức frame-granular; các private symbol không đáng tin. Cơ chế song song duy nhất khả dụng là **inter-frame pipelining** (capture N+1 song song transmit/decode N).

8. **Pixel format decode mismatch (D3, refuted "unified memory tự tối ưu").** **SỬA:** phải khớp format native decoder; KHÔNG được giả định unified memory loại bỏ chi phí conversion. Không set `kCVPixelBufferPixelFormatTypeKey` khác native.

9. **DSCP qua `SO_NET_SERVICE_TYPE` (N2, confirmed).** **SỬA:** trên LAN/Ethernet, để ghi DSCP IP-header phải dùng `IP_TOS`/`IPV6_TCLASS` trực tiếp; `SO_NET_SERVICE_TYPE`/`.interactiveVideo` chỉ điều khiển Wi-Fi L2 UP. Dùng cả hai (L2 qua serviceClass, L3 qua IP_TOS) nếu cần priority trên switch managed.

10. **AC_VI "tự động không cần MDM" (N5, refuted).** **SỬA:** phải set service type rõ ràng; default là AC_BE. `net_qos_policy_restricted=0` chỉ *cho phép*, không *tự nâng*.

11. **`maximumDrawableCount=2` "không nên dùng trên iOS" (DP4, refuted).** **SỬA:** dùng 2 trên cả macOS lẫn iOS cho latency tối thiểu (xử lý nil drawable). Lưu ý: Moonlight/Apple DTS khuyến nghị 3 trên macOS để tránh starvation — đây là trade-off cần đo trong spike, không phải cấm.

12. **`CAMetalDisplayLink` "chỉ Apple Silicon" (DP1, refuted).** **SỬA:** không gate theo `isAppleSilicon()` nếu chỉ vì lo API không có — nó có trên mọi Mac macOS 14+. Chỉ gate nếu có lý do ProMotion-specific.

13. **10-bit capture format (Z1, refuted).** **SỬA:** không gán `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` ('x420') vào `SCStreamConfiguration.pixelFormat`. Cho 10-bit HDR dùng `SCStreamConfiguration(preset:)` (macOS 15+) hoặc 'xf44' (4:4:4). Lưu ý: HDR capture cần **macOS 15.0**, không phải 14.0 — điều chỉnh ma trận OS support.

14. **Adaptive sync (DP3, confirmed).** **SỬA:** app single-window (không fullscreen) KHÔNG hưởng VRR scheduling. Nếu cần VRR phải fullscreen — mâu thuẫn với differentiator "single window". Quyết định kiến trúc: hoặc chấp nhận fixed-rate compositor cho windowed, hoặc cung cấp chế độ fullscreen tùy chọn ở client.

### 3. Phase-0 spike — checklist xác nhận thực nghiệm (BẮT BUỘC)

Mọi mục `refuted`/`uncertain` ở trên đều phải được đóng lại bằng đo đạc trên phần cứng mục tiêu (host: Apple Silicon Mac macOS 14 + macOS 15 + nếu có macOS 26; client: macOS + iPhone/iPad 120Hz ProMotion). Đo bằng clock thống nhất `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` và `mach_timebase_info` (Apple Silicon: numer=125, denom=3 — **xác nhận trên M2/M3/M4 vì chỉ M1 được đo công khai**).

**A. Capture (ScreenCaptureKit)**
- [ ] **C1/C2 — minimumFrameInterval:** Trên ProMotion 120Hz, đo fps thực giao với (a) default (kỳ vọng 60), (b) `1/120`, (c) `(1/120)×0.9`, (d) `kCMTimeZero`. *Đo:* đếm callback `complete` trong 10s qua testufo-style content. *Pass:* tìm giá trị cho ≥115 fps ổn định không drop.
- [ ] **C3 — queueDepth:** Thử queueDepth = 1, 2, 3. *Đo:* tỉ lệ drop frame + latency capture→encode-submit khi encoder bận. Xác nhận deadline release `minimumFrameInterval × (queueDepth−1)` đạt được với VT HW encode. *Pass:* chọn giá trị nhỏ nhất không gây stall.
- [ ] **C4 — displayTime clock:** So `SCStreamFrameInfoDisplayTime` (đổi ticks→ns qua mach_timebase) với `CACurrentMediaTime()*1e9` cùng frame. *Pass:* chênh lệch dương, hợp lý (~vài ms), không âm. Nếu âm ⇒ điều tra bug PTS riêng.
- [ ] **Z1 — pixel format:** Liệt kê format thực `SCStreamConfiguration` chấp nhận; thử '420v' (8-bit), 'xf44' (10-bit), và preset HDR (macOS 15+). *Đo:* xác nhận IOSurface backing + không có conversion pass thừa khi feed thẳng vào VT encoder.

**B. Encode (VideoToolbox HEVC)**
- [ ] **E1/E2 — HEVC low-latency RC:** Tạo VTCompressionSession HEVC với `EnableLowLatencyRateControl=true`; gọi `VTCopySupportedPropertyDictionaryForEncoder`. *Đo:* session tạo thành công, HW engine engage (đối chiếu Activity Monitor GPU 0%, đo per-frame encode time). *Pass:* HEVC 1080p60 & 4K60 encode < frame budget; nếu fail ⇒ kích hoạt fallback config thủ công (E3/E5/E6).
- [ ] **E4 — ForceLTRRefresh type:** Gửi LTR refresh bằng `kCFBooleanTrue` rồi bằng `@(1)` (CFNumberRef). *Đo:* output frame có phải LTR-P (nhỏ hơn IDR) không, có lỗi không. *Pass:* xác định đúng loại encoder chấp nhận.
- [ ] **E3 — EnableLTR + HEVC:** Bật EnableLTR trên HEVC low-latency session, chạy vòng ACK token. *Pass:* nhận `RequireLTRAcknowledgementToken` trên output, ForceLTRRefresh tạo LTR-P thay vì IDR.
- [ ] **Per-frame encode latency (open question):** Đo `encode_done_ns − encode_submit_ns` cho HEVC Main10 ở 1080p/4K @ 60/120fps. *Mục tiêu:* xác lập số thật cho ngân sách (ceiling lý thuyết ~3.3ms/1080p chỉ là throughput, không phải latency).
- [ ] **First-IDR spike:** Đo frame đầu CÓ và KHÔNG có `VTCompressionSessionPrepareToEncodeFrames`. *Pass:* lượng hóa penalty cold-start (corpus: chưa có số public).

**C. Decode + Render**
- [ ] **D2 — flags=0 sync:** Đo `decode_done − decode_submit` với flags=0; kiểm `kVTDecodeInfo_Asynchronous` trong infoFlags callback. *Pass:* xác nhận callback fire trước khi DecodeFrame trả về; ghi nhận có async-internal hay không.
- [ ] **D3 / Z2 — destination pixel format:** So 3 cấu hình: (a) omit pixelFormat key, (b) set native `420YpCbCr10BiPlanarVideoRange`, (c) set BGRA. *Đo:* decode latency + GPU blit pass (Instruments). *Pass:* chọn cấu hình không có extra copy trên macOS 14+.
- [ ] **DP6 — AVSampleBufferDisplayLayer vs Metal:** A/B trên cả macOS và iOS client: VTDecompressionSession→CVMetalTextureCache→CAMetalLayer vs AVSampleBufferDisplayLayer (với `DisplayImmediately=true`). *Đo:* glass-to-glass bằng camera tốc độ cao (240fps/1000fps) hoặc photodiode rig. *Pass:* xác định path nào thấp hơn, bằng bao nhiêu ms — KHÔNG dựa vào "1+ frame" suy đoán.
- [ ] **Z3 — private YCbCr MTLPixelFormat:** Thử map decoded 10-bit buffer sang `MTLPixelFormat(rawValue:505)`. *Pass:* hoạt động ⇒ dùng như tối ưu tùy chọn; fail ⇒ fallback 2-plane r16Unorm/rg16Unorm shader. **Không phụ thuộc kiến trúc vào symbol này.**
- [ ] **DP5 — opaque:** Đo presentation latency với `isOpaque` true vs false trên ProMotion. *Pass:* xác nhận hướng cải thiện (không kỳ vọng đúng "13ms").

**D. Transport**
- [ ] **N3 — user-space networking:** Chạy `sudo skywalkctl flow -n -P <pid>` với firewall ON/OFF trên macOS 14 VÀ 15. *Pass:* xác nhận flowsw entries; ghi nhận điều kiện fallback (firewall/Private Relay/VPN).
- [ ] **N4 — sendmsg_x/recvmsg_x:** Forward-declare `msghdr_x`, gọi `sendmsg_x(fd, msgs, N, 0)` batch. *Đo:* số syscall giảm N lần, throughput. *Pass:* chạy không crash trên macOS 14+ AS; so với per-packet sendmsg.
- [ ] **N6 — QUIC vs UDP overhead:** Microbench NWConnection QUIC datagram send-to-send vs plain UDP send-to-send trên LAN wired, gói ~1400B. *Đo:* delta ns/gói bằng Instruments System Trace. *Pass:* lượng hóa overhead thật (corpus chỉ ước lượng).
- [ ] **N1/N5 — QoS marking thực tế:** Set `.interactiveVideo` + `IP_TOS=AF41<<2`; bắt gói bằng Wireshark trên LAN. *Đo:* DSCP byte trong IP header (kỳ vọng 0 cho SO_NET_SERVICE_TYPE alone; non-zero cho IP_TOS); xác nhận Wi-Fi AC_VI qua air capture nếu có. *Pass:* hiểu chính xác cơ chế nào set cái gì.

**E. Realtime threads / scheduling**
- [ ] **RT1 — os_workgroup_join EINVAL:** Thử join CoreAudio workgroup KHÔNG set THREAD_TIME_CONSTRAINT_POLICY (kỳ vọng EINVAL) rồi CÓ set (kỳ vọng OK). *Pass:* xác nhận thứ tự bắt buộc; xác định workgroup video custom có cần điều kiện này không.
- [ ] **RT2 — mach_wait_until jitter:** Đo wakeup jitter trên RT thread (THREAD_TIME_CONSTRAINT_POLICY) CÓ và KHÔNG có os_workgroup_interval, với và không với P-core enrollment. *Pass:* lập phân phối p50/p99/p99.9 thật trên M-series (đừng tin "600µs").
- [ ] **DVFS ramp (open question):** Đo P-core frequency ramp time trên chip mục tiêu (M2/M3/M4) qua IOReport CPU Performance States residency. *Pass:* xác nhận ~70ms (M1) còn đúng hay ngắn hơn; quyết định có cần os_workgroup_interval keep-warm không.

**F. Clock-sync & ground-truth (xuyên suốt)**
- [ ] **mach_timebase numer/denom:** Đọc trên mọi chip mục tiêu. *Pass:* xác nhận 125/3 (M1) đồng nhất qua M2/M3/M4.
- [ ] **NWProtocolIP.Metadata.receiveTime epoch:** Đã xác nhận corpus là **CLOCK_MONOTONIC_RAW** (tăng cả khi sleep), KHÁC `CLOCK_UPTIME_RAW`/`mach_absolute_time`. *Spike:* tính offset đồng thời lúc startup và refresh khi wake-from-sleep. *Pass:* one-way latency không âm, ổn định.
- [ ] **Ground-truth glass-to-glass:** Dựng photodiode + LED rig (Raspberry Pi Pico, ~20ns resolution) hoặc camera 240/1000fps. *Pass:* tổng các stage software đo được khớp hardware trong ±1ms; nếu lệch >1ms ⇒ có bug clock/instrument.
- [ ] **Overlay underreport warning:** Đối chiếu số overlay nội bộ với ground-truth. *Pass:* biết overlay thiếu bao nhiêu (capture delay + compositor + scanout).

**G. Display phase / beat-frequency**
- [ ] **Host display rate exactness:** Đọc rate thực host display (kỳ vọng phát hiện 59.951/59.94 vs 60.000). *Pass:* nếu lệch ⇒ ép `CGDisplaySetDisplayMode` khớp client rate để loại beat (~17–20s period).
- [ ] **DP2 — preferredFrameLatency:** Xác nhận chỉ 1.0/2.0 hợp lệ; đo latency drawable pipeline ở 1.0 vs 2.0. *Pass:* set 1.0 cho streaming.

**Tiêu chí thoát Phase 0:** mọi hàng `refuted`/`uncertain` trong Bảng §1 đã chuyển thành `confirmed`/`refuted` *có số đo*, và pipeline glass-to-glass thực nghiệm (qua ground-truth rig) nằm trong ngưỡng kỳ vọng (~14–16ms @120fps wired, ~22–26ms @60fps wired — các con số này cũng cần validate, vì phần lớn là dẫn xuất chứ chưa đo trên stack native Swift này).
