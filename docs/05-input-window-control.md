# 05 — Input Injection & Window Control (phần KHÓ NHẤT)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Kiến trúc hiện hành: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **CHỈ áp dụng cho GUI video-path.** Trong kiến trúc hybrid ([12](12-coding-profile.md)), **terminal đi PTY text-path**: input = byte → PTY stdin → **không CGEvent, không TCC Accessibility, không activate-then-control, không AXUIElement↔CGWindowID matching**. Toàn bộ rủi ro injection dưới đây **biến mất cho terminal** (phần lớn workflow coding); chỉ còn áp dụng khi mirror cửa sổ GUI (VS Code/Xcode) ở Phase 4.
>
> **Correction (cần test):** keyboard inject qua `CGEventPostToPid` **được** Electron/VS Code text-area chấp nhận; chỉ **mouse** bị renderer IPC từ chối (cần SkyLight `SLEventPostToPid` private SPI).

> Đây là rủi ro kỹ thuật lớn nhất của **GUI video-path**. Đọc kỹ phần "giới hạn" trước khi thiết kế.

## 0. Kết luận thẳng thắn

**Activate-then-control là mô hình ĐÚNG và gần như DUY NHẤT đáng tin trên macOS hiện đại.** Lý do:

1. **Không thể inject mouse vào cửa sổ nền một cách tin cậy.** macOS hit-test sự kiện chuột tổng hợp theo z-order cửa sổ dưới con trỏ — y hệt input vật lý. `CGEventPostToPid` đưa event vào queue của process, nhưng **AppKit bên trong vẫn hit-test** và cửa sổ không-frontmost thường không xử lý click.
2. **Vì vậy phải raise/focus cửa sổ đích trước**, rồi mới post event → chính là mô hình đã chọn.
3. **macOS 14 đổi activation thành cooperative/advisory** — hệ thống có thể từ chối, đặc biệt khi trigger bởi sự kiện mạng/timer (chính là case của remote control).
4. **Không tương thích App Sandbox** → ship ngoài Mac App Store, Developer-ID + notarize.
5. **Ưu tiên AX action (`AXPress`, set `AXValue`) hơn click tổng hợp** khi UI expose Accessibility — bỏ qua hit-test & focus, robust hơn nhiều.

---

## 1. Tạo & post sự kiện CGEvent

```swift
let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left)
let kdn  = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
let scr  = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
```

Gotchas:
- **Drag** = `.leftMouseDown` → nhiều `.leftMouseDragged` → `.leftMouseUp`. Down→up ở 2 điểm KHÔNG phải drag.
- **Double-click:** set `.mouseEventClickState = 2` trên cặp down/up thứ 2.
- **Mouse moved/dragged:** nên set `.mouseEventDeltaX/Y` cho app/game đọc delta.

### Routing — điểm mấu chốt

| Hàm | Routing | Target process? |
|-----|---------|-----------------|
| `CGEventPost(.cghidEventTap)` | Tầng HID thấp nhất, di chuyển con trỏ thật, hit-test toàn cục | Không |
| `CGEventPost(.cgSessionEventTap)` | Luồng session, vẫn hit-test toàn cục | Không |
| `CGEventPostToPid(pid, e)` | Vào queue process cụ thể, **nhưng AppKit vẫn hit-test nội bộ** | Process, **không phải window** |

→ **Dùng `CGEventPostToPid(targetPid, e)` SAU khi raise** (ít xáo trộn con trỏ hệ thống). Nó **bổ trợ** activation, không thay thế.

---

## 2. Coordinate mapping (rất dễ sai)

**Sự thật then chốt:** CGEvent mouse position và `kCGWindowBounds` **dùng CÙNG global "screen space": gốc top-left màn hình chính, +Y xuống dưới, đơn vị points.** → window rect dùng trực tiếp để click, **không cần flip Y**.

⚠️ **AppKit (`NSWindow.frame`/`NSScreen`) ngược chiều** (gốc bottom-left, +Y lên). Nếu trộn frame AppKit với điểm CGEvent → phải flip. **Giải pháp: ở nguyên CG/Quartz space đầu-cuối, không đụng frame AppKit.**

```swift
// remotePoint: tọa độ tương đối top-left cửa sổ (points)
let target = CGPoint(x: windowBounds.origin.x + remotePoint.x,
                     y: windowBounds.origin.y + remotePoint.y)
```

- **Multi-monitor:** mặt phẳng liên tục; display bên trái/trên có tọa độ âm → tự đúng vì cộng window origin.
- **Retina:** `kCGWindowBounds` & CGEvent đều là **points**, scale factor KHÔNG vào phép tính. CHỈ chia scale nếu client gửi tọa độ **pixel** từ frame ScreenCaptureKit (frame là pixel). **Đừng double-apply scale.**
- Client nên gửi tọa độ **chuẩn hóa (0–1)** → nhân `windowBounds.width/height` → né hẳn mơ hồ pixel/point.

---

## 3. Keyboard

