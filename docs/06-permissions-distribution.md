# 06 — Permissions, Entitlements & Distribution

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

## 1. Quyền cần thiết (Host macOS)

| Quyền (TCC) | Để làm gì | Bắt buộc? |
|-------------|-----------|-----------|
| **Screen Recording** | ScreenCaptureKit capture + đọc title/nội dung cửa sổ app khác | ✅ Bắt buộc |
| **Accessibility** | Post event tới app khác + raise/control cửa sổ qua AX | ✅ Bắt buộc |
| **Input Monitoring** | CHỈ nếu dùng `CGEventTap` để *quan sát* input cục bộ | ❌ Không cần để *post* event |

Client (Mac/iOS) chỉ cần **Local Network** (Bonjour) — xem [03](03-transport-protocol.md#1-discovery--bonjour-zero-config).

## 2. Info.plist

```xml
<!-- Host: Screen Recording -->
<key>NSScreenCaptureUsageDescription</key>
<string>PaneCast chia sẻ cửa sổ ứng dụng của bạn tới thiết bị đã ghép nối.</string>

<!-- Client + Host: Local Network (iOS 14+ bắt buộc, không có thì Bonjour im lặng) -->
<key>NSLocalNetworkUsageDescription</key>
<string>PaneCast tìm và kết nối thiết bị trong cùng mạng nội bộ.</string>
<key>NSBonjourServices</key>
<array><string>_panecast._udp</string></array>
```

> Thiếu `NSScreenCaptureUsageDescription` → process **bị kill** khi chạm SCKit lần đầu.

## 3. Detect & request quyền

```swift
// Accessibility — check không prompt:
let trusted = AXIsProcessTrusted()
// Check + prompt (mở System Settings → Privacy → Accessibility):
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
AXIsProcessTrustedWithOptions(opts)

// Screen Recording:
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
```

- **Không thể cấp quyền bằng code** — user phải tự bật trong System Settings.
- Quyền gắn theo **chữ ký code** — build unsigned/ad-hoc rebuild có thể mất grant.
- **Poll `AXIsProcessTrusted()`** (hoặc theo dõi app reactivate) để biết khi user bật xong → cập nhật UI onboarding.

## 4. Sandbox — dealbreaker (nêu rõ)

- **App sandboxed KHÔNG thể có quyền Accessibility.** Sandbox bật → prompt không hiện, không add được trong Settings, `AXIsProcessTrusted()` luôn false. **Không có entitlement nào bật lại.**
- Vì cốt lõi app là điều khiển app khác → **Sandbox tắt hoàn toàn.**
- **Hệ quả: không lên Mac App Store** (App Store yêu cầu sandbox).

## 5. Hardened Runtime & Distribution

- **Hardened Runtime** (cần cho notarize/Developer-ID) **OK** — không chặn post event/AX. Hardened runtime và sandbox độc lập nhau.
- Thường **không cần** entitlement hardened-runtime đặc biệt chỉ để post CGEvent/dùng AX.
- **Mô hình phân phối:** Developer-ID signed + **notarized**, ship ngoài App Store (DMG / trang web / Sparkle auto-update).

## 6. Onboarding flow (đề xuất)

1. Mở app → màn hình "Cần 2 quyền".
2. Nút "Cấp Screen Recording" → `CGRequestScreenCaptureAccess()`.
3. Nút "Cấp Accessibility" → `AXIsProcessTrustedWithOptions(prompt)` → deep-link Settings.
4. Poll cả hai → khi đủ, chuyển sang màn hình chọn cửa sổ.
5. Client iOS: lần kết nối LAN đầu → iOS tự prompt Local Network.

## 7. Checklist build

- [ ] `Info.plist`: 3 key trên.
- [ ] Tắt App Sandbox (host).
- [ ] Bật Hardened Runtime.
- [ ] Ký Developer-ID + notarize cho host app.
- [ ] Onboarding poll quyền + hướng dẫn từng bước.
