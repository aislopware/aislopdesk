# 10 — Tối ưu Latency (học từ Parsec, Moonlight/Sunshine)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Chỉ áp dụng cho GUI video-path.** Terminal path ([12](12-coding-profile.md)) có model latency khác hẳn: dominated by network RTT (~1–5ms LAN) + local echo, **không vsync/encode/decode**. Nhiều kỹ thuật dưới đây (pacer, beam-racing) là **over-engineering cho profile coding** — xem [12 §3.3](12-coding-profile.md).

> Tổng hợp kỹ thuật từ các hệ thống production, map sang stack Apple. Moonlight/Sunshine là mã nguồn mở → đọc được code thật (đã trace). Parsec công bố triết lý, không công bố số ms.

## 0. Triết lý cốt lõi (Parsec)

**Ưu tiên theo thứ tự: LATENCY trước → frame rate → chất lượng.** Gần như mọi quyết định dưới đây là hệ quả của thứ tự này. "Buffering là kẻ thù."

---

## 1. Phát hiện QUAN TRỌNG NHẤT: LTR thay cho keyframe (sửa thiết kế cũ)

### Vấn đề "keyframe spike"
Khi mất gói, reference của decoder hỏng → corruption lan sang mọi P-frame sau đó. Cách ngây thơ là gửi IDR/keyframe — **nhưng keyframe nặng gấp 5–20× P-frame**. Trên link đã nghẽn, spike đó gây thêm queuing delay + mất gói mới → "fix" làm latency **tệ hơn**. Đây là bẫy keyframe.

### Giải pháp: **VideoToolbox CÓ hỗ trợ LTR** (Long-Term Reference)
Đây là điểm khác biệt lớn so với thiết kế cũ (chỉ drop-frame + request-keyframe). Workflow LTR trong low-latency mode (WWDC21):

1. Bật LTR: `kVTCompressionPropertyKey_EnableLTR`.
2. Encoder đánh dấu 1 frame là LTR, phát ra **acknowledgement token** trong sample-buffer attachments (`RequireLTRAcknowledgementToken`).
3. Client ack các frame nhận được → host báo lại token đã ack qua per-frame option `AcknowledgedLTRTokens` (array).
4. Khi mất gói → request recovery bằng per-frame option **`ForceLTRRefresh`** → encoder phát **LTR-P frame** nhỏ, predict từ LTR đã-được-ack. **Chỉ khi không còn LTR nào được ack mới fallback keyframe.**

→ **Đây là cơ chế recovery chính của ta.** Cần xây kênh feedback client→host (ack + loss report) để lái nó.

> ⚠️ **Cập nhật từ [11](11-absolute-latency.md):** `EnableLTR` **codec-agnostic** (macOS 12+/iOS 15+) → HEVC+LTR khả thi trên Apple Silicon (vẫn nên feature-detect runtime). **`ForceLTRRefresh` mâu thuẫn nội bộ header:** annotation ghi `CFNumberRef`, abstract ghi `kCFBooleanTrue` → **test cả hai (`@(1)` và `kCFBooleanTrue`) ở runtime**, không hardcode.

### Bổ trợ: Temporal scalability
`kVTCompressionPropertyKey_BaseLayerFrameRateFraction = 0.5` chia stream thành base + enhancement layer; frame enhancement không bị reference → mất nó không lan. Error resilience rẻ. Nhận diện layer qua `CMSampleAttachmentKey_IsDependedOnByOthers`.

### Cái VideoToolbox KHÔNG làm được (khác NVENC)
- ❌ **Reference-frame invalidation theo frame ID** (`NvEncInvalidateRefFrames`) — không expose. Thay bằng model LTR-ack ở trên (tương đương về recovery, control surface khác: không nói "frame 47 hỏng" mà nói "refresh từ LTR đã ack").
- ❌ **Gradual/periodic intra-refresh** (rải I-block qua nhiều frame) — không có property public. Dùng LTR thay thế. (Verify lại header.)
- ❌ **Slice / sub-frame pipelining** — **xác nhận KHÔNG khả dụng** qua public API ([11](11-absolute-latency.md)): VideoToolbox output **frame-granular** (callback 1 lần/frame). Private symbols `NumberOfSlices`/`NumberOfSubFrameSections` tồn tại trong .tbd nhưng hành vi **unknown** → bỏ. Cơ chế song song duy nhất khả dụng là **inter-frame pipelining** (capture N+1 ‖ transmit/decode N).

