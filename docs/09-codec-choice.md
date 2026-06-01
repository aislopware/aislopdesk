# 09 — Lựa chọn Codec

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Re-scope (hybrid):** content text-heavy (terminal/code) đi **PTY path — KHÔNG qua codec, nét tuyệt đối** ([12](12-coding-profile.md)). Video chỉ cho **GUI window**, nơi **HEVC 4:2:0 8-bit quality-mode (`Quality≈0.6`, Apple Silicon) là đủ**. → Bài toán **4:4:4 / text-crispness dưới đây KHÔNG còn là vấn đề trung tâm** (drop "software 4:4:4 tier"; 10-bit hạ xuống optional). Giữ phần dưới làm bối cảnh codec cho GUI path.

> Nghiên cứu chuyên sâu cho bối cảnh: **Apple-only, LAN, low-latency, content là screen/text** (không phải video camera). Yếu tố quyết định: **hardware support trên Apple** + đặc thù screen content.

## TL;DR

**Mặc định (GUI video-path): HEVC Main 8-bit 4:2:0 + constant-quality (Quality≈0.6, Apple Silicon), no B-frames.** 10-bit = optional; low-latency RC = optional/uncertain (`AllowFrameReordering=false` đã đủ). H.264 fallback. **4:4:4 dropped** (Apple HW không encode; text crisp đã đi PTY path). AV1/VVC không HW-encode → loại.

Hai điều cần nhớ:
1. Giả định "low-latency mode chỉ H.264" **SAI trên Apple Silicon** — HEVC cũng được → không còn lý do chọn H.264 vì latency.
2. Trần chất lượng text thật là **chroma 4:2:0** (Apple HW không có 4:4:4), không phải việc chọn H.264/HEVC.

---

## 1. H.264 vs HEVC cho screen content

| Tiêu chí | Kết quả |
|----------|---------|
| **Bitrate** | HEVC đạt độ nét text tương đương ở **~60–70% bitrate** của H.264. Block lớn hơn (64×64) nén tốt vùng phẳng; 35 intra mode (vs 9) bám cạnh UI sắc tốt hơn |
| **Text legibility** | HEVC: intra prediction + SAO filter → ít ringing quanh glyph |
| **Latency/frame (Apple Silicon)** | Chênh lệch **không đáng kể** — cả hai chạy Media Engine. "HEVC chậm" là chuyện phần cứng PC đa hãng (cảnh báo của Parsec), không áp dụng cho Apple |
| **Low-latency rate control** | ✅ **Cả hai trên Apple Silicon** (Intel Mac: chỉ H.264) |

### Sửa giả định quan trọng

Apple WWDC21 nói "low-latency mode chỉ H.264" — **lỗi thời**. Bằng chứng: FFmpeg `videotoolboxenc.c` gate điều kiện:

```c
if ((flags & AV_CODEC_FLAG_LOW_DELAY) &&
    (codec_id == AV_CODEC_ID_H264 ||
     (TARGET_CPU_ARM64 && codec_id == AV_CODEC_ID_HEVC))) {
    EnableLowLatencyRateControl = true;
}
```

Commit upstream: "enabled only for H.264 on Intel Macs, but can be used with both H.264 and HEVC on Apple Silicon." → **Feature-detect lúc runtime** (Apple chưa pin version trong doc chính thức).

---

## 2. Chroma 4:2:0 — trần chất lượng thật cho text

Đây quan trọng **hơn** việc chọn H.264/HEVC:

- **4:2:0 làm nhòe text màu**: chữ đỏ trên nền đen, code syntax-highlight → viền/bleeding màu. Parsec: "4:2:0 falls apart on UI/text vốn dựa vào RGB subpixel rendering."
- **Apple HW encode KHÔNG có 4:4:4** — cả H.264 lẫn HEVC qua VideoToolbox đều 4:2:0 (HEVC thêm 10-bit; 4:2:2 chỉ cho path kiểu ProRes, không phải Main 4:4:4 streaming). **Đổi codec không sửa được.**
- Parsec/Moonlight đều coi **4:4:4 là đòn bẩy số 1** cho độ nét UI và chỉ bật được nhờ HW encode 4:4:4 của Intel/Nvidia — **thứ Apple không có**.

### Đòn bẩy khả dụng trên Apple (xếp ưu tiên)

1. **HEVC 10-bit (Main 10):** giảm banding gradient/vùng phẳng — **optional** (mặc định 8-bit; chỉ bật nếu cần).
2. **Capture resolution cao hơn** (retina full scale): mỗi glyph có nhiều pixel chroma hơn → 4:2:0 đỡ hại.

---

## 3. Các codec "ngon hơn" — vì sao loại

