# 13 — Transport trên NetBird mesh (WireGuard)

> Cả host lẫn client đều là node trong **NetBird** (WireGuard mesh VPN). Doc này ghi model mạng + các **correction** cho doc 03/11/12 (nhiều giả định "LAN thuần" không còn đúng). Nguồn: NetBird docs + source (`client/iface/*`).

## TL;DR — 6 quyết định

1. **Bỏ encryption tầng app (TLS/QUIC-crypto).** WireGuard đã E2E encrypt (ChaCha20-Poly1305) + xác thực node bằng public key. Thêm lớp nữa là **thừa** — đúng như bạn nói. Crypto của WireGuard là sub-microsecond/packet (không phải nguồn latency); cái đáng tránh là **lớp mã hóa thứ 2**.
2. **KHÔNG pin `requiredInterfaceType = .wiredEthernet/.wifi`.** NetBird tạo interface **`utun100`** (wireguard-go userspace) → trong Network.framework là **`.other`**. Pin vào wiredEthernet/wifi sẽ **loại bỏ traffic NetBird → hỏng kết nối**. Để mặc định không pin (routing table tự lái `100.64/10` vào utun100), hoặc pin theo `NWInterface` cụ thể bằng tên.
3. **Bonjour/mDNS KHÔNG đi qua mesh.** WireGuard là L3 point-to-point, không multicast. Discovery qua mesh dùng **NetBird DNS (`peer.netbird.cloud`)** hoặc IP `100.64.0.0/10` hoặc NetBird API. **Bonjour chỉ dùng cho cùng LAN vật lý.**
4. **`serviceClass`/DSCP vô tác dụng qua tunnel.** WireGuard zero DSCP của packet outer (chỉ propagate ECN). → `serviceClass = .interactiveVideo` **không làm gì** trên NetBird. Thay bằng **adaptive rate control tầng app**.
5. **Authorization = NetBird ACL** (deny-by-default, per-port/protocol). WireGuard xác thực *node*; NetBird policy giới hạn *peer nào* tới *port nào*. Đây là lớp access control thay cho app crypto.
6. **Giả định: NetBird direct P2P** (~5–20ms, cùng LAN gần native). **KHÔNG engineer cho relay** — nếu P2P fail và rớt xuống relay (>80ms) thì chỉ **surface + cảnh báo** cho user (chấp nhận degraded), không xây workaround (no mosh/SSP, no adaptive/FEC). → toàn bộ thiết kế tối ưu cho P2P.

---

## 1. Bảo mật — dựa vào VPN, bỏ app crypto

| Lớp | NetBird/WireGuard lo | App KHÔNG cần làm |
|-----|----------------------|-------------------|
| Confidentiality | ChaCha20-Poly1305 AEAD | ❌ TLS/QUIC encryption |
| Integrity | Poly1305 MAC (16B) | ❌ |
| Node authentication | WireGuard public key + NetBird management | ❌ cert/key exchange |
| **Authorization (peer→port)** | **NetBird ACL** (deny-by-default, group/port/protocol) | ✅ chỉ cần cấu hình policy |

- **"NetBird mesh LÀ security boundary"** (khác với LAN trần): chỉ peer đã join + được ACL cho phép mới tới được port. PTY=RCE giờ **bị giới hạn trong các peer được authorize** (bạn kiểm soát membership) — không còn là "ai trên LAN cũng RCE".
- **ACL khuyến nghị:** policy chỉ mở port app (vd TCP terminal + UDP video) từ group client → group host. Per-port range hỗ trợ từ v0.48.
- **Giới hạn:** ACL ở mức *node*, không phải *user*. Nhiều user chung 1 máy → cùng quyền. Nếu cần per-user → OIDC/SSO của NetBird, hoặc app-level device-allowlist nhẹ (không phải crypto).
- Transport tầng app = **plain** (TCP cho terminal, UDP cho video) — không TLS, không QUIC-crypto.

> ⚠️ Self-hosted NetBird: domain DNS khác `netbird.cloud`; relay/signal tự host. Điều chỉnh discovery tương ứng.

## 2. Transport / Network.framework