---

## 2. Frame pacing & render pipeline (Moonlight `Pacer`)

### Render-on-arrival là mặc định cho LAN
Parsec "zero-buffered". Moonlight: "real-time không thể buffer vì thêm latency lớn." Trên LAN dây jitter sub-ms → jitter buffer gần như lỗ ròng. **KHÔNG thêm jitter buffer theo thời gian.**

### Kiến trúc Pacer (port sang Apple)
Moonlight `pacer.cpp`:
- **2 queue, 2 thread:** pacing queue (decoder đẩy vào) → vsync tick chuyển 1 frame sang render queue → render thread (priority HIGH) tiêu thụ. Vsync thread priority TIME_CRITICAL.
- **Vsync-gated dequeue:** mỗi nhịp refresh chuyển đúng 1 frame. Frame đến trễ vẫn được 1 cơ hội ở vsync hiện tại (slack 3ms) thay vì chờ cả frame.
- **Render-ahead tí hon:** cap `MAX_QUEUED_FRAMES = 3`, tổng outstanding = 5 (khớp surface pool decoder).
- **Frame-drop theo lịch sử (không ngây thơ):** giữ cửa sổ 500ms độ sâu queue. Nếu queue *liên tục* >1 → drop mạnh (target=1); nếu từng ≤1 → khoan dung (target=3). Tránh drop do burst thoáng qua.

**Map Apple:**
- Thay `IVsyncSource` (Windows `WaitForVBlank`) bằng **`CVDisplayLink`** (macOS) / **`CADisplayLink`** (iOS) làm vsync tick.
- Giữ nguyên thiết kế 2-queue + render thread riêng + cap 3 frame + heuristic drop theo cửa sổ (display-rate-agnostic).
- Nếu render bằng **`AVSampleBufferDisplayLayer`**: nó tự pace qua PTS → có thể dùng path render-on-arrival đơn giản. Nếu render **Metal**: tự build CVDisplayLink vsync source để có full pacer.

---

## 3. Receive path — không jitter buffer

Moonlight `RtpVideoQueue` + `VideoDepacketizer`:
- **Reassemble-and-submit-immediately.** "Buffer" duy nhất là FEC reassembly của *1 frame*, không phải delay theo thời gian.
- Đủ shard (kể cả recover qua FEC) → submit ngay, không chờ frame tương lai.
- **Out-of-order:** fast path giả định in-order; gói OOO đầu tiên chuyển sang slow insert + dedupe. OOO *trong* frame được hấp thụ; gói quá cũ bị reject.
- **Mất cả frame:** gói của frame mới đến trước khi frame hiện tại xong → tuyên bố frame hiện tại không cứu được, nhảy tới frame mới. **Không bao giờ stall chờ gói lạc.**
- Queue depacketizer→decoder bounded **≤15**; tràn → request recovery.

**Map Apple:** `NWConnection` UDP → tự viết lại FEC-block reassembler. **Không** thêm time-based jitter buffer cho LAN. Queue nhỏ bounded giữa depacketizer và `VTDecompressionSession`.

---

## 4. Loss recovery — FEC + speculative loss

### FEC (Reed-Solomon)
- Host: `parity = ceil(data * fec% / 100)`. Default **20%**, floor tối thiểu 2 parity shard.
- **Per-frame, host-driven:** FEC % nhúng trong header mỗi frame; client chỉ tuân theo.
- **Multi-FEC blocks:** frame lớn chia ≤4 block, mỗi block recover độc lập → 1 block cứu được trong khi block khác còn đang đến.
- **4K dùng FEC thấp hơn** (5%) để giảm overhead.

