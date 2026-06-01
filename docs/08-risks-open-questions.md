# 08 — Rủi ro & Câu hỏi mở

> **STATUS: SUPERSEDED** — đã thay; xem [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

## 1. Rủi ro kỹ thuật (xếp theo mức độ)

> ⚠️ **R1/R2 (input injection) CHỈ áp dụng cho GUI video-path.** Terminal đi PTY text-path né hoàn toàn (input = byte → PTY stdin) — xem [12](12-coding-profile.md). Với profile coding (terminal-first), R1/R2 không còn là rủi ro chặn dự án.

### 🔴 R1 — Window-targeted input không hoàn hảo trên macOS *(chỉ GUI path)*
- **Vấn đề:** không inject mouse tin cậy vào cửa sổ nền; không có API map `AXUIElement`↔`CGWindowID`; matching cửa sổ là heuristic.
- **Ảnh hưởng:** click có thể trúng nhầm cửa sổ; matching sai khi nhiều cửa sổ cùng title.
- **Giảm thiểu:** activate-then-control + ưu tiên AX action; verify ở Phase 0.4–0.5. Code phòng thủ khi match.
- **Fallback nếu fail:** lùi về điều khiển **toàn app** (raise app, không cố raise đúng 1 cửa sổ), hoặc điều khiển **cả desktop** như chế độ phụ.

### 🔴 R2 — Cooperative activation macOS 14+ từ chối activate từ sự kiện mạng
- **Vấn đề:** `activate()` advisory, hay fail khi trigger bởi network/timer — đúng case remote control.
- **Giảm thiểu:** kết hợp `AXRaise` (tự reorder dù app activation throttle) + thử `activateIgnoringOtherApps:` (deprecated nhưng mạnh hơn).
- **Cần:** **đo thực tế ở Phase 0.6** trên đúng version macOS sẽ ship (14/15/26).

### 🟡 R3 — Latency Wi-Fi cao/bursty
- **Vấn đề:** Wi-Fi loss bursty + jitter phá mục tiêu 30–50ms.
- **Giảm thiểu:** plain UDP over NetBird (QUIC dropped — WireGuard đã encrypt, [13]); FEC chỉ cân nhắc khi relayed. **(GUI video-path only, Phase 4.)**

### 🟡 R4 — Keyboard layout / dead keys
- **Vấn đề:** keycode phụ thuộc layout host; dead-key (´+e→é) khó.
- **Giảm thiểu:** gửi text qua **Unicode injection** (layout-independent); keycode chỉ cho shortcut. Một số game bỏ qua Unicode → fallback keycode.

### 🟡 R4b — Text màu nhòe do chroma 4:2:0
- **Vấn đề:** Apple HW encode không có 4:4:4 → text trên nền màu bị viền/bleeding. Đổi codec không sửa được.
- **Giảm thiểu:** HEVC **10-bit** + capture resolution cao. Nếu chí mạng → software 4:4:4 "ultra text" tier (chấp nhận latency). Xem [09 §2](09-codec-choice.md).

### 🟢 R5 — AVSampleBufferDisplayLayer thêm latency
- **Giảm thiểu:** bọc behind protocol `VideoRenderer`, chuyển Metal khi cần (Phase 4).

### 🟢 R6 — Pointer lifetime CMFormatDescription crash
- **Giảm thiểu:** nest `withUnsafeBytes` / `withExtendedLifetime` đúng cách ([04 §1](04-client-decode-render.md)).

### 🟡 R7 — VideoToolbox thiếu RFI-by-id & gradual intra-refresh
- **Vấn đề:** không có `NvEncInvalidateRefFrames` hay periodic intra-refresh như NVENC.
- **Giảm thiểu:** dùng **LTR ack workflow** (`EnableLTR`/`ForceLTRRefresh`) — tương đương về recovery, tránh keyframe spike. Verify tên symbol trên SDK đích. Xem [10 §1](10-latency-optimization.md).
- **Rủi ro phụ:** nếu LTR symbol/behavior không như WWDC21 mô tả → fallback FEC + IDR-on-loss (vẫn chạy, chỉ kém mượt khi mất gói).

### ⭐ Cross-cutting note (không đánh số) — Compositor/vsync tail là latency ẩn lớn nhất phía client *(GUI path)*
- **Giảm thiểu:** Metal overhead thấp + `displaySyncEnabled=false` (macOS) + present sát vsync. Xem [10 §9](10-latency-optimization.md).

### 🟡 R8 — VRR/Adaptive-sync cần fullscreen, xung đột với mô hình 1 cửa sổ
- **Vấn đề:** adaptive-sync scheduling yêu cầu cửa sổ fullscreen → client windowed KHÔNG hưởng lợi VRR (~3–8 ms).
- **Giảm thiểu:** chấp nhận fixed-rate compositor cho windowed, HOẶC chế độ fullscreen tùy chọn ở client. Xem [11](11-absolute-latency.md).

### 🟢 R9 — NetBird relayed fallback (chấp nhận degraded, KHÔNG engineer)
- **Quyết định:** thiết kế **giả định direct P2P**; nếu rớt relay (>80ms, do NAT hairpin/hard-NAT — cùng LAN không đảm bảo 100%) thì **chỉ surface + cảnh báo**, KHÔNG xây workaround (no mosh/SSP, no adaptive/FEC). Lưu ý: NetBird ≥ v0.69.0 đã có UPnP/NAT-PMP/PCP (đỡ rớt relay); Tailscale còn birthday-paradox cho symmetric NAT. Xem [13](13-netbird-transport.md).
- **Giảm thiểu:** badge connection-type (`netbird status` P2P/Relayed) + cảnh báo user; nếu thực tế hay relay mới cân nhắc nâng cấp sau. Xem [13 §4](13-netbird-transport.md).

### 🟡 R10 — macOS 26 Tahoe decode/present latency regression
- **Vấn đề:** Moonlight #1696 báo decode latency vọt (~20–80 ms) với CAMetalDisplayLink trên macOS 26; tắt Metal renderer → ~2.7 ms.
- **Giảm thiểu:** **test trên macOS 26 target** trước khi tin floor; có thể cần fallback present path.

> 📋 **Nhiều correction & open-question đã được giải/cập nhật** trong [11-absolute-latency.md](11-absolute-latency.md) §"Verified API claims" (14 corrections + checklist Phase-0 đầy đủ). Đọc trước khi code.

---

## 2. Câu hỏi mở (cần chốt)

| # | Câu hỏi | Khuyến nghị mặc định |
|---|---------|----------------------|
| Q1 | Codec mặc định? | **HEVC Main 8-bit 4:2:0 + constant-quality** (Apple Silicon); 10-bit optional; 4:4:4 dropped; AV1/VVC không HW-encode. Xem [09](09-codec-choice.md) |
| Q2 | Render Phase đầu? | **AVSampleBufferDisplayLayer** (nhanh lên hình), Metal ở Phase 4 |
| Q3 | Transport mặc định? | **Plain UDP** (video) / **plain TCP** (terminal) over NetBird — QUIC dropped (WireGuard encrypt, [13]) |
| Q4 | Có cần auth/pairing không? | **Nên có** PIN/QR dù LAN (tránh ai cùng mạng cũng điều khiển được) |
| Q5 | Audio? | Để Phase 4 (per-window audio không có; audio ở mức app) |
| Q6 | Nhiều cửa sổ đồng thời? | Phase 4; MVP 1 cửa sổ/phiên |
| Q7 | Con trỏ trên client? | **Đã rõ:** loại khỏi video (`showsCursor=false`) + **vẽ client-side** từ kênh input (cảm giác tức thì). Xem [10 §7](10-latency-optimization.md) |
| Q8 | macOS version ship tối thiểu? | 14+ (ảnh hưởng test activation R2) |

---

## 3. Giả định đang dựa vào (cần verify khi code)

- `kAXPositionAttribute` (AX) == `kCGWindowBounds` (CG) cùng top-left/points — **đúng trong thực tế nhưng chưa thấy 1 trang Apple khẳng định verbatim**. Verify bằng print runtime trước khi tin cho click pixel-accurate.
- Encode/decode latency Apple Silicon ~1–8ms — **đo lại Phase 0**.
- LAN loss ~0 đủ để FEC thấp/không — **đo trên mạng thật**.
- `SCStreamFrameStatus` khi minimize (`.suspended` vs ngừng emit) khác nhau giữa version macOS — reconcile với `SCWindow.isOnScreen`.

---

## 4. Phi mục tiêu (rõ ràng KHÔNG làm, ít nhất giai đoạn đầu)

- ❌ App-level NAT traversal / custom relay — delegate cho **NetBird mesh** ([13]). Remote access đi qua NetBird (direct P2P assumed; relayed = degraded).
- ❌ Host Windows/Linux (chỉ macOS).
- ❌ Mac App Store (sandbox không tương thích — [06](06-permissions-distribution.md)).
- ❌ Điều khiển nhiều cửa sổ nền đồng thời thật sự (giới hạn macOS — [05 §0](05-input-window-control.md)).
- ❌ Per-window audio (macOS không hỗ trợ).