```swift
// KHÔNG pin .wiredEthernet/.wifi — sẽ loại utun100 (NetBird). Để routing table tự lái 100.64/10.
let params = NWParameters.udp          // plain UDP cho video — WireGuard đã encrypt
params.allowFastOpen = true
// params.requiredInterfaceType = .wiredEthernet   // ❌ SAI cho NetBird — bỏ
params.includePeerToPeer = false       // tắt AWDL của Apple (không liên quan NetBird, vẫn nên tắt)
// KHÔNG set serviceClass kỳ vọng QoS — DSCP bị WireGuard zero qua tunnel. Dùng adaptive rate tầng app.
```

- **Terminal path:** plain TCP qua `NWConnection` (framing 1-byte type + 4-byte len). Không TLS.
- **Video path:** plain UDP. **Bỏ QUIC** (lý do dùng QUIC trước đây chủ yếu là TLS + congestion — TLS thừa, congestion thì tự làm adaptive).
- **MTU:** NetBird default **1280** (`DefaultMTU` trong `client/iface/iface.go`; KHÔNG phải 1420). Payload app ~1200 **an toàn** (headroom ~52B). Tốt nhất: đọc MTU interface runtime, clamp payload = `mtu − 80` (overhead WireGuard IPv6 outer).

## 3. Discovery

| Trường hợp | Cách |
|-----------|------|
| **Cùng LAN vật lý** | Bonjour/mDNS vẫn chạy (không qua NetBird, dùng Ethernet/Wi-Fi local) |
| **Qua mesh (remote)** | NetBird DNS `host-name.netbird.cloud` (resolver tại IP cao nhất trong /16), hoặc IP `100.64/10`, hoặc NetBird API `/api/peers` |

→ App nên: thử Bonjour (same-LAN) **và** cho phép nhập/chọn NetBird hostname/IP. Không dựa Bonjour cho peer qua mesh.

## 4. Latency — thiết kế cho direct P2P (relay = degraded fallback)

| Tier | Latency | Xử lý |
|------|---------|-------|
| **Direct P2P** (giả định) | ~5–20ms (cùng LAN gần native, dominated by NIC) | Tối ưu cho tier này |
| **Relayed** (fallback) | >80ms | **Chỉ surface + cảnh báo**, KHÔNG engineer workaround |

