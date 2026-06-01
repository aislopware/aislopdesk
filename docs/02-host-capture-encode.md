# 02 — Host: Capture từng cửa sổ + Encode

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Pipeline phía host: **ScreenCaptureKit (capture 1 cửa sổ)** → **VideoToolbox (HW encode low-latency)** → NALU cho transport.

---

## 1. Capture với ScreenCaptureKit

### 1.1 Liệt kê cửa sổ

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false,
    onScreenWindowsOnly: false   // false: lấy cả cửa sổ minimized/offscreen
)
for window in content.windows {
    window.windowID                  // CGWindowID — định danh ổn định
    window.title                     // có thể nil
    window.frame                     // CGRect (CG screen space, top-left, points)
    window.isOnScreen
    window.owningApplication?.processID        // pid_t — cần cho input inject
    window.owningApplication?.bundleIdentifier
}
```

### 1.2 Filter 1 cửa sổ duy nhất

```swift
let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
```

Đặc tính của `desktopIndependentWindow` (WWDC22 session 10155):
- Output origin luôn `(0,0)`, không phải vị trí trên màn hình.
- **Không** gồm child/popup window — chỉ đúng `SCWindow` đã chọn.
- Capture được cả khi cửa sổ **bị che** hoặc nằm ngoài màn hình.
- Cửa sổ **minimized** → stream tạm dừng, tự resume khi restore.
- Cửa sổ **đóng** → stream dừng, gọi `stream(_:didStopWithError:)`.

### 1.3 Cấu hình stream

```swift
let config = SCStreamConfiguration()
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12 — rẻ nhất cho encode
config.width  = Int(window.frame.width)  * scaleFactor   // scaleFactor lấy từ NSScreen, KHÔNG hardcode 2
config.height = Int(window.frame.height) * scaleFactor
// CHỐT: cap ~24–30fps cho coding (KHÔNG 60/120 — đây không phải game-stream; [DECISIONS]/[12]/[17]).
// PHẢI set tường minh (macOS 15+ default âm thầm = 1/60) — ta còn muốn THẤP HƠN nữa (30).
config.minimumFrameInterval = CMTimeMake(value: 1, timescale: 30)   // cap ~30fps; idle-skip đưa về ~0 khi tĩnh
config.queueDepth = 3          // default thực là 8 (không phải 3); 2–3 cho latency thấp (xử lý release nhanh)
config.showsCursor = false   // loại con trỏ → vẽ client-side cho cảm giác tức thì (xem 10 §7)
```

> ⚠️ **scaleFactor:** không có API đọc scale trực tiếp từ `SCShareableContent`. Query từ `NSScreen` (match theo `displayID`). Hardcode `×2` sẽ sai trên màn hình ngoài non-Retina.

> ⚠️ **minimumFrameInterval & queueDepth (corrections từ [11](11-absolute-latency.md)):** macOS 15+ đổi default `minimumFrameInterval` thành `1/60` (im lặng, không có trong release notes) → **phải set tường minh**. Ta cap **~24–30fps** (không 60/120 — coding tool, không game-stream); ProMotion 120 **bỏ**. `queueDepth` default thực là **8**; không có sàn cứng 3 (số "3" là nhầm với CGDisplayStream cũ) → dùng **2–3** cho latency thấp nếu release IOSurface trong deadline `minimumFrameInterval × (queueDepth−1)`.

### 1.4 Nhận frame

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]],
          let info = attachments.first,
          (info[.status] as? SCStreamFrameStatus) == .complete   // bỏ qua .idle / .blank / .suspended
    else { return }

    let dirtyRects = info[.dirtyRects] as? [CGRect] ?? []   // chỉ vùng đổi → có thể tối ưu bitrate
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    encoder.encode(pixelBuffer: pixelBuffer, pts: pts)
}
```

**Tối ưu quan trọng:**
- `status == .idle` → không có pixel mới (cửa sổ tĩnh). **Bỏ encode hoàn toàn.** Khi capture cửa sổ coding (phần lớn tĩnh) ở 24–30fps cap, đa số frame là idle → tiết kiệm rất nhiều.
- `dirtyRects` → có thể chỉ encode vùng đổi (nâng cao, để sau).

