# 03 — Transport, Discovery & Protocol

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Tất cả dùng **Network.framework** (native, không libwebrtc). Ba phần: discovery (Bonjour), transport (UDP/QUIC), và packet format.

---

## 1. Discovery — Bonjour zero-config

> ⚠️ **Bonjour CHỈ chạy cùng LAN vật lý** — KHÔNG đi qua NetBird mesh (WireGuard không forward multicast). Peer qua mesh: dùng **NetBird DNS (`host.netbird.cloud`)** / IP `100.64/10` / NetBird API. App nên hỗ trợ cả hai: Bonjour cho same-LAN, nhập/chọn NetBird hostname cho remote. Chi tiết [13](13-netbird-transport.md).

### Host advertise (`NWListener`)

```swift
let listener = try NWListener(using: params)   // port tự cấp; đọc lại từ .port
var txt = NWTXTRecord()
txt["v"] = "1"; txt["codec"] = "hevc"; txt["res"] = "3840x2160"
listener.service = NWListener.Service(name: "Phòng khách Mac",
                                      type: "_panecast._udp", domain: nil, txtRecord: txt)
listener.serviceRegistrationUpdateHandler = { change in /* tên thực sau khi resolve va chạm */ }
listener.newConnectionHandler = { conn in /* accept, start trên queue */ }
listener.start(queue: .main)
```

### Client discover (`NWBrowser`)

Dùng `.bonjourWithTXTRecord` để lọc theo codec/version **trước khi** connect:

```swift
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_panecast._udp", domain: nil), using: .udp)
browser.browseResultsChangedHandler = { results, _ in
    for r in results {
        if case let .bonjour(txt) = r.metadata { _ = txt["codec"] }   // check trước connect
        // r.endpoint dùng trực tiếp — không cần resolve IP/port thủ công
    }
}
browser.start(queue: .main)
// Connect: NWConnection(to: result.endpoint, using: params)
```

> 📋 **Info.plist bắt buộc** (iOS 14+ nếu không sẽ im lặng không tìm thấy): `NSLocalNetworkUsageDescription` + `NSBonjourServices = ["_panecast._udp"]`.

---

## 2. Transport — chọn UDP hay QUIC

| | UDP thuần | QUIC datagram | QUIC stream |
|--|-----------|---------------|-------------|
| Reliability | Không (đúng ý cho video) | Không (như UDP) | Có + ordered (**HOL blocking — tệ cho video**) |
| Congestion control | Tự xây | **Có sẵn, phản ứng RTT/loss** | Có sẵn |
| Encryption | Tự lo | TLS 1.3 sẵn | TLS 1.3 sẵn |
| Min OS | iOS 12 | iOS 16 / Ventura | iOS 15 |
| Overhead | Zero handshake | 1-RTT (hoặc 0-RTT) | — |

> ⚠️ **Transport chạy TRÊN NetBird (WireGuard mesh)** — xem [13-netbird-transport.md](13-netbird-transport.md). Điều này ghi đè nhiều khuyến nghị dưới: encryption đã có ở tầng VPN (bỏ TLS/QUIC-crypto), interface là `utun` (`.other` — KHÔNG pin `.wiredEthernet`), `serviceClass` vô tác dụng qua tunnel, Bonjour không qua mesh. Đọc doc 13 trước.

**Khuyến nghị (đã cập nhật cho NetBird):**
- **Video → UDP thuần.** WireGuard đã encrypt → **bỏ QUIC** (lý do dùng QUIC chủ yếu là TLS + congestion; TLS thừa, congestion tự làm adaptive). Loss/jitter tùy tier: direct P2P ~0 (như LAN), relayed thì cần adaptive/FEC.
- **Terminal → TCP thuần** (không TLS). Framing 1-byte type + 4-byte len.

### NWParameters → single source ở [13 §2]

> **Recipe `NWParameters` đầy đủ (utun KHÔNG pin `.wiredEthernet`; `serviceClass`/DSCP vô tác dụng qua tunnel; plain UDP/TCP — bỏ QUIC; `includePeerToPeer=false`) = single source ở [13-netbird-transport.md §2](13-netbird-transport.md).** Không lặp recipe ở đây để tránh drift.

### MTU & fragmentation

- `NWConnection.maximumDatagramSize` ≈ 1472 (Ethernet) — trần để IP **không** fragment.
- **Không bao giờ để IP layer fragment** datagram realtime: mất 1 fragment = mất cả datagram, IP stack không có context để recover.
- Target payload **~1200 byte** (chừa biên cho Wi-Fi/IPv6/VPN).
- Keyframe nặng hàng chục–trăm KB → **fragment ở tầng app** thành N datagram, ghép lại theo frameID.

---

## 3. Kênh control (input) — reliable, riêng biệt

