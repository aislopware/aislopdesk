# 01 — Kiến trúc tổng thể

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Cập nhật kiến trúc (re-scope):** dự án giờ là **hybrid** — terminal đi **PTY text-path** (như SSH/mosh, render bằng libghostty), chỉ **GUI window** đi video. Doc này mô tả **GUI video-path**; kiến trúc tổng thể mới + insight (terminal né input-injection) ở **[12-coding-profile.md](12-coding-profile.md)** (đọc trước).

## 1. Bức tranh lớn

```
┌─────────────────────────── HOST (macOS) ───────────────────────────┐
│                                                                     │
│  ┌──────────────┐   CVPixelBuffer   ┌──────────────┐  NALU+PTS     │
│  │ ScreenCapture │ ────────────────▶ │ VideoToolbox │ ───────────┐  │
│  │  Kit (1 win)  │                   │  HW Encoder  │            │  │
│  └──────────────┘                    └──────────────┘            │  │
│         ▲                                                         ▼  │
│         │ raise + frame                              ┌──────────────┐│
│  ┌──────────────┐    CGEvent / AX     ┌──────────┐   │ Packetizer / ││
│  │ Window/Input  │ ◀──────────────────│ Control  │◀──│  Transport   ││
│  │  Controller   │                    │ Receiver │   │ (Network.fw) ││
│  └──────────────┘                     └──────────┘   └──────────────┘│
└──────────────────────────────────────────────────────────│─────────┘
                                                            │ LAN (UDP/QUIC)
                       Bonjour discovery ◀──────────────────┤
                                                            │
┌──────────────────── CLIENT (macOS / iOS / iPadOS) ────────▼─────────┐
│  ┌──────────────┐    NALU      ┌──────────────┐  CVPixelBuffer       │
│  │ Transport /   │ ───────────▶ │ VideoToolbox │ ──────────────┐     │
│  │ Reassembler   │              │  HW Decoder  │               ▼     │
│  └──────────────┘               └──────────────┘     ┌──────────────┐│
│         ▲                                            │ Metal /      ││
│  ┌──────────────┐   input events (reliable)          │ AVSampleBuf  ││
│  │ Input Capture │ ──────────────────────────────────│ DisplayLayer ││
│  │ (mouse/touch) │                                    └──────────────┘│
│  └──────────────┘                                                     │
└───────────────────────────────────────────────────────────────────────┘
```

## 2. Thành phần & trách nhiệm

### Host (macOS)
| Module | Trách nhiệm | API chính |
|--------|-------------|-----------|
| **Window Enumerator** | Liệt kê cửa sổ, cho user chọn | `SCShareableContent`, `SCWindow` |
| **Capturer** | Capture 1 cửa sổ → `CVPixelBuffer` | `SCStream` + `SCContentFilter(desktopIndependentWindow:)` |
| **Encoder** | HW encode H.264/HEVC low-latency | `VTCompressionSession` |
| **Packetizer + Transport** | Fragment NALU → UDP datagram, gửi | `NWConnection`, `NWListener` |
| **Control Receiver** | Nhận input event qua kênh reliable | `NWConnection` (TCP/QUIC stream) |
| **Window/Input Controller** | Raise cửa sổ + inject mouse/key | `AXUIElement`, `CGEvent`, `CGEventPostToPid` |

### Client (macOS / iOS / iPadOS) — **share code tối đa**
| Module | Trách nhiệm | API chính |
|--------|-------------|-----------|
| **Discovery** | Tìm host trên LAN | `NWBrowser` (Bonjour) |
| **Transport + Reassembler** | Nhận datagram, ghép lại frame | `NWConnection` |
| **Decoder** | HW decode → `CVPixelBuffer` | `VTDecompressionSession` |
| **Renderer** | Hiển thị low-latency | `CAMetalLayer` hoặc `AVSampleBufferDisplayLayer` |
| **Input Capture** | Bắt chuột/phím/touch → gửi host | NSEvent / UIKit gesture |

## 3. Cấu trúc package (Swift Package Manager)

```
PaneCast/
├── Package.swift
├── Sources/
│   ├── PaneCastCore/          # SHARED — không phụ thuộc platform
│   │   ├── Protocol/          # packet format, message types, codec enum
│   │   ├── Transport/         # NWConnection wrappers, Bonjour, packetizer/reassembler
│   │   └── Codec/             # VideoToolbox encode + decode wrappers
│   ├── PaneCastHost/          # macOS only — capture, input inject, window control
│   ├── PaneCastClientKit/     # shared client logic (decode pipeline, input mapping)
│   └── PaneCastRender/        # Metal renderer (macOS + iOS)
├── Apps/
│   ├── HostApp-macOS/         # AppKit/SwiftUI host UI + window picker
│   ├── ClientApp-macOS/       # viewer UI
│   └── ClientApp-iOS/         # viewer UI (touch)
└── docs/
```