### Speculative loss detection (tối ưu latency)
Dự đoán frame mất **trước khi** frame kế đến — khi chứng minh được từ số shard rằng không thể recover. Bắn loss-notify ngay → tiết kiệm 1 frame-time. Tự sửa nếu đoán sai.

### Khuyến nghị LAN của ta (kết hợp doc [03](03-transport-protocol.md))
1. **LAN dây:** FEC thấp/không (0–10%), dựa LTR recovery + speculative loss. **Wi-Fi:** FEC 15–20%, multi-block.
2. Recovery ưu tiên **LTR refresh** (§1) → chỉ keyframe khi không còn LTR ack.
3. **Không retransmit cho video** (tốn 1 RTT → stutter). Retransmit chỉ cho input/control.

---

## 5. Encoder recipe (Sunshine, đã verify) → VideoToolbox

Công thức "ultra-low-latency" phổ quát:

| Khái niệm | Sunshine/NVENC | VideoToolbox |
|-----------|----------------|--------------|
| **Infinite GOP + on-demand IDR** | `gopLength = INFINITE`, IDR theo yêu cầu | `MaxKeyFrameInterval = INT_MAX` + `ForceKeyFrame` per-frame (KHÔNG keyframe định kỳ theo timer!) |
| **No B-frames** | `frameIntervalP=1` | `AllowFrameReordering = false` |
| **One-in-one-out** | `zeroReorderDelay=1` | low-latency mode tự lo |
| **CBR + VBV ~1 frame** | `rateControlMode=CBR`, `vbvBufferSize=bitrate/fps` | `ConstantBitRate` (hoặc `AverageBitRate` + `DataRateLimits` = [bytes, 1s]) |
| **Cap per-frame size** | — | `MaxAllowedFrameQP` (frame phức tạp không blow budget) |
| **No lookahead** | `enableLookahead=0` | `RealTime=true` tự lo |
| **VUI bitstream restriction** | `bitstreamRestrictionFlag=1` ("critical for low decode latency") | đảm bảo SPS mang flag → giảm decoder reorder buffer |
| **LTR recovery** | RFI/LTR ack | `EnableLTR` + ack workflow (§1) |

> **Sửa doc cũ:** [02](02-host-capture-encode.md) ghi `MaxKeyFrameInterval=120` — nên đổi thành **effectively infinite + on-demand IDR**. Keyframe định kỳ theo timer = spike latency vô ích.

---

## 6. Input latency (input-to-photon)

Moonlight `InputStream.c` — quy tắc platform-independent, **port trực tiếp**:
- **Batch mouse/pen motion cửa sổ 1ms** (`MOUSE_BATCHING_INTERVAL_MS=1`). Nghịch lý: batching *giảm* latency hiệu dụng vì chống gói xếp hàng trong stack reliable.
- **Button/key down/up KHÔNG BAO GIỜ batch** — gửi ngay.
- Relative-mouse delta coalesce; absolute-mouse giữ giá trị mới nhất.
- **Kênh input riêng, ưu tiên cao**, không để video head-of-line-block. Input nên **reliable** (mất phím tệ hơn mất frame video) nhưng trên path không block video.
- Timestamp + sequence mọi input → host order/dedupe + đo round-trip.

**Map Apple:** kênh `NWConnection` riêng cho input (xem [03 §3](03-transport-protocol.md)); replicate quy tắc 1ms-batch-motion / immediate-button y nguyên.

---

## 7. ⭐ Con trỏ chuột — vẽ client-side (latency win lớn, dễ bỏ sót)

Capture + re-encode con trỏ HW vào video stream → con trỏ trễ cả pipeline (cảm giác lag rõ).

**Fix:** **loại con trỏ khỏi video** (`SCStreamConfiguration.showsCursor = false` — ta đã set) + **vẽ con trỏ client-side** từ kênh input/cursor-position low-latency. Con trỏ cảm giác tức thì bất kể video latency. → Host gửi vị trí con trỏ qua control channel; client vẽ Metal overlay.

---

## 8. Adaptive bitrate — KHÔNG cần cho LAN

