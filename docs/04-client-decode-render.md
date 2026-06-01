# 04 — Client: Decode + Render

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Chạy trên **cả macOS và iOS/iPadOS** (share code). Pipeline: NALU nhận được → `VTDecompressionSession` → `CVPixelBuffer` → render Metal.

---

## 1. Dựng CMFormatDescription từ parameter sets

Phải có `CMVideoFormatDescription` trước khi tạo decode session. Build 1 lần từ parameter sets (strip start code Annex-B trước khi truyền vào).

```swift
// H.264 — SPS + PPS
CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: kCFAllocatorDefault, parameterSetCount: 2,
    parameterSets: ptrs, parameterSetSizes: sizes,
    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)

// HEVC — VPS + SPS + PPS
CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    allocator: kCFAllocatorDefault, parameterSetCount: 3,
    parameterSets: ptrs, parameterSetSizes: sizes,
    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
```

> ⚠️ **Pointer lifetime:** `Data.withUnsafeBytes` có scope. Phải giữ `Data` sống qua call (nest `withUnsafeBytes` trực tiếp hoặc `withExtendedLifetime`), nếu không crash khó tái hiện.

Khi parameter sets đổi (đổi resolution) → build `CMVideoFormatDescription` mới + session mới. Check `VTDecompressionSessionCanAcceptFormatDescription` trước khi teardown.

---

## 2. Ghép NALU → CMSampleBuffer (AVCC)

VideoToolbox cần **AVCC** (length-prefix), không phải Annex-B. Nếu transport gửi Annex-B thì convert:

```swift
func annexBToAVCC(_ body: Data) -> Data {
    var lenBE = UInt32(body.count).bigEndian
    var out = Data(bytes: &lenBE, count: 4); out.append(body); return out
}
```

> ⚠️ **Multi-slice:** 1 frame có thể nhiều slice NALU. Gộp **tất cả** vào 1 `CMBlockBuffer` (`[len][nalu][len][nalu]...`), tạo 1 `CMSampleBuffer` với `sampleCount = 1`. Tách thành nhiều sample → render nửa frame, artifact.

```swift
var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
    formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
```

PTS: truyền PTS gốc của encoder kèm packet (flag `.valid` bắt buộc), hoặc dùng `CMClockGetTime(CMClockGetHostTimeClock())` lúc nhận.

---

## 3. VTDecompressionSession

```swift
var spec: [CFString: Any] = [:]
#if os(macOS)
spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true   // iOS luôn HW
#endif
let bufAttrs: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12 native
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary   // IOSurface → zero-copy Metal
]
VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
    decoderSpecification: spec as CFDictionary, imageBufferAttributes: bufAttrs as CFDictionary,
    outputCallback: &cb, decompressionSessionOut: &session)
VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
```

Decode (dùng output handler closure cho gọn):

```swift
VTDecompressionSessionDecodeFrameWithOutputHandler(
    session, sampleBuffer: sb,
    flags: [.enableAsynchronousDecompression],   // KHÔNG enableTemporalProcessing (vì không B-frames)
    infoFlagsOut: nil
) { status, info, imageBuffer, pts, _ in
    guard status == noErr, let px = imageBuffer else { return }
    self.renderer.enqueue(px, pts: pts)   // return NHANH — callback block decoder
}
```

**Latency levers:** `RealTime=true`, bỏ `enableTemporalProcessing` (bỏ reorder buffer), NV12 native + IOSurface (zero-copy), không làm việc nặng trong callback.

### Xử lý lỗi decode

VideoToolbox không có API "request keyframe" — phải báo ngược về **host** qua control channel.

| Mã lỗi | Ý nghĩa | Hành động |
|--------|---------|-----------|
| `-12909` BadData | Bitstream hỏng | recreate session + request keyframe |
| `-12911` Malfunction | HW fault | recreate session |
| `-12903` InvalidSession | Session chết | recreate + request keyframe |
| `infoFlags` chứa `.frameDropped` | Decoder quá tải drop | request keyframe |

> iOS strict hơn macOS về bitstream corruption (macOS thường tự sửa). Handler phải robust cả hai.

---

## 4. Render — 2 lựa chọn

### Option A — CAMetalLayer + CVMetalTextureCache (latency thấp nhất, **khuyến nghị**)

`CVPixelBuffer` từ VideoToolbox backed bởi IOSurface → `CVMetalTextureCacheCreateTextureFromImage` map sang `MTLTexture` **zero-copy**.

```swift
metalLayer.device = device
metalLayer.pixelFormat = .bgra8Unorm
metalLayer.framebufferOnly = true
#if os(macOS)
metalLayer.displaySyncEnabled = false   // present ngay khi GPU xong, không chờ vsync (giảm tới 1 refresh)
#endif
metalLayer.maximumDrawableCount = 2     // 2 = latency thấp nhất (HỢP LỆ trên iOS — claim "không nên" đã refuted); xử lý nextDrawable nil

// Mỗi frame: tạo 2 texture (Y plane .r8Unorm, UV plane .rg8Unorm) từ NV12 → shader YCbCr→RGB → present
```