- **Virtual keycode** (`virtualKey:keyDown:`): cho phím điều hướng/shortcut (mũi tên, Return, Tab, Esc, ⌘-keys). Keycode là **vị trí vật lý** → ký tự phụ thuộc layout của **host**. Set modifier: `event.flags = [.maskCommand, .maskShift]`.
- **Unicode injection** (`event.keyboardSetUnicodeString(...)`): **cách robust để gửi text** — layout-independent, truyền đúng ký tự user gõ. Né hẳn vấn đề keycode-vs-layout và dead-key.

**Chiến lược:** gửi **text dạng Unicode**, dùng **keycode chỉ cho shortcut/phím điều hướng**. (Một số game đọc keycode phần cứng, bỏ qua Unicode → fallback keycode.)

---

## 4. Raise một cửa sổ CỤ THỂ

Activate *app* chỉ đưa key/main window lên — không nhất thiết đúng cửa sổ. Phải dùng AX:

```swift
let appEl = AXUIElementCreateApplication(pid)   // pid từ SCWindow.owningApplication.processID
var v: CFTypeRef?
AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v)
let axWindows = v as! [AXUIElement]
let target = axWindows.first { /* match theo title / so frame với SCWindow.frame */ }!

AXUIElementPerformAction(target, kAXRaiseAction as CFString)
AXUIElementSetAttributeValue(appEl, kAXMainWindowAttribute as CFString, target)
NSRunningApplication(processIdentifier: pid)?.activate()   // xem caveat macOS 14 bên dưới
```

> ⚠️ **Không có API public map `AXUIElement` ↔ `CGWindowID`.** Match cửa sổ là **heuristic** (title + so `kAXPositionAttribute`/`kAXSizeAttribute` với CG `frame`). Đây là điểm dễ vỡ thật sự của thiết kế "1 cửa sổ cụ thể" — phải code phòng thủ (nhiều title trùng, cửa sổ di chuyển giữa query và raise).

### Caveat macOS 14+ cooperative activation (quan trọng cho remote control)

`activate(ignoringOtherApps:)` deprecated; `activate()` mới là **advisory** — hệ thống có thể từ chối. Report cộng đồng: **work khi trigger bởi user action, FAIL khi trigger bởi timer/network** — chính xác là case remote control (activate do sự kiện mạng đến).

Giảm thiểu:
- `activateIgnoringOtherApps:` (deprecated) vẫn chạy ở macOS 14, mạnh hơn — chấp nhận warning.
- `AXRaise` tự reorder cửa sổ ngay cả khi full app activation bị throttle → **kết hợp `AXRaise` + `activate()` là tin cậy nhất**.
- **Phải test trên đúng version ship (14/15/26)** — chính sách activation siết liên tục.

---

## 5. Accessibility làm đường điều khiển chính (khi có thể)

Khi control expose AX → điều khiển **trực tiếp**, không tổng hợp chuột/phím:

```swift
AXUIElementPerformAction(buttonEl, kAXPressAction as CFString)             // bấm nút
AXUIElementSetAttributeValue(fieldEl, kAXValueAttribute as CFString, "x")  // set text (layout-independent)
AXUIElementSetAttributeValue(fieldEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
```

**Robust hơn** vì không phụ thuộc vị trí con trỏ, z-order, hit-test, hay cửa sổ phải key.

**Giới hạn:** chỉ tốt như app target implement AX. UI vẽ tay, canvas, nhiều game, Electron/web, OpenGL/Metal view → expose rất ít → fallback CGEvent. AX cần **cùng quyền Accessibility** (không giảm permission footprint, chỉ tăng độ tin cậy).

**Hybrid khuyến nghị:** thử AX action cho control type biết trước; fallback activate-then-CGEvent cho phần còn lại (drag, vẽ tự do, game, view không expose).

---

## 6. Kiến trúc đề xuất "activate-then-control, 1 cửa sổ/lần"

1. **Enumerate** bằng ScreenCaptureKit; capture & stream `SCWindow` đã chọn. Giữ `windowID`, `owningApplication.processID`, `frame`.
2. **Mỗi tương tác:** đọc lại frame (CG space), **raise cửa sổ cụ thể** (`AXRaise` + set main, rồi `activate()` — cân nhắc `activateIgnoringOtherApps:` nếu test thấy API mới drop activation từ mạng).
3. **Map** tọa độ remote → global CG (cộng window origin; chuẩn hóa nếu stream là pixel; không flip Y).
4. **Act:** ưu tiên **AX action** khi control expose; nếu không → **`CGEventPostToPid(pid, e)`**. Text gửi **Unicode**, keycode chỉ cho shortcut.

---

## 7. Việc cho Phase 0 spike (KIỂM CHỨNG RỦI RO)

- [ ] Lấy `pid` + `windowID` + `frame` từ `SCWindow`.
- [ ] `AXRaise` đúng cửa sổ cụ thể của 1 app nhiều cửa sổ (test heuristic matching).
- [ ] `CGEventPostToPid` click vào tọa độ map → verify click trúng đúng vị trí trong cửa sổ.
- [ ] Test activation từ callback mạng (mô phỏng) trên macOS đích — đo tỉ lệ activate thành công.
- [ ] Thử `AXPress` 1 nút chuẩn → so độ tin cậy với click tổng hợp.

→ Nếu các mục này pass → mô hình khả thi. Nếu activation fail nhiều → cân nhắc fallback (xem [08-risks](08-risks-open-questions.md)).