### 1.5 Lifecycle

| Sự kiện | Hành vi |
|---------|---------|
| Resize | SCKit tự scale về `width`/`height`; stream tiếp tục. `contentRect`/`contentScale` trong attachments phản ánh geometry mới |
| Move sang display khác | Tiếp tục; `scaleFactor` có thể đổi nếu DPI khác |
| Minimize | Ngừng emit frame, tự resume |
| Đóng | `stream(_:didStopWithError:)` → phải `stopCapture()` + release |

Cập nhật động không cần restart:
```swift
try await stream.updateConfiguration(config)           // đổi fps/resolution
try await stream.updateContentFilter(newFilter)        // đổi cửa sổ capture
```

---

## 2. Encode với VideoToolbox

### 2.1 Tạo session low-latency (H.264)

```swift
// EnableLowLatencyRateControl là H.264-ONLY và phải đặt ở ENCODER SPEC lúc tạo session
let encoderSpec: [CFString: Any] = [
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
]
var session: VTCompressionSession?
VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault, width: w, height: h,
    codecType: kCMVideoCodecType_H264,
    encoderSpecification: encoderSpec as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)

VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // NO B-frames
// Infinite GOP + on-demand IDR — KHÔNG keyframe định kỳ theo timer (mỗi keyframe = spike latency vô ích).
// Recovery bằng LTR (xem 10-latency-optimization.md §1), chỉ force IDR khi không còn LTR ack.
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int.max as CFNumber)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) // LTR recovery — verify symbol trên SDK
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AverageBitRate, value: (8_000_000/8) as CFNumber) // bytes/s!
VTCompressionSessionPrepareToEncodeFrames(session!)

// Output qua closure (sạch hơn function pointer):
VTCompressionSessionSetOutputHandler(session!) { status, flags, sb in
    guard status == noErr, let sb else { return }
    self.handleEncoded(sb)
}
```

### 2.2 HEVC 10-bit (codec mặc định của ta)

> ✅ **Sửa giả định cũ:** trên **Apple Silicon**, `EnableLowLatencyRateControl` hỗ trợ **CẢ HEVC** (xác nhận qua FFmpeg `videotoolboxenc.c`: gate `H264 || (arm64 && HEVC)`). Chỉ **Intel Mac** mới giới hạn H.264. → Dùng low-latency mode cho HEVC luôn, nhưng **feature-detect lúc tạo session** (Apple chưa pin version trong doc).

```swift
let spec: [CFString: Any] = [
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true   // OK trên Apple Silicon — feature-detect
]
VTCompressionSessionCreate(... codecType: kCMVideoCodecType_HEVC ...)
// Main 10 chỉ có lợi nếu input cũng 10-bit (cần capture 10-bit = macOS 15 HDR preset, xem dưới).
// Mặc định 8-bit → dùng kVTProfileLevel_HEVC_Main_AutoLevel:
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
// CORRECTIONS từ [11]: HEVC mặc định AllowOpenGOP=true → PHẢI set false (IDR recovery độc lập decode):
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
// MaxFrameDelayCount=0 → ép one-in-one-out (emit đồng bộ). KHÔNG phải "no-limit" (đó là -1):
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
// Lưu ý: low-latency mode yêu cầu bitrate tường minh (không ABR tự động) — hợp LAN.
```

HEVC HW encode luôn có trên Apple Silicon & Intel có T2.

> ⚠️ **CORRECTION 10-bit pixel format (Z1, từ [11](11-absolute-latency.md)):** `SCStreamConfiguration` **KHÔNG** chấp nhận `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`) — format này không có trong danh sách supported. 10-bit YCbCr được liệt kê là `'xf44'` (4:4:4 full-range). Cho **10-bit HDR capture** dùng `SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)` — yêu cầu **macOS 15.0** (không phải 14.0). → Pipeline mặc định nên dùng **8-bit `'420v'`** (`420YpCbCr8BiPlanarVideoRange`) cho zero-copy; 10-bit là tùy chọn HDR cần macOS 15.