Shader fragment NV12→RGB (BT.601/709) — xem snippet trong research. iOS không có `displaySyncEnabled` (luôn present ở vsync; ProMotion 120Hz giúp giảm worst-case còn 8.3ms).

### Option B — AVSampleBufferDisplayLayer (đơn giản nhất)

Nhận `CMSampleBuffer` trực tiếp (kể cả compressed — layer tự decode). Bắt buộc cho Picture-in-Picture trên iOS.

```swift
// Set controlTimebase TRƯỚC khi enqueue, dùng host clock để present ngay:
var tb: CMTimebase?
CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
CMTimebaseSetTime(tb!, time: CMClockGetTime(CMClockGetHostTimeClock())); CMTimebaseSetRate(tb!, rate: 1.0)
displayLayer.controlTimebase = tb
displayLayer.enqueue(sampleBuffer)   // hiển thị khi PTS <= timebase
// poll displayLayer.status == .failed → flush()
```

**So sánh:**

| | CAMetalLayer | AVSampleBufferDisplayLayer |
|--|--------------|----------------------------|
| Latency | Thấp nhất | +1–2 frame buffering (Moonlight-QT report) |
| Độ phức tạp | Cao (shader, texture cache) | Rất thấp (1 call) |
| PiP (iOS) | Không | Có |
| Kiểm soát màu/effect | Toàn quyền | Hạn chế |

**Quyết định:** dùng **AVSampleBufferDisplayLayer cho Phase 3 (lên hình nhanh)**, chuyển sang **Metal khi cần tối ưu latency** hoặc đo thấy chênh đáng kể. Bọc behind protocol `VideoRenderer` để hoán đổi.

---

## 4b. Frame pacing — render-on-arrival + Pacer

Trên LAN, **mặc định render-on-arrival, KHÔNG jitter buffer** (xem [10 §2–3](10-latency-optimization.md)). Nếu thấy judder do lệch pha vsync, thêm Pacer kiểu Moonlight:
- **2-queue + render thread riêng**, vsync tick bằng **`CVDisplayLink`** (macOS) / **`CADisplayLink`** (iOS) — thay cho `WaitForVBlank` của Windows.
- Cap render-ahead **3 frame**; frame-drop theo lịch sử cửa sổ 500ms (drop mạnh nếu queue *liên tục* >1).
- `AVSampleBufferDisplayLayer` tự pace qua PTS → path đơn giản; render Metal thì tự dựng CVDisplayLink source.

**CAMetalDisplayLink (macOS 14+/iOS 17+):** vsync tick chính xác; set `preferredFrameLatency = 1.0` (chỉ chấp nhận 1.0 hoặc 2.0; default iOS là 2 → set 1 tiết kiệm ~8–16 ms). **KHÔNG** giới hạn Apple Silicon (chạy mọi Mac macOS 14+). Render frame mới nhất ngay trước `targetTimestamp` (beam-racing).

**LTR ack:** client phải báo frame nào nhận được về host (qua control channel) để host lái LTR recovery — xem [10 §1](10-latency-optimization.md).

> ⚠️ **VRR/Adaptive-sync cần FULLSCREEN (từ [11](11-absolute-latency.md)):** adaptive-sync scheduling (`presentDrawable:afterMinimumDuration:`) yêu cầu cửa sổ fullscreen → app client **windowed** KHÔNG hưởng lợi VRR. Mâu thuẫn với mô hình "1 cửa sổ"; cân nhắc chế độ fullscreen tùy chọn ở client nếu cần. Trên macOS đo `macOS 26 Tahoe` kỹ — có report decode/present latency regression với CAMetalDisplayLink.

## 5. Khác biệt iOS vs macOS

| | iOS/iPadOS | macOS |
|--|-----------|-------|
| HW decode | Luôn HW, không fallback | Có software fallback; HW opt-in |
| `displaySyncEnabled` | Không có | Có (set false giảm latency) |
| Bitstream tolerance | Strict | Lenient |
| ProMotion 120Hz | iPhone 13 Pro+, iPad Pro M1+ | MacBook Pro/iMac 2023+ |
| Simulator | Không HW decode (trừ M1+ Mac chạy sim) | HW đầy đủ |

Capability check: `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`.

---

## 6. Việc cho Phase 1 & 3

- [ ] (P1, macOS) Decode + render frame nhận từ host → lên hình.
- [ ] Render behind protocol `VideoRenderer` (Metal + AVSampleBuffer impl).
- [ ] (P3, iOS) Build `PaneCastClientKit` + render cho iOS, test trên device thật (Simulator không HW decode).
- [ ] Đo glass-to-glass latency (timestamp host → hiển thị client).