Moonlight comment thẳng: dynamic bitrate "nảy giữa min/max, không bao giờ settle" → **disabled**. Parsec thì drop bitrate khi mất gói (ưu tiên latency).

**Ta (LAN):** bỏ qua ABR closed-loop. Set bitrate 1 lần lúc khởi tạo (cap rộng vì LAN không nghẽn). Có làm thì chỉ: per-frame FEC report + connection-quality indicator + (tùy chọn) drop bitrate khi loss kéo dài qua `VTSessionSetProperty(AverageBitRate)`.

---

## 9. ⭐ Compositor/vsync tail — latency ẩn lớn nhất phía client

Render "on arrival" vẫn bị **vsync + window-server compositor** chặn → frame ngồi chờ tới 1 refresh interval. **Đây thường là nguồn latency lớn nhất bạn kiểm soát được ở client.**

Giảm thiểu:
- Path Metal overhead thấp, present sát vsync nhất có thể.
- Tránh layer compositing thừa.
- macOS: `CAMetalLayer.displaySyncEnabled = false` (present ngay khi GPU xong).
- iOS ProMotion 120Hz → worst-case wait còn 8.3ms.

---

## 10. Đo lường — instrument 6 stage

Stats overlay của Moonlight = spec đo lường. **Timestamp frame tại host** (lúc encode xong) nhúng vào frame header → tách được latency host vs network+client. Sáu segment cần đo:

1. **Host processing** (capture + encode) — từ timestamp host trong header.
2. **Network** = RTT + variance (đo qua reliable ping/ack).
3. **Reassembly** = lúc-frame-đủ − lúc-nhận-gói-đầu.
4. **Decode** = quanh call `VTDecompressionSessionDecodeFrame`.
5. **Queue/pacer delay** = thời gian trong pacing queue.
6. **Render (+vsync)** = quanh present.

Ground truth: **camera 240fps** quay thiết bị input + màn hình, đếm frame từ tác động → phản hồi (server/client delay vô hình với network tools).

---

## 11. Bài học nghịch lý (hard-won)

- **Keyframe để "sửa" loss làm tệ hơn** → dùng LTR (§1).
- **Jitter buffer "cho chắc" làm cảm giác tệ hơn** trên LAN (thêm latency cố định chống jitter không tồn tại).
- **VBR không cap cắn ngược:** scene phức tạp → frame khổng lồ → tràn link → spike latency cho *mọi thứ*. Phải cap (`MaxAllowedFrameQP`).
- **HEVC KHÔNG tự động latency thấp hơn H.264** — vài thiết bị decode H.264 nhanh hơn. Đừng giả định codec mới thắng về latency. (Đo, xem [09](09-codec-choice.md).)
- **Stadia "negative latency"** (ML dự đoán input) — vô dụng cho LAN (RTT ~1ms). **Bỏ qua.**

---

## 12. Cập nhật roadmap

Thêm vào các phase:

- **Phase 0:** verify symbol LTR (`EnableLTR`...) trên SDK đích; đo encode latency H.264 vs HEVC.
- **Phase 1:** Pacer (CVDisplayLink, 2-queue) hoặc AVSampleBufferDisplayLayer render-on-arrival; instrument 6-stage latency; timestamp host trong frame header.
- **Phase 1–2:** **LTR recovery loop** (ack client→host + `ForceLTRRefresh`) thay vì chỉ keyframe.
- **Phase 2:** input 1ms-batch / immediate-button; **con trỏ vẽ client-side**.
- **Phase 4:** temporal scalability, adaptive FEC Wi-Fi.

---

## Tham chiếu code đáng đọc
- **Moonlight** (client): `pacer.cpp`, `RtpVideoQueue.c`, `VideoDepacketizer.c`, `ControlStream.c`, `InputStream.c`.
- **Sunshine** (host): `video.cpp` (bảng encoder option per-vendor), `nvenc_base.cpp` (RFI/LTR/intra-refresh), `stream.cpp` (FEC + frame header).
- Là implementation đọc-được gần nhất với "Parsec mã nguồn mở".