**Nguyên tắc:** `PaneCastCore` build được cho cả macOS lẫn iOS (decode + transport chạy 2 nơi). `PaneCastHost` chỉ macOS (capture + input chỉ có ở host). Render dùng Metal share được cả hai.

## 4. Data flow một frame (happy path)

1. Cửa sổ trên host đổi pixel → ScreenCaptureKit emit `CMSampleBuffer` (status `.complete`).
2. Lấy `CVPixelBuffer` + PTS → đẩy vào `VTCompressionSession`.
3. Encoder trả NALU (AVCC). Nếu là keyframe → kèm parameter sets (SPS/PPS hoặc VPS/SPS/PPS).
4. Packetizer cắt frame thành các datagram ≤1200 byte, gắn header (frameID, fragIndex, fragCount, flags, streamSeq).
5. Gửi qua `NWConnection` UDP (`serviceClass = .interactiveVideo`).
6. Client nhận, ghép fragment theo frameID; nếu thiếu fragment → **bỏ frame + yêu cầu keyframe** qua kênh control.
7. Ghép NALU → `CMSampleBuffer` (AVCC) → `VTDecompressionSession`.
8. Decoder trả `CVPixelBuffer` (NV12, IOSurface-backed).
9. Renderer: zero-copy `CVMetalTextureCache` → shader YCbCr→RGB → present.

## 5. Latency Budget

> ⚠️ **Chỉ áp dụng GUI video-path.** Terminal path latency = network RTT (~1–5ms LAN-direct), không vsync/encode. GUI path target nới lên **40–80ms** (coding); **120fps/ProMotion bỏ**. Bảng dưới là số cũ (30–50ms/60fps) — giữ làm reference. Xem [12 §latency](12-coding-profile.md), [00](00-overview.md).

Mục tiêu **glass-to-glass ~30–50ms** trên LAN có dây, 60fps (frame = 16.6ms).

| Giai đoạn | Ước tính | Ghi chú |
|-----------|----------|---------|
| Capture (SCKit, chờ frame) | ~8–16ms | tối đa 1 frame interval |
| HW encode (Apple Silicon, low-latency) | ~1–5ms | đo lại ở Phase 0 |
| Packetize + gửi | <1ms | |
| Mạng LAN (có dây) | ~0.2–2ms | Wi-Fi có thể 2–10ms + jitter |
| Reassemble | <1ms | |
| HW decode | ~2–8ms | |
| Render + present | ~8–16ms | giảm bằng `displaySyncEnabled=false` (macOS), ProMotion 120Hz |
| **Tổng (LAN dây, 60fps)** | **~30–50ms** | |

**Đòn bẩy latency quan trọng nhất:**
- Tắt B-frames (`AllowFrameReordering = false`) ở cả encode lẫn decode (bỏ `enableTemporalProcessing`).
- `RealTime = true` ở cả `VTCompressionSession` và `VTDecompressionSession`.
- `serviceClass = .interactiveVideo` trên `NWParameters`.
- Bỏ jitter buffer lớn: lỗi → drop frame + request keyframe, KHÔNG retransmit.
- Render: `CAMetalLayer.displaySyncEnabled = false` (macOS), `maximumDrawableCount = 2`.

## 6. Tech stack tóm tắt

| Tầng | Công nghệ | Min OS |
|------|-----------|--------|
| Capture | ScreenCaptureKit | macOS 13 (target 14+) |
| Encode/Decode | VideoToolbox (HEVC ưu tiên, H.264 fallback) | — |
| Discovery | Bonjour qua `NWListener`/`NWBrowser` | — |
| Transport | `NWConnection` UDP (LAN) hoặc QUIC datagram (Wi-Fi) | UDP: iOS 12 / QUIC: iOS 16 |
| Control channel | TCP `noDelay` hoặc QUIC reliable stream | — |
| Render | Metal (`CAMetalLayer` + `CVMetalTextureCache`) | macOS + iOS |
| Input inject | CGEvent + Accessibility | macOS 14+ |

> **Codec mặc định:** **HEVC Main 10 (10-bit), 4:2:0, low-latency rate control**. H.264 làm fallback. Trên **Apple Silicon**, low-latency rate control hỗ trợ **cả HEVC** (không chỉ H.264). AV1 = decode-only trên Apple (không có HW encode) → không dùng để encode. Trần chất lượng thật cho text là **chroma 4:2:0** (Apple HW không có 4:4:4) → giảm thiểu bằng 10-bit + capture resolution cao. Phân tích đầy đủ ở [09-codec-choice.md](09-codec-choice.md).
