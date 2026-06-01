# 07 — Roadmap

> **STATUS: SUPERSEDED** — đã thay; xem [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Đã được ghi đè** bởi [12 §"Revised phased roadmap"](12-coding-profile.md). Thứ tự mới cho kiến trúc hybrid: **terminal PTY text-path = Phase 1** (đơn giản hơn, giá trị cao hơn, né bài toán injection); GUI video path lùi về **Phase 4**. Phần dưới giữ làm tham chiếu chi tiết cho **GUI video-path**.

Nguyên tắc: **kiểm chứng rủi ro trước, đẹp sau.** Phase 0 dồn vào 2 điểm rủi ro cao nhất (input injection theo cửa sổ + latency encode/decode). Đừng đầu tư transport/UI trước khi Phase 0 pass.

---

## Phase 0 — Spike kiểm chứng (BẮT BUỘC trước tiên)

**Mục tiêu:** chứng minh không có rào cản kỹ thuật. Code throwaway, không cần đẹp.

| # | Việc | Doc | Done khi |
|---|------|-----|----------|
| 0.1 | Capture 1 cửa sổ qua SCKit, log fps + idle-frame skip | [02](02-host-capture-encode.md) | Thấy frame `.complete`, idle bị bỏ |
| 0.2 | HW encode HEVC low-latency, **đo encode latency** | [02](02-host-capture-encode.md) | Có số ms/frame trên máy đích |
| 0.2b | Verify symbol LTR (`EnableLTR`/`ForceLTRRefresh`) trên SDK đích | [10 §1](10-latency-optimization.md) | Xác nhận LTR API tồn tại & hoạt động |
| 0.3 | Decode lại nội bộ host (encode→decode loop), hiển thị | [04](04-client-decode-render.md) | Cửa sổ hiện lại đúng |
| 0.4 | `AXRaise` đúng cửa sổ cụ thể (app nhiều cửa sổ) | [05](05-input-window-control.md) | Cửa sổ đúng lên front |
| 0.5 | `CGEventPostToPid` click theo tọa độ map | [05](05-input-window-control.md) | Click trúng vị trí trong cửa sổ |
| 0.6 | Test activation từ callback mạng giả lập (macOS đích) | [05](05-input-window-control.md) | Đo tỉ lệ activate thành công |

**Gate:** nếu 0.4–0.6 fail nhiều → dừng, xem lại mô hình ([08-risks](08-risks-open-questions.md)) trước khi tiếp.

---

## Phase 1 — MVP video Mac→Mac, 1 chiều, 1 cửa sổ

**Mục tiêu:** xem được 1 cửa sổ host trên 1 Mac client qua LAN.

- [ ] Scaffold SPM theo [01 §3](01-architecture.md#3-cấu-trúc-package-swift-package-manager).
- [ ] `PaneCastCore`: packet format + packetizer/reassembler + unit test mất/đảo gói ([03 §4–5](03-transport-protocol.md)).
- [ ] Bonjour discovery: host advertise, client liệt kê ([03 §1](03-transport-protocol.md)).
- [ ] Pipeline đầy đủ: capture → encode → UDP → reassemble → decode → render.
- [ ] Kênh control TCP `noDelay` + message recovery (LTR ack / request-IDR) ([03 §3](03-transport-protocol.md)).
- [ ] Render-on-arrival hoặc Pacer (CVDisplayLink) ([10 §2](10-latency-optimization.md)).
- [ ] **Instrument 6-stage latency** + timestamp host trong frame header ([10 §10](10-latency-optimization.md)).
- [ ] Window picker UI (host) + host list UI (client).
- [ ] **Đo glass-to-glass latency.**

**Done:** chọn cửa sổ trên host → thấy live trên client Mac, latency < 60ms LAN, mất gói tự recover (LTR, fallback keyframe).

---

## Phase 2 — Input / điều khiển (Mac→Mac)

**Mục tiêu:** điều khiển được cửa sổ từ client.

- [ ] Client bắt chuột/phím/scroll trong view → gửi qua control channel (tọa độ chuẩn hóa 0–1).
- [ ] Input: batch motion 1ms / button gửi ngay; con trỏ vẽ client-side ([10 §6–7](10-latency-optimization.md)).
- [ ] Host: activate-then-control — raise + map tọa độ + `CGEventPostToPid` ([05](05-input-window-control.md)).
- [ ] Text qua Unicode injection; shortcut qua keycode.
- [ ] (Tùy chọn) AX action cho nút/text field chuẩn.
- [ ] Xử lý drag, double-click, scroll.

**Done:** điều khiển trơn tru 1 cửa sổ từ client Mac; gõ text + click + drag hoạt động.

---

## Phase 3 — Client iOS / iPadOS

**Mục tiêu:** xem & điều khiển từ iPhone/iPad.

- [ ] Build `PaneCastClientKit` + `PaneCastRender` cho iOS.
- [ ] Render trên device thật (Simulator không HW decode).
- [ ] Touch → input mapping: chế độ **trackpad** (relative) + **direct-touch** (absolute).
- [ ] Bàn phím cứng + on-screen keyboard → Unicode injection.
- [ ] iPad: hỗ trợ trackpad/pencil nếu có.

**Done:** điều khiển cửa sổ Mac từ iPhone & iPad qua LAN.

---

## Phase 4 — Polish & mở rộng

- [ ] Nhiều cửa sổ / nhiều phiên đồng thời.
- [ ] Reconnect tự động khi rớt mạng.
- [ ] Adaptive bitrate theo loss/RTT ([03 §5](03-transport-protocol.md)).
- [ ] Render Metal thay AVSampleBufferDisplayLayer nếu cần latency thấp hơn.
- [ ] FEC adaptive cho Wi-Fi.
- [ ] Audio (tùy chọn — SCKit capture audio ở mức app, không per-window).
- [ ] Bảo mật/pairing: PIN/QR ghép thiết bị (LAN vẫn nên có auth).
- [ ] Ký Developer-ID + notarize + auto-update ([06](06-permissions-distribution.md)).

---

## Thứ tự ưu tiên rút gọn

```
Phase 0 (spike) ──gate──▶ Phase 1 (video) ──▶ Phase 2 (input) ──▶ Phase 3 (iOS) ──▶ Phase 4 (polish)
   rủi ro cao                  giá trị thấy được      cốt lõi          mở rộng         hoàn thiện
```