Input event (chuột/phím) nhỏ và **không được mất**. **Tách riêng kênh reliable**, không ghép chung kênh video lossy:

> ⭐ **Quy tắc input (từ Moonlight, port trực tiếp):** batch mouse/pen motion cửa sổ **1ms** (nghịch lý: *giảm* latency vì chống xếp hàng trong stack reliable); **button/key down/up KHÔNG bao giờ batch** — gửi ngay. Timestamp + sequence mọi input. Kênh này cũng tải **vị trí con trỏ** để client vẽ cursor overlay (xem [10 §6–7](10-latency-optimization.md)).

- **Cleanest:** `NWConnection` thứ 2 qua **TCP `noDelay = true`** (tắt Nagle → mỗi phím gửi ngay), port riêng.
- **Nếu video dùng QUIC:** mở **QUIC reliable stream** cho control trên cùng connection, video đi qua QUIC datagram → 1 handshake, 1 connection mã hóa, reliable/unreliable tách tự nhiên.

```swift
var tcp = NWProtocolTCP.Options()
tcp.noDelay = true
tcp.enableKeepalive = true; tcp.keepaliveIdle = 2; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
let controlParams = NWParameters(tls: nil, tcp: tcp)
controlParams.serviceClass = .signaling
```

---

## 4. Packet format (Moonlight-style, đơn giản hóa)

Một header/datagram, big-endian:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| ver |  type |     flags     |          (reserved)           |  type: 0=video 1=fec 2=control-ack
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+  flags: SOF=1 EOF=2 KEY=4
|                          frameID (u32)                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        fragIndex (u16)         |       fragCount (u16)         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  streamSeq (u32) — phát hiện mất gói           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      payload (≤ ~1200 byte)                   |
```

- `frameID`: tăng mỗi frame. `KEY` flag bật ở IDR.
- `fragIndex`/`fragCount`: fragment 1 frame. `EOF` (hoặc `fragIndex==fragCount-1`) đánh dấu fragment cuối.
- `streamSeq`: tăng đơn điệu trên **mọi** datagram → thiếu 1 số = mất 1 fragment, phát hiện tức thì.

---

## 5. Loss handling — không jitter buffer lớn

Chiến lược Moonlight (`VideoDepacketizer.c`). Receiver theo dõi `nextFrameNumber` + `lastStreamSeq`:

1. **Gap trong `streamSeq`** → frame hỏng → `dropFrame`, set `nextFrameNumber = frameID+1`, **request IDR** (KHÔNG retransmit).
2. **Cả frame thiếu** (frameID nhảy vượt) → drop partial, chờ frame sạch tiếp theo.
3. **Fragment cũ** (frameID < nextFrameNumber) → bỏ im lặng.

Request recovery đi qua **kênh control reliable**. Buffer giới hạn ~1 frame → không tích lũy latency.

> ⭐ **Recovery ưu tiên LTR, không phải keyframe.** VideoToolbox hỗ trợ Long-Term Reference: client ack frame nhận được, khi mất gói host phát LTR-P nhỏ predict từ LTR đã-ack (tránh "keyframe spike" 5–20×). Chỉ force IDR khi không còn LTR ack. Đây là sửa đổi quan trọng so với bản đầu — chi tiết [10 §1](10-latency-optimization.md). Thêm: **speculative loss detection** (đoán mất gói trước khi frame kế đến) tiết kiệm 1 frame-time.

### FEC vs retransmit trên LAN

- **Retransmit (ARQ):** tốn 1 RTT → stutter nhìn thấy. **Tránh cho video.**
- **FEC (Reed-Solomon):** recover loss zero added latency, đổi lấy bandwidth.
- **Khuyến nghị LAN dây:** FEC thấp/không (0–10%), dựa vào drop-frame→request-keyframe. **Wi-Fi:** FEC ~15–20%, adaptive theo loss đo được qua control channel.
- ARQ retransmit **chỉ dùng cho kênh control** (đó là mục đích của nó).

### Pacing

- Đừng "bắn" toàn bộ fragment keyframe trong 1 microburst → tràn buffer switch, gây loss ngay cả trên LAN. Trải đều fragment qua frame interval (token/interval pacer đơn giản).
- Couple bitrate encoder với loss/RTT đo từ control channel: loss tăng → giảm bitrate / tăng FEC; sạch → ramp lên.

---

## 6. Việc cho Phase 1

- [ ] `NWListener`/`NWBrowser` discovery Mac↔Mac, hiển thị danh sách host.
- [ ] Packetizer + reassembler theo format §4, có unit test mất/đảo gói.
- [ ] Gửi keyframe (nhiều fragment) + delta frame end-to-end.
- [ ] Kênh control TCP `noDelay` + message `request-keyframe`.