| Codec | Encode trên Apple | Decode | Kết luận |
|-------|-------------------|--------|----------|
| **AV1** | ❌ **Không có HW encode trên bất kỳ chip nào** (kể cả M5 Max, 2026). Apple newsroom liệt kê AV1 chỉ ở "decode" | ✅ A17 Pro, M3+ | Software AV1 encode phá latency/pin/nhiệt → **loại cho host**. Decode không cần (ta không nhận stream AV1 bên thứ 3) |
| **VVC/H.266** | ❌ Không có gì | ❌ | Không `kCMVideoCodecType`, không HW. Apple đặt cược AV1 (royalty-free) thay VVC → **loại** |
| **ProRes** | ✅ Mac M1 Pro/Max, M3+ (base M3/M4 có 1 engine) | ✅ phổ biến | Intra-only → latency cực thấp, robust với mất gói. **Nhưng bitrate chục–trăm Mbps** → xem §4 |

> ⚠️ Một blog tổng hợp nói "M5 Pro/Max thêm AV1 hardware encode" — **SAI**, mâu thuẫn với Apple newsroom (3/2026) và Wikipedia (đều ghi AV1 = decode-only). Tin Apple.

---

## 4. ProRes — khi nào hợp lý?

- **Hợp:** LAN **có dây multi-Gbps** (vd 10GbE) + Mac host có ProRes encode engine, cần **chất lượng visually-lossless** + latency encode tối thiểu (intra-only). Use case: review production, color-critical.
- **Không hợp (mặc định):** ProRes Proxy/LT vẫn gấp 10–50× bitrate của HEVC low-latency. Trên Wi-Fi / 1GbE → bão hòa link → **tăng** latency qua network buffering.
- **Kết luận:** opt-in "high-quality wired mode", gate theo (a) host có ProRes engine, (b) link multi-Gbps. Mặc định vẫn HEVC.

---

## 5. Các streamer thực tế dùng gì (và vì sao)

| Streamer | Codec | Ghi chú |
|----------|-------|---------|
| **Parsec** | Default H.264, có H.265 + AV1; "Prefer 4:4:4" ở tier trả phí | H.264-for-latency là kết luận **cross-vendor PC**, KHÔNG áp dụng cho Apple-only |
| **Moonlight/Sunshine** | H.264, HEVC, AV1; thêm **YUV 4:4:4** (2024) cho text — ưu tiên **HEVC 4:4:4** vì "AV1 4:4:4 hardware là con số 0" | Câu chuyện hệ PC; Apple ngược lại: có decode 4:4:4 nhưng không encode |
| **NVIDIA GameStream/GFN** | H.264 → HEVC → AV1 (Ada) | Game content, không phải text-first |
| **Steam Remote Play** | H.264 default, HEVC nơi hỗ trợ | Tối đa device reach |

**Pattern:** ai phục vụ **text/desktop** đều **muốn 4:4:4** và chọn **HEVC** là nấc đạt được đầu tiên. Default H.264 của họ do **ubiquity phần cứng đa hãng** — ràng buộc **ta không có** (Apple-only).

---

## 6. Bitrate ballpark — 4K, mostly-text, ~30fps cap, LAN

Screen content bursty: gần 0 khi tĩnh, spike lớn khi redraw/scroll toàn màn. **Budget cho spike, không cho average.** LAN không nghẽn băng thông → bias cao cho text nét.

| Codec (VideoToolbox, 4:2:0) | Cap "visually clean" | Setting LAN thoải mái |
|-----------------------------|----------------------|----------------------|
| **H.264** | ~50–80 Mbps | 60 Mbps |
| **HEVC (8/10-bit)** | ~30–50 Mbps | 40 Mbps |

Rule of thumb: **HEVC cho độ nét text tương đương ở ~60–70% bitrate H.264.** Trên gigabit LAN: set cap rộng (HEVC 40–50, H.264 60–80 Mbps), GOP dài + force IDR khi detect scene-change, để rate controller spike khi đổi toàn màn. Average sẽ thấp hơn cap nhiều vì màn hình phần lớn tĩnh.

---

## 7. Quyết định cuối + việc cần làm

**Mặc định:** HEVC Main **8-bit** 4:2:0 + **constant-quality** (`Quality≈0.6`, Apple Silicon); 10-bit optional; `EnableLowLatencyRateControl` optional/feature-detect; `RealTime=true`, `AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, GOP dài + force IDR/LTR. (4:4:4 dropped — text qua PTY path.)

**Fallback H.264 khi:** client cũ / non-Apple / browser decode yếu; host là **Intel Mac** (low-latency chỉ H.264); cần tương thích tối đa.

**ProRes:** opt-in wired-high-quality, gate theo host + bandwidth.

### Việc cho Phase 0
- [ ] Probe `EnableLowLatencyRateControl` với HEVC trên máy đích (`VTCopySupportedPropertyDictionaryForEncoder` / thử tạo session) — xác nhận chạy.
- [ ] Thử HEVC 8-bit vs **10-bit** trên text màu → đánh giá fringing thực tế.
- [ ] Đo encode latency H.264 vs HEVC trên cùng máy (xác nhận chênh lệch nhỏ).
- [ ] Test capture 4:2:0 ở resolution cao xem text có chấp nhận được không (trước khi nghĩ tới software 4:4:4).