- Kiểm tra: `netbird status --detail` → `Connection type: P2P/Relayed`, `Direct: true/false`, `Latency`. App hiển thị badge P2P/Relayed.
- ⚠️ **Cùng LAN KHÔNG đảm bảo P2P 100%** — NAT hairpin/VLAN khác có thể ép relay. **Đảm bảo NetBird ≥ v0.69.0** (2026-04): bản này thêm UPnP/NAT-PMP/PCP (PR #5219) + đỡ các bug same-LAN ([#1753](https://github.com/netbirdio/netbird/issues/1753))/post-sleep ([#2507](https://github.com/netbirdio/netbird/issues/2507)) của bản cũ. Đây là lý do **giữ chỉ báo connection-type**, không phải lý do build mosh/SSP.

### Hệ quả: giữ thiết kế ĐƠN GIẢN (không workaround relay)
Vì giả định P2P (loss~0, ~LAN), các kỹ thuật cho WAN/relay **KHÔNG cần làm**:
- **Terminal = TCP byte-stream + libghostty** (render client; **không SwiftTerm** — best-only). **Không mosh/SSP**, không predictive local-echo. (Lợi ích SSP chỉ phát huy khi relayed — mà ta không engineer cho relay.)
- **Video = plain UDP, không adaptive bitrate, không FEC.** Direct P2P loss~0 như LAN.
- Nếu thực tế hay bị relay → mới cân nhắc nâng cấp (đây là quyết định lùi sau, không phải v1).

### NetBird vs Tailscale/Headscale (đã verify — chọn VPN)
- **Direct P2P: cả ba bằng nhau** (Apple = userspace wireguard-go, cùng cipher/MTU). **Không ai nhanh hơn trên dây.** → giữ NetBird nếu đang đạt direct (`netbird status` = P2P).
- Khác biệt = **xác suất giữ direct**. Tailscale còn 2 thứ NetBird chưa có: **birthday-paradox** (né relay ở symmetric NAT) + **re-upgrade direct ổn định hơn sau sleep**. NetBird đã có UPnP/NAT-PMP/PCP từ **v0.69.0**.
- Nếu *đã* relay: NetBird relay = **QUIC/UDP** (có thể thấp latency hơn DERP=**TCP/443** của Tailscale).
- ⚠️ **Lý do mạnh nhất để cân nhắc Tailscale/Headscale: bug iOS NetBird [#5789](https://github.com/netbirdio/netbird/issues/5789)** (2026-04) — handshake OK nhưng **0 gói data qua utun** (`mkdir /var/run/wireguard: operation not permitted`), cả WiFi lẫn cellular. **Verify status #5789 trước khi quyết** — nếu iOS client là path quan trọng, đây quan trọng hơn cả NAT theory.
- **Headscale** = data-plane Tailscale (full traversal: birthday-paradox + port-mapping) + control tự host. Caveat: control = SPOF, DERP tự host phải lo geography, phát hiện node offline chậm (~16 phút).
- **Kết luận:** mostly same-LAN + expect-P2P → **đổi VPN không đáng về tốc độ**. Chỉ đổi nếu (a) bug iOS #5789 cản, hoặc (b) hay remote qua NAT khó.

## 5. Corrections cho docs cũ (áp dụng)

| Doc | Sai/cũ | Sửa |
|-----|--------|-----|
| [03](03-transport-protocol.md) | `requiredInterfaceType=.wiredEthernet` | Bỏ — utun là `.other`, pin sẽ hỏng NetBird |
| [03](03-transport-protocol.md) | `serviceClass=.interactiveVideo` "đòn bẩy quan trọng nhất" | Vô tác dụng qua tunnel (DSCP zeroed) → adaptive rate tầng app |
| [03](03-transport-protocol.md) | Bonjour cho mọi discovery | Bonjour chỉ same-LAN; mesh dùng NetBird DNS/IP/API |
| [03](03-transport-protocol.md) | QUIC datagram cho Wi-Fi (TLS + CC) | Bỏ QUIC — TLS thừa; plain UDP |
| [12](12-coding-profile.md) §7 / Phase 5 | (cũ) "auth+encryption bắt buộc tầng app" | Bỏ app crypto; dựa WireGuard + NetBird ACL *(đã áp dụng vào doc 12)* |
| [12](12-coding-profile.md) | "LAN không cần local-echo" | Đúng — assume P2P → **không local-echo, không SSP** (terminal = TCP byte-stream) |
| [11](11-absolute-latency.md) | serviceClass là lever | Moot qua NetBird |
| Scope | "Chỉ LAN" | NetBird mesh: direct (near-LAN) hoặc relayed (WAN-like) |

## 5b. P2P không xóa hết server — vẫn cần control plane nhẹ (bài học Happy/Happier)

NetBird P2P lo **byte path**, nhưng **không** thay được toàn bộ control plane ([15](15-prior-art-happy-happier.md)):
- **Push notification** ("Claude cần input" khi app iOS background) — host trigger **APNs/FCM trực tiếp** (không Expo Push — privacy). Cần đăng ký device token ở đâu đó.
- **"Host offline → queue prompt"** + device discovery + session metadata persistence — cần một control plane nhẹ.
- NetBird management server (đã có) + APNs/FCM thẳng từ host có thể đủ; đừng ảo tưởng "pure P2P, zero server". Chỉ relay bị loại khỏi **byte path**.

## 6. Việc cho roadmap
- [ ] Phase 0: log `NWPathMonitor.availableInterfaces` → xác nhận utun100 = `.other` trên macOS + iOS đích.
- [ ] Phase 1: connect qua NetBird IP/hostname (không Bonjour over mesh); plain TCP.
- [ ] Hiển thị connection type (P2P/relayed) trong UI + cảnh báo nếu relayed; clamp payload theo MTU runtime.
- [ ] Cấu hình NetBird ACL policy cho port app (deny-by-default).
- [ ] Giữ thiết kế đơn giản: terminal TCP byte-stream (no SSP), video plain UDP (no adaptive/FEC) — vì assume P2P.