> ⚠️ **Chroma 4:2:0 là trần chất lượng text** — Apple HW encode **không có 4:4:4** (cả H.264 lẫn HEVC). Đổi codec không sửa được. Giảm thiểu: 10-bit (nếu macOS 15+) + capture resolution cao. Chi tiết & lựa chọn ở [09-codec-choice.md](09-codec-choice.md).

### 2.3 Encode 1 frame + force keyframe

```swift
var props: CFDictionary?
if forceKeyframe {   // khi client gửi request-keyframe (mất gói / viewer mới join)
    props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
}
VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
    presentationTimeStamp: pts, duration: .invalid,
    frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: &flags)
```

### 2.4 Trích NALU + parameter sets

VideoToolbox trả **AVCC** (4-byte length prefix). Cần convert sang **Annex-B** (`00 00 00 01`) hoặc giữ AVCC tùy protocol — ta sẽ thống nhất ở [03](03-transport-protocol.md).

```swift
func handleEncoded(_ sb: CMSampleBuffer) {
    let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [CFDictionary]
    let isKey = !CFDictionaryContainsKey(attach?.first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    if isKey {
        // Trích parameter sets, gửi TRƯỚC IDR (và mỗi khi đổi)
        // H.264: SPS(0)+PPS(1) qua CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        // HEVC : VPS(0)+SPS(1)+PPS(2) qua CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
    }
    // Duyệt CMBlockBuffer, đọc length prefix, tách từng NALU
}
```

### 2.5 Bảng property low-latency

| Key | Giá trị | Ghi chú |
|-----|---------|---------|
| `EnableLowLatencyRateControl` (encoder spec) | `true` | H.264 documented; **HEVC empirical trên Apple Silicon** — feature-detect runtime |
| `RealTime` | `true` | Ưu tiên latency hơn chất lượng |
| `AllowFrameReordering` | `false` | Tắt B-frames → "one in, one out" |
| `AllowOpenGOP` | `false` | **HEVC mặc định `true` → PHẢI set false** (IDR độc lập decode) |
| `MaxFrameDelayCount` | `0` | Ép emit đồng bộ one-in-one-out (KHÔNG phải "no-limit"; no-limit là `-1`) |
| `MaxKeyFrameInterval` | `Int.max` | Infinite GOP + on-demand IDR/LTR (KHÔNG keyframe định kỳ theo timer) |
| `AverageBitRate` | bytes/s | **Lưu ý: bytes, không phải bits** |
| `DataRateLimits` | `[maxBytes, seconds]` | Trần cứng theo cửa sổ trượt |
| `MaxAllowedFrameQP` | vd 40 | Cap kích thước frame phức tạp (tránh spike latency toàn cục) |
| `ForceKeyFrame` (per-frame) | `true` | Cho recovery mất gói |

---

## 3. Gotchas (từ research)

- `EnableLowLatencyRateControl`: trên **Apple Silicon** hỗ trợ **cả H.264 lẫn HEVC**; trên **Intel Mac** chỉ H.264. **Feature-detect lúc tạo session**, đừng gate theo version OS (Apple chưa pin version cho HEVC).
- Low-latency mode yêu cầu **bitrate tường minh** (không dùng ABR tự động).
- Query `UsingHardwareAcceleratedVideoEncoder` ở low-latency mode trả lỗi `-12900` — đây là quirk đã biết, HW encoder vẫn chạy.
- `AverageBitRate` tính bằng **bytes/giây**, không phải bits.
- VideoToolbox luôn xuất **AVCC**; phải tự convert nếu cần Annex-B.
- Parameter sets phải gửi **trước** IDR đầu tiên và **lặp lại khi đổi** (vd resolution change). Trên LAN lossy nên kèm parameter sets vào **mỗi** keyframe để client mới/recovery decode được.

## 4. Việc cho Phase 0 spike

- [ ] Capture 1 cửa sổ → dump fps thực tế, xác nhận idle-frame skipping hoạt động.
- [ ] Encode HEVC low-latency → **đo encode latency** trên máy đích.
- [ ] Verify trích được parameter sets + NALU, ghép lại decode được (loop nội bộ host).
