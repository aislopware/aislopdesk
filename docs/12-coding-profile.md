# 12 — Coding Profile: Kiến trúc Hybrid (terminal text-path + GUI video-path)

> **STATUS: CURRENT** (deep-dive). Front door + decisions: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).
> Doc này gồm 4 phần: **A. Kiến trúc hybrid** (§1–7) · **B. Terminal text-streaming — thiết kế** · **C. GUI video path** (§1–8) · **D. Roadmap & cập nhật docs**.

> Kết quả workflow nghiên cứu (34-agent, 6 dimension + verify + gap-fill) cho use-case **coding hàng ngày**. Tài liệu này **thay thế giả định "mọi cửa sổ đều video"** của các doc trước. Raw corpus: [research/hybrid-research-corpus.json](research/hybrid-research-corpus.json).

## TL;DR — quyết định kiến trúc

App chia **hai đường dữ liệu tách biệt**, route theo từng cửa sổ/tính năng:

| | **Terminal text-path** (như SSH/mosh) | **GUI video-path** |
|--|---|---|
| Dùng cho | shell / vim / tmux / CLI | VS Code, Xcode, browser, app GUI khác |
| Host | spawn login shell trong PTY (`forkpty`), stream byte stream | ScreenCaptureKit capture 1 cửa sổ |
| Client render | **libghostty** full surface (Metal GPU — VVTerm stack), nét tuyệt đối | VideoToolbox decode → Metal (4:2:0, mờ nhẹ — chấp nhận) |
| Input | **byte → PTY stdin** | CGEvent/Accessibility inject |
| Bandwidth idle | ~0 | ~0 (skip `.idle`) |

⭐ **Insight lớn nhất:** terminal-path **bỏ qua hoàn toàn vấn đề input-injection của macOS** (không CGEvent, không TCC Accessibility, không activate-then-control, không AXUIElement mapping) — input chỉ là byte ghi vào PTY. → Đây là lý do **làm terminal-path TRƯỚC**: đơn giản hơn, nét hơn, né sạch lớp rủi ro lớn nhất của dự án (R1/R2 trong [08](08-risks-open-questions.md)).

> Bài học prior-art: VS Code Remote, JetBrains Gateway (bỏ Projector pixel-streaming), Blink Shell — **không ai pixel-mirror đường code**; semantic/text streaming thắng. Pixel chỉ là fallback cho GUI window.


---

## Kiến trúc hybrid: terminal text-path + GUI video-path

> **Re-scope quan trọng.** Tài liệu này thay thế giả định "mọi cửa sổ đều đi qua video" của [01-architecture.md](01-architecture.md). Thiết kế mới chia thành **hai đường dữ liệu tách biệt về bản chất**, định tuyến theo từng cửa sổ / từng tính năng. Use-case là **coding hàng ngày** trên LAN — nơi phần lớn nội dung là terminal/shell text, và GUI editor (VS Code, Xcode) chỉ là một phần.

---

### 1. Hai đường, một insight trung tâm

Mọi công cụ remote-coding thành công đều hội tụ về cùng một nhận định: **semantic/text streaming thắng pixel streaming cho đường code, và pixel streaming chỉ giữ lại làm fallback cho GUI window** nơi không có lựa chọn semantic. JetBrains bỏ Projector (serialize lệnh vẽ AWT qua WebSocket) để chuyển sang RD protocol thin-client vì cách stream lệnh-vẽ vẫn latency cao hơn một protocol semantic chuyên dụng (JetBrains nói thẳng: Projector có "higher UI latency and significantly more network bandwidth"). Setup iPad→Mac tốt nhất hiện nay ghép Blink Shell (mosh/SSH) cho đường text + VS Code Server (Remote Tunnels / code-server) cho đường IDE — **không bên nào pixel-mirror cả** ([JetBrains Gateway blog](https://blog.jetbrains.com/blog/2021/12/03/dive-into-jetbrains-gateway/), [blink.sh](https://blink.sh/), [code.visualstudio.com/docs/remote/vscode-server](https://code.visualstudio.com/docs/remote/vscode-server)).

Kiến trúc hybrid của PaneCast phản chiếu chính xác điều đó:

| | **TERMINAL text-path** | **GUI video-path** |
|--|------------------------|--------------------|
| Mô hình | App **sở hữu shell** như ssh/mosh: host spawn login shell trong PTY, stream byte stream (VT escape sequences) | Mirror 1 cửa sổ GUI: capture → encode → stream → decode |
| Capture | `forkpty()` / `openpty()` từ `<util.h>` (Darwin) | `ScreenCaptureKit` per-window |
| "Encode" | Không có — byte stream thô qua dây | `VideoToolbox` HEVC 4:2:0 (Media Engine) |
| Render client | **libghostty** full surface (Metal GPU, patch tự-own) | `VTDecompressionSession` → Metal |
| Input | **Byte ghi thẳng vào PTY stdin** | `CGEventPostToPid` / SkyLight SPI inject |
| Bandwidth idle | ~0 (PTY không sinh byte khi shell rảnh) | ~0 (`SCFrameStatus.idle` → skip encode) |
| Chất lượng text | **Sắc nét by construction** | 4:2:0 (mờ nhẹ, đã chấp nhận đánh đổi) |

**Insight cốt lõi — và là phần thắng kiến trúc lớn nhất:** đường terminal **bỏ qua hoàn toàn vấn đề input-injection của macOS**. Trên đường video, để gõ phím vào cửa sổ host phải synthesize CGEvent rồi `event.postToPid(pid)`, mà việc này:

- Đòi quyền **Accessibility** (`kTCCServicePostEvent`) do user cấp thủ công trong System Settings, và **app host phải KHÔNG sandbox** thì Accessibility mới hoạt động đầy đủ.
- **Fail im lặng với app Chromium/Electron** (VS Code renderer, Chrome, Slack) vì renderer IPC filter từ chối event tổng hợp thiếu telemetry phần cứng. Mouse bị từ chối chặt hơn keyboard; right-click trên web content bị ép thành left-click.
- Với app canvas/game engine (Blender, Unity) buộc phải dùng **activate-then-control** (raise cửa sổ ~1 frame rồi trả focus) — phá vỡ lời hứa "không cướp focus" của host ([trycua: inside-macos-window-internals](https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md)).

Đường terminal làm input **biến mất hết các ràng buộc đó**: keystroke chỉ là byte ghi vào file descriptor PTY master qua socket — **không CGEvent, không TCC Accessibility, không activate-then-control, không AXUIElement mapping**. Đây không phải tối ưu runtime mà là quyết định kiến trúc loại bỏ một lớp rủi ro cả về kỹ thuật lẫn phân phối (Accessibility gần như buộc phải phân phối ngoài Mac App Store).

> ⚠️ **Lưu ý quan trọng về "input bypass" (corpus, claim_to_verify đã được verify một phần):** việc bypass này nằm ở **CLIENT side không bao giờ inject vào host OS** — client chỉ gửi byte qua transport, host ghi byte vào PTY master fd. Cần xác nhận bằng prototype rằng **không** có lời gọi CGEvent/Accessibility nào trong đường xử lý phím của client (libghostty write-callback → `NWConnection`). Dễ kiểm chứng vì client chỉ phát byte ra `NWConnection`.

---

### 2. Sơ đồ kiến trúc hybrid

```
┌──────────────────────────────── HOST (macOS, non-sandboxed) ────────────────────────────────┐
│                                                                                              │
│   ╔══════════════ TERMINAL PATH (như SSH/mosh) ═══════════╗   ╔════ GUI VIDEO PATH ═════════╗│
│   ║                                                       ║   ║                             ║│
│   ║  forkpty()/openpty()  ┌────────────┐                  ║   ║  ┌───────────────┐          ║│
│   ║  spawn login shell ──▶│ PTY master │                  ║   ║  │ScreenCaptureKit│ 1 window ║│
│   ║   (-zsh, TERM=        │     fd      │                 ║   ║  │ desktopIndep.  │          ║│
│   ║   xterm-ghostty,     └─────┬──────┘                  ║   ║  └───────┬───────┘          ║│
│   ║   LANG=…UTF-8)              │ DispatchIO(.stream)     ║   ║  status==.complete?         ║│
│   ║                             │ read 128KB              ║   ║          │ (skip .idle)      ║│
│   ║  ioctl(TIOCSWINSZ)◀── resize│                         ║   ║          ▼                  ║│
│   ║                             ▼                         ║   ║  ┌──────────────┐ NALU      ║│
│   ║                      raw VT bytes                     ║   ║  │ VideoToolbox │ HEVC 4:2:0 ║│
│   ║                             │                         ║   ║  │ HW encode    │ no B-frame ║│
│   ╚═════════════════════════════│═════════════════════════╝   ║  └──────┬───────┘          ║│
│         ▲ keystroke bytes        │                            ║         │                   ║│
│         │ → PTY stdin            │                            ║  CGEvent/SkyLight inject◀── ║│
│   ┌─────┴───────────────────────▼──────────────────────────────────────│───────────────────╝│
│   │            TRANSPORT  (Network.framework NWListener)                 │                     │
│   │   1-byte msg type (0=PTY data, 1=resize, …) + 4-byte len + payload   │   video = UDP/QUIC   │
│   │   terminal = TCP byte relay (LAN: HOL blocking negligible)           │   (lossy, per [03])  │
│   └──────────────────────────────────────│──────────────────────────────────────────────────┘│
└─────────────────────────────────────────│───────────────────────────────────────────────────┘
                                           │  LAN (<1ms RTT)
┌──────────────────────── CLIENT (macOS / iOS / iPadOS) ──────────────────────────────────────┐
│   ┌─────────────────────────────────────▼──────────────────────────────────────────────┐    │
│   │                      TRANSPORT (NWConnection) + demux theo msg type                  │    │
│   └──────────┬───────────────────────────────────────────────────────┬──────────────────┘    │
│              │ raw VT bytes                                            │ NALU                  │
│              ▼                                                         ▼                       │
│   ┌──────────────────────┐                                  ┌──────────────────┐              │
│   │ libghostty surface    │  feed_data()                    │ VTDecompression  │              │
│   │  emulator (Metal)     │                                 │  → Metal render  │              │
│   │  TerminalViewDelegate │ ── send(source:data:) ──┐       └──────────────────┘              │
│   └──────────────────────┘   keystroke → bytes      │                                          │
│              ▲                                       └──▶ gửi thẳng về PTY stdin (KHÔNG inject) │
│              │ hardware/soft keyboard                                                           │
│   ┌──────────┴───────────┐                          ┌──────────────────┐                       │
│   │ Input (UIKey/NSEvent) │                          │ Mouse/touch input │──▶ inject vào host    │
│   └──────────────────────┘                          └──────────────────┘    (chỉ đường video)  │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 3. Data flow chi tiết từng đường

### 3.1 TERMINAL text-path (đường chính)

**Host PTY → byte stream → libghostty.** Host spawn login shell trong PTY, đọc master fd (DispatchIO), stream raw VT bytes; keystroke ghi thẳng PTY stdin; resize `TIOCSWINSZ`+SIGWINCH. **Chi tiết API đầy đủ** (forkpty vs `openpty`+`posix_spawn`, DispatchIO, env vars + IUTF8, các corpus-correction) **ở Part B §"Terminal text-streaming — thiết kế" §1 bên dưới** — single source, không lặp ở đây.

**Render client — libghostty (full surface) + external-backend patch TỰ OWN. [QUYẾT ĐỊNH ĐÃ CHỐT]**
Dùng **libghostty** (engine Ghostty) cho cả macOS + iOS — render Ghostty-class (Metal GPU, VT fidelity cao nhất, Kitty graphics, ligatures). Đây là stack VVTerm (open source) + Moshi/Echo/RootShell đang chạy production trên iOS, **đúng 1:1 use-case của ta** (client không có local PTY, render byte stream từ mạng).

> 🔑 **Cách tích hợp đã chốt: TỰ OWN minimal external-backend patch — KHÔNG depend fork người khác.** Cân nhắc đã cân: research khuyến nghị path SwiftTerm-engine+own-renderer (mature, không lib non), NHƯNG ta ưu tiên **render Ghostty-class** nên giữ full libghostty và **tự sở hữu patch nhỏ** thay vì depend fork. Lý do bỏ "depend fork": cả hai fork external-IO đều **proven trong app shipping** ([17 §2.2] — VVTerm trên `wiedymi/ghostty:custom-io`, Geistty trên `daiimus/ghostty:ios-external-backend`) nhưng đều **bus-factor 1**; `wiedymi:custom-io` thiếu resize callback, `daiimus` có **External.zig + resize callback + tests** (→ reference tốt hơn). Tự own patch (ref daiimus) = kiểm soát rebase, không phụ thuộc người khác.

**Data path (theo VVTerm, đọc source xác nhận):** network bytes (NetBird/WireGuard TCP) → `ghostty_surface_feed_data()` → VT parse + Metal render của Ghostty; keystroke ra qua `ghostty_surface_set_write_callback` (`use_custom_io = true`) → ghi `NWConnection` → PTY stdin host. Resize qua surface API → host `ioctl(TIOCSWINSZ)`.

> ✅ **Quyết định (verdict LẬT từ SwiftTerm sang libghostty, đã verify 2026).** Ba phản đối cũ với libghostty đều đổ:
> - **iOS proven production** — VVTerm (`vivy-company/vvterm`, đọc source: `ghostty_surface_new` trên `GHOSTTY_PLATFORM_IOS`, **full surface** không phải vt), Moshi (getmoshi.app, Ghostty 1.3.1), Echo, RootShell (`kitknox/rootshell`). Mitchell Hashimoto endorse.
> - **full libghostty feed network bytes được** — qua external/custom-io backend (xem "cái giá" #1). "Giả định tự sở hữu PTY" chỉ đúng với upstream main.
> - **chưa có tagged release** — vẫn đúng (tới Ghostty 1.3.1) nhưng KHÔNG block production.
> - **Dùng FULL surface, KHÔNG vt + own renderer** (lấy luôn Metal renderer Ghostty; vt + own renderer là đường Spectty đang đi và *chưa xong*).
>
> **Công thức tự-own patch (references, KHÔNG depend trực tiếp):**
> 1. **Patch external-backend (tự maintain) — feed-external-bytes là patch-only** (upstream `ghostty-org/ghostty` chỉ spawn PTY; iOS không spawn process được nên BẮT BUỘC in-process patch). Reference thiết kế: **`daiimus/ghostty ios-external-backend`** (`External.zig` ~470 LOC — **hoàn chỉnh hơn**: có resize callback + unit test, có ARCHITECTURE.md) hơn là `wiedymi/ghostty custom-io` (~chục dòng delta, thiếu resize, frozen). API: `use_custom_io` / `GHOSTTY_BACKEND_EXTERNAL` + `ghostty_surface_set_write_callback` + `ghostty_surface_feed_data`. **Code delta thực nhỏ (~hàng trăm LOC)** → own + rebase được.
> 2. **Swift wrapper (tự viết, ref Lakr233):** `Lakr233/libghostty-spm` có `InMemoryTerminalSession` (`write: (Data)->Void` + `receive(_ data: Data)` + UIKit input/IME/accessory/Metal display link) — **map đúng use-case ta** → dùng làm reference cho wrapper của mình, không depend.
> 3. **Build từ Zig (tự dựng, ref Lakr233 `build.yml`):** `zig build -Demit-xcframework=true` (Zig 0.14+, Xcode 15+) → slices ios-arm64 / ios-arm64-sim / macos → vendor `GhosttyKit.xcframework`, **pin upstream Ghostty commit SHA**, re-apply patch khi bump. Build-time lock, không phải runtime risk.
> 4. **Bọc sau protocol `TerminalRendering`** (`feed(bytes)` + `onOutboundBytes`) để cô lập binding C-ABI.
>
> **Cái giá chấp nhận:** né được **bus factor** (ta own patch), NHƯNG vẫn gánh **ABI-instability tax** — libghostty C-ABI chưa có stable release (`vt.h`/`ghostty.h`: "not a general purpose embedding API yet"), nên mỗi Ghostty bump phải **rebase patch + verify ABI** + tự nuôi **Zig toolchain**. Effort: patch nhỏ + pipeline ~**1–3 engineer-weeks** ban đầu, rồi rebase theo giờ khi bump.
>
> ✅ **Open questions ĐÃ GIẢI (đọc source, đã verify — `research/resolve-open-questions-corpus.json`):**
> - (a) **Alt-screen (1049/smcup/rmcup) chạy ĐÚNG** qua external-backend — cả 3 feed function đều về cùng VT parser của Ghostty (`processOutput → terminal_stream.nextSlice`). → **fullscreen Claude Code OK.**
> - (b) **API external-backend OPAQUE** — KHÔNG expose parsed escape-stream / cell grid / cursor cho host (`ghostty.h` chỉ có `read_text`/`read_selection` snapshot + **action callbacks**: `COMMAND_FINISHED`+exit_code+duration, `PWD`, `SET_TITLE`, `PROGRESS_REPORT`, `CELL_SIZE`). → **Block/status UI làm qua action callbacks**, KHÔNG parse OSC raw client-side. (`libghostty-vt` riêng *có* grid API nhưng không bắc cầu sang `ghostty_surface_t`.)
> - (c) **Keyboard: Ghostty tự encode** qua `ghostty_surface_key()` (đọc live kitty_flags/DECCKM) → **route MỌI phím qua đó**; ⚠️ **KHÔNG dùng bypass path của Lakr233** (`TerminalHardwareKeyRouter` hardcode VT100 protocol-blind cho phím nav khi inMemory+no-modifier — sai với remote PTY đang ở kitty/DECCKM mode).
> - (d) **TCP chỉ cần buffering đơn giản** — in-order lossless; escape sequence có thể split qua 2 read → VT parser stateful giữ state qua read (không cần seq/ACK/dedup/reorder).
> - (g) **Thread-safety: feed từ I/O thread riêng, serialize per-surface** (`processOutput` acquire `renderer_state.mutex`; safe concurrent trên surface KHÁC nhau, KHÔNG cùng surface). `@MainActor` của VVTerm là convention, không bắt buộc.
> - **Lakr233 `InMemoryTerminalSession`** = wrapper trên patch `0002-host-managed-io.patch` (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` + `write_buffer` + `process_exit`) → **dùng làm reference cho patch của ta** (cạnh daiimus External.zig).
>
> 🔬 **Còn lại CHỈ SPIKE mới biết (đo trên device):** (e) binary-size XCFramework Metal renderer trên iOS; (f) shell-integration OSC 133 e2e qua network. Các spike codec ở [§5/§6](#5-cấu-hình-videotoolbox-cho-màn-hình-tĩnh) + checklist Phase 0 cuối doc.

> ⚠️ **Threading với libghostty (verify trên device thật):** gọi `ghostty_surface_feed_data` từ network receive loop — xác nhận thread-safety mà VVTerm dùng (queue nào gọi feed; Ghostty tự quản render thread + Metal/IOSurface). *Caveat data-race `feed()` của SwiftTerm KHÔNG còn áp dụng* (đã đổi sang libghostty).

**Scrollback:** PTY thô không có scrollback. Đơn giản nhất là **client-side**: libghostty surface giữ ring buffer các dòng → server **stateless byte relay**, zero cost. Nếu cần replay khi reconnect, giữ server-side ring buffer raw bytes (~1MB), đơn giản hơn nhiều so với mosh-style state sync.

### 3.2 GUI video-path (fallback cho cửa sổ GUI)

GUI video-path = **fallback** cho cửa sổ GUI (VS Code/Xcode...). **Chi tiết** (capture per-window, idle-skip `SCFrameStatus.idle`, dirtyRects, encode HEVC 4:2:0 constant-quality + caveats) ở **Part C §"GUI video path"** bên dưới + [02](02-host-capture-encode.md)/[09](09-codec-choice.md). Input inject (CGEvent/SkyLight — **chỉ đường này**) ở [05](05-input-window-control.md).

---

### 4. Định tuyến per-window: terminal-first

**Khuyến nghị: lean terminal-first.** Lý do có cơ sở từ corpus:

- **Thị phần & workflow.** VS Code chiếm 75.9% IDE nhưng Vim/Neovim cộng lại ~38% usage (Stack Overflow 2025); workflow terminal-centric (Neovim + tmux, CLI, git, build system) **chiếm phần lớn coding hàng ngày** trên Mac từ xa. Đường terminal phục vụ trực tiếp khối này.
- **Đường terminal là nửa mạnh hơn về mọi mặt:** sidestep input-injection, near-zero bandwidth, text sắc nét by construction, API sạch (`apple_support: native`, `difficulty: low`).
- **Đường video là nửa khó hơn:** giữ nguyên toàn bộ phức tạp CGEvent/SkyLight, private SPI, rủi ro phân phối, 4:2:0 mờ.

**Thứ tự ship đề xuất:**

1. **v1 — PTY shell trước.** Rủi ro thấp, API sạch, bandwidth tí hon. Một `NWConnection` TCP byte-relay + framing 1-byte type.
2. **v2 — video mirroring làm tính năng phụ "mirror this window"**, khởi động on-demand qua window picker (giống `SCShareableContent` list — cách an toàn & tường minh nhất). Chấp nhận giới hạn CGEvent với fallback minh bạch cho cửa sổ non-terminal.

**Cách user kích hoạt** (open question, hướng đề xuất): user chọn từ window picker là phương án an toàn & rõ ràng nhất; tránh auto-detect cửa sổ vì phân loại "đây là terminal hay GUI editor" không có API tin cậy. Trường hợp **terminal nhúng trong GUI** (integrated terminal của VS Code, Xcode console) là một open question — không nên cố tách, để nguyên trong đường video của cửa sổ đó.

---

### 5. Wire protocol cho đường terminal

Đường terminal **không cần** sự phức tạp của mosh SSP (state-diff UDP) trên LAN. Với LAN RTT <1ms và loss <0.01%, TCP head-of-line blocking là **negligible** — raw byte streaming qua TCP cho hiệu năng ngang ngửa với ít công sức hơn nhiều. (Mosh chỉ tối ưu cho WAN lossy; SEND_INTERVAL_MIN=20ms của nó cap server→client ở 50fps, vô nghĩa cho LAN.)

**Framing đề xuất (ttyd-style, sạch cho multiplexing resize):**

```
1-byte msg type  (0 = PTY data, 1 = resize, …)
4-byte big-endian payload length
payload bytes (PTY data thô / {cols,rows} cho resize)
```

`NWConnection(.tcp)` qua Network.framework: `NWListener` trên host, `NWConnection` trên client; manual 4-byte length framing hoặc `NWProtocolFramer`. **Không TLS tầng app** — WireGuard encrypt ([13]). Idle efficiency tuyệt vời: PTY master fd không sinh byte khi shell rảnh → không byte nào chảy.

> **Local echo / prediction — KHÔNG cần trên LAN (verdict: confirmed).** Mosh prediction engine ở chế độ Adaptive **hoàn toàn dormant** khi SRTT < ~60ms: `srtt_trigger` chỉ bật khi `send_interval > 30ms`, mà trên LAN `send_interval` clamp về sàn 20ms. Nếu sau này muốn instant echo, phải dùng `DisplayPreference = Always` chủ động (verify từ `terminaloverlay.cc:434` + `transportsender.h:49`). Với PTY-over-LAN round-trip 1–5ms, echo từ server tới trước khi user kịp nhận ra → **bỏ prediction cho v1**. Prediction engine là transport-agnostic (chứng minh bởi nosshtradamus chạy nó trên SSH/TCP) nên có thể thêm sau nếu cần cho Wi-Fi.

---

### 6. App Sandbox — ràng buộc kiến trúc cứng

**Host component bắt buộc KHÔNG sandbox.** App sandboxed **không thể** `forkpty()`/`execvp()` spawn login shell tùy ý — sandbox chặn exec process ngoài không khai báo trong entitlement, và không có entitlement nào whitelist shell tùy ý. Pattern Apple chấp nhận:

1. **Non-sandboxed app qua Developer ID** (ngoài Mac App Store) — đa số dev tool (Xcode, VS Code, iTerm2, Terminal.app) đều không sandbox. **Đây là cách chuẩn cho công cụ dev** và gỡ mọi ràng buộc trên forkpty/PTY/socket.
2. Hoặc non-sandboxed LaunchAgent/XPC helper giao tiếp với app sandboxed.

Vì đường video cũng đã cần non-sandboxed cho Accessibility/CGEvent (xem [06](06-permissions-distribution.md)), quyết định "host = non-sandboxed Developer ID app" thống nhất cả hai đường. Client viewer (chỉ render + gửi byte) **có thể** lên Mac App Store.

---

### 7. Tổng kết & việc cho roadmap

| Tiêu chí | Terminal path | Video path |
|----------|---------------|------------|
| Input-injection problem | **Biến mất hoàn toàn** | Còn nguyên (CGEvent + SkyLight SPI) |
| TCC permission | Không cần (chỉ network) | Accessibility + Screen Recording |
| Sandbox | Phải non-sandbox (spawn shell) | Phải non-sandbox (Accessibility) |
| Bandwidth idle | ~0 | ~0 (nếu guard `.complete`) |
| Độ nét text | Sắc nét tuyệt đối | 4:2:0 mờ nhẹ (chấp nhận) |
| Độ khó / rủi ro | low / native | medium / private SPI |
| Thư viện chủ lực | **libghostty** (full surface, patch tự-own) + host PTY bridge | ScreenCaptureKit + VideoToolbox |

**Việc cho Phase 1 (terminal-first):**
- [ ] Host helper non-sandboxed: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()`, setup env (`TERM`/`LANG`/`IUTF8`), `DispatchIO` read loop, `TIOCSWINSZ` resize.
- [ ] Wire protocol 1-byte-type + 4-byte-len qua `NWConnection` TCP; resize message riêng.
- [ ] Client: **libghostty** full surface — **patch external-backend tự maintain** (ref `daiimus/ghostty` External.zig), build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA; `ghostty_surface_feed_data` ← network, write-callback → PTY stdin host, resize → surface API.
- [ ] Xác nhận bằng prototype: **không** có CGEvent/Accessibility call nào trong đường phím client.
- [ ] (v2) Window picker để chọn cửa sổ GUI → kích hoạt video-path on-demand.

---


## Terminal text-streaming (SSH/mosh-class) — thiết kế

Đây là **nửa mạnh hơn** của kiến trúc hybrid. Khác với GUI window path (ScreenCaptureKit → HEVC → CGEvent inject), terminal path **sở hữu shell** giống `ssh`/`mosh`: host spawn login shell trong một POSIX pseudo-terminal, stream **raw byte stream** (VT escape sequences) về client, và keystroke được ghi **thẳng vào PTY stdin**. Hệ quả kiến trúc lớn nhất: path này **né hoàn toàn giới hạn CGEvent/Accessibility injection của macOS** — input chỉ là bytes ghi vào một file descriptor, không có synthetic keyboard event, không cần TCC `kTCCServicePostEvent`, không activate-then-control. Text crisp by construction, bandwidth cực nhỏ (idle = 0 byte), không codec artifact.

---

### 1. Host PTY bridge — exact APIs

#### 1.1 Cấp phát PTY: `forkpty()` vs `openpty()` + `posix_spawn`

Có hai con đường, cả hai đều native Darwin (`<util.h>`):

**`forkpty()` — one-call PTY + fork + exec.** `forkpty(&master, NULL, NULL, &winsize)` atomically cấp phát cặp PTY, gọi `fork()`, gọi `login_tty()` ở child, trả về master FD ở parent; child `execvp()` login shell. Đây là path production của SwiftTerm (`Pty.swift` → `PseudoTerminalHelpers.fork(andExec:)`) — master FD trở thành kênh I/O hai chiều duy nhất cho toàn bộ terminal ([SwiftTerm/Pty.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift)).

> ⚠️ **CORRECTION — "forkpty() không an toàn từ Swift" (verified):** Claim này **directionally đúng nhưng bị nói quá**. Quinn (Apple DTS, [forum thread/747499](https://developer.apple.com/forums/thread/747499)) xác nhận: nguy hiểm thật sự là chạy code Swift/ObjC/libdispatch **trong child process sau fork() trước khi exec()** — ObjC runtime crash guard (`objc_initializeAfterForkError`, từ macOS 10.13) sẽ kill child nếu một `+initialize` đang chạy ở thread khác lúc fork. **Bản thân lời gọi `forkpty()` ở parent KHÔNG nguy hiểm.** SwiftTerm gọi `forkpty()` trực tiếp từ Swift trong production (Secure Shellfish, La Terminal, CodeEdit) không có crash, vì nó tuân thủ pattern fork-then-exec-immediately: chuẩn bị mọi C string bằng `strdup()` **trước** fork, rồi trong child chỉ gọi `chdir()` + `execve()` + `_exit()` — thuần POSIX, không có Swift runtime sau fork. Vấn đề này **không liên quan** đến Swift 5.9/6 concurrency model (actors/async-await); không có API mới nào nới lỏng ràng buộc. Để loại bỏ hoàn toàn class nguy hiểm, dùng path thứ hai.

**`openpty()` + `posix_spawn` — workaround được Apple khuyến nghị.** `openpty(&master, &slave, NULL, &termp, &winp)` cấp cặp PTY **không fork**; child launch qua `posix_spawn` với `posix_spawn_file_actions_t` redirect stdin/stdout/stderr về slave FD, `POSIX_SPAWN_SETSID` tạo session mới, và `login_tty(slave)` gọi trong pre-spawn configurator. Pattern này **không bao giờ gọi fork() từ Swift** nên loại bỏ hẳn ObjC runtime lock hazard — đây chính là điều LLVM sanitizer_common làm ([D65253](https://reviews.llvm.org/D65253)) và là hướng SwiftTerm đang migrate sang qua `swift-subprocess`.

> ✅ **VERIFIED — `POSIX_SPAWN_SETSID` qua `preSpawnProcessConfigurator` là API production thật** trong `swiftlang/swift-subprocess` (lưu ý: repo canonical là `swiftlang/`, **không** phải `apple/swift-subprocess`). `PlatformOptions.preSpawnProcessConfigurator` là `public`, không guard, có test live (`testSubprocessPlatformOptionsProcessConfiguratorUpdateSpawnAttr`). Tuy nhiên trong **SwiftTerm hiện tại**, path Subprocess bị guard `#if false //canImport(Subprocess)` (5 chỗ trong `LocalProcess.swift`) → **chưa active**; default vẫn là `startProcessWithForkpty`.

> ✅ **VERIFIED — `posix_openpt()` KHÔNG "broken" trên macOS** (claim bị refuted). Claim gốc gán nhầm thread (thực ra là [thread/734230](https://developer.apple.com/forums/thread/734230), không phải 688534) và mô tả sai. Sự thật: `posix_openpt()` hoạt động đầy đủ trên macOS 14/15; `openpty()` của Apple **gọi `posix_openpt()` bên trong** (Libc `util/pty.c:78`). Giới hạn thực tế **rất hẹp**: gọi `fcntl(masterFd, F_SETFL, O_NONBLOCK)` sẽ fail `EINVAL` **nếu slave chưa được open** — fix là open slave trước khi set non-blocking trên master. `openpty()` né được vì nó tự open slave.

#### 1.2 Async read trên master FD: `DispatchIO`

Sau khi có master FD, wrap trong `DispatchIO(type: .stream, fileDescriptor: masterFd)`:

```swift
let io = DispatchIO(type: .stream, fileDescriptor: masterFd, queue: readQueue) { err in
    close(masterFd)              // ⚠️ close trong cleanupHandler, KHÔNG trong deinit (tránh EV_VANISHED crash)
}
io.setLimit(lowWater: 1)
io.setLimit(highWater: 131_072)  // 128 KB — hấp thụ burst lớn (cat file to)
// chain read trong completion handler; coalesce theo timeslice 4ms trước khi dispatch lên transport
```

SwiftTerm dùng `pendingChunks` queue với **timeslice 4ms** (`pendingTimeSliceNs = 4_000_000`) để gộp burst, `readSize = 128*1024`, compact khi vượt `pendingChunkFlushThreshold = 32` chunks. Theo dõi shell exit không poll bằng `DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit)` rồi `waitpid(shellPid, &n, WNOHANG)` ([SwiftTerm/LocalProcess.swift](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/LocalProcess.swift)).

#### 1.3 Resize: `TIOCSWINSZ` + `SIGWINCH`

Khi client báo kích thước mới, gọi `ioctl(masterFd, TIOCSWINSZ, &winsize)` trên master FD; kernel gửi `SIGWINCH` tới foreground process group, shell + vim/tmux re-query `TIOCGWINSZ` và reflow. Struct `winsize { ws_col, ws_row, ws_xpixel=0, ws_ypixel=0 }`. Trên macOS hằng `TIOCSWINSZ` typed là `Int32` (Linux cần cast `UInt`). Đây là điều SwiftTerm `setWinSize()` và mosh-server làm khi nhận `Resize` action ([SwiftTerm/Pty.swift:119](https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Pty.swift), [mosh-server.cc](https://github.com/mobile-shell/mosh/blob/master/src/frontend/mosh-server.cc)). Bandwidth ~0 — resize là control event hiếm.

#### 1.4 Login shell setup — env vars bắt buộc

Set trước `execvp` ở child:

| Biến | Giá trị | Lý do |
|------|---------|-------|
| `TERM` | `xterm-ghostty` (fallback `xterm-256color` nếu gặp paste bug #54700 — xem [14]) | khớp libghostty client + kitty keyboard |
| `LANG` | `en_US.UTF-8` | **critical** — thiếu thì vi/ncurses phát ISO 2022 sequences |
| `COLORTERM` | `truecolor` | true-color terminal |
| `NCURSES_NO_UTF8_ACS` | `1` | ép ncurses dùng UTF-8 box-drawing thay vì VT100 line-drawing |
| termios `c_iflag` | `\|= IUTF8` | backspace-over-multibyte đúng |
| `argv[0]` | prepend `-` (vd `-zsh`) | login shell → source `.zprofile`/`.zshrc` |

**KHÔNG** forward `PATH` mù từ server process. Mirror `LOGNAME/USER/HOME/DISPLAY` từ parent. Reference: `SwiftTerm.Terminal.getEnvironmentVariables()`; mosh thêm `unset STY` (chống GNU screen tưởng bị nested).

> ✅ **VERIFIED — `IUTF8` có sẵn trên Darwin.** XNU `bsd/sys/termios.h:133` định nghĩa `IUTF8 = 0x00004000` dưới guard `#if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)` → hiện diện dưới mọi build non-strict-POSIX. Lưu ý: flag chỉ ảnh hưởng **canonical-mode VERASE**; trong raw PTY mode (terminal mode điển hình) nó vô tác dụng — nhưng vẫn nên set cho đúng.

#### 1.5 App Sandbox — quyết định kiến trúc, không phải runtime

Một app sandboxed **không thể** `forkpty()`/`execvp()` shell tùy ý — sandbox chặn exec process không khai báo trong entitlements, và **không có entitlement nào** whitelist arbitrary shell. Các pattern được Apple chấp nhận:

1. **App non-sandboxed phân phối qua Developer ID** (ngoài Mac App Store) — chuẩn cho dev tool (Xcode, VS Code, iTerm2, Terminal.app đều **không** sandboxed). **Khuyến nghị cho host component.**
2. LaunchDaemon/LaunchAgent helper non-sandboxed, giao tiếp với app sandboxed qua XPC hoặc local socket.
3. Privileged helper qua `SMJobBless`/`SMAppService`.

Kết luận: **host component phải non-sandboxed**. Mac App Store distribution **không tương thích** với arbitrary shell spawning qua `forkpty`. Bật **Hardened Runtime** (`codesign -o runtime`) cho helper để chặn dylib injection (`DYLD_INSERT_LIBRARIES`); helper spawn PTY **không cần** entitlement đặc biệt — nhưng **không được** thêm `com.apple.security.cs.disable-library-validation`. Chạy shell **dưới logged-in user, không phải root**; shell binary cố định (`$SHELL` từ `/etc/passwd`), **không cho client chỉ định** path/env (bài học từ ET CVE GHSA-hxg8-4r3q-p9rv: client-supplied path đi vào privileged file op → escalation).

---

### 2. Transport — chọn reliable TCP, không mosh-SSP UDP

Đây là quyết định kiến trúc trọng yếu và corpus rất rõ: **trên LAN, dùng plain TCP byte relay qua Network.framework. KHÔNG port mosh SSP.**

| | TCP byte relay (ET-style) | mosh SSP (UDP state-sync) |
|--|---------------------------|---------------------------|
| Đơn vị | raw PTY bytes verbatim | terminal **state diff** (framebuffer) |
| Loss tolerance | TCP lo (LAN loss ~0) | idempotent datagram, bỏ qua loss |
| Crypto | TLS 1.3 (CryptoKit/Security) sẵn | **AES-128-OCB3** |
| Server emulator | **không cần** (stateless relay) | **phải chạy full emulator** (`Terminal::Complete`) |
| Code | tối thiểu | phức tạp (state machine, fragmentation, fec) |
| Phù hợp | **LAN <1ms RTT** | lossy WAN |

Lý do dứt khoát: trên LAN, RTT điển hình **<1ms** và loss <0.01% → TCP head-of-line blocking **không đáng kể**, mosh-style frame-skipping **không cho lợi ích gì** so với TCP raw streaming, trong khi độ phức tạp implementation lớn hơn nhiều. Mosh SSP tối ưu cho 29% packet loss link (SSH 16.8s → SSP 0.33s, 50× — [mosh paper](https://mosh.org/mosh-paper.pdf)) — một tình huống **không tồn tại** trên LAN dây.

> ⚠️ **CORRECTION — AES-128-OCB không có trong CryptoKit** (verified, confirmed). Nếu vì lý do nào đó muốn port SSP, biết rằng CryptoKit **chỉ** expose `AES.GCM` và `ChaChaPoly`, **không** có `AES.OCB`. CommonCrypto cũng **không** expose OCB như một mode (không có `kCCModeOCB`). Ba lựa chọn: (1) port `ocb_internal.cc` của mosh dùng CommonCrypto chỉ làm raw AES block cipher backend (đúng cách mosh build trên macOS), (2) link OpenSSL riêng dùng `EVP_aes_128_ocb()`, hoặc (3) thay OCB bằng AES-GCM + CryptoKit native, chấp nhận wire-format khác mosh. Vì ta **không** dùng SSP, điểm này chỉ là cảnh báo — dùng **TLS 1.3 / AES-GCM native** trên TCP.

#### Wire protocol — type-prefix framing (ttyd-style)

Đơn giản nhất cho LAN, gộp được resize cùng data:

```
[1-byte type] [4-byte big-endian length] [raw payload]
  type 0 = terminal data (raw PTY bytes verbatim)
  type 1 = resize {cols, rows}
```

ttyd dùng đúng pattern này: server→client `'0'`=OUTPUT, client→server `'0'`=INPUT, `'1'`=RESIZE ([ttyd/protocol.c](https://github.com/tsl0922/ttyd/blob/main/src/protocol.c)). **Không JSON trên hot path** (terminal bytes). Transport là `NWConnection(.tcp)`: `NWListener` ở host, `NWConnection` ở client; framing thủ công 4-byte length hoặc `NWProtocolFramer`. SSH RFC 4254 channel model (multiplexing, flow-control window) là **overkill** cho LAN one-connection-per-session — chỉ mượn cấu trúc payload `window-change` (cols/rows uint32) nếu cần ([RFC 4254](https://datatracker.ietf.org/doc/html/rfc4254)).

> 📋 **Claim cần verify khi implement:** `NWProtocolFramer` xử lý arbitrary byte sequences (không treat as text) và không có min-MTU constraint fragment keystroke nhỏ. Test trước khi cố định.

Idle efficiency tự nhiên: master FD **không sinh byte khi shell idle** → 0 byte flow, không encode/decode. Đây là đòn bẩy hiệu năng quan trọng nhất cho coding tool (màn hình tĩnh phần lớn thời gian).

---

### 3. Mosh-style predictive local echo — ⏸️ DEFERRED (assume P2P)

> ⏸️ **ĐÃ DEFER cho v1** (quyết định cuối: assume NetBird direct P2P ~1–5ms, drop prediction — xem [13 §4], Phase 5). Phần phân tích dưới giữ làm **reference** nếu sau này relay phổ biến.
>
> 🔎 **Cập nhật (xem [17 §2.4]):** lý do *không* làm full predictor mạnh hơn cả RTT-thấp: (1) `ghostty_surface_t` opaque → buộc dựng **VT parser thứ 2** giữ shadow-framebuffer (desync-risk); (2) **Claude Code TUI dùng alt-screen** → Mosh tự tắt prediction ở đó, lợi ích chỉ còn ở bare shell prompt. Thay thế rẻ Phase 2 = **glitch-window caret** (chỉ track cột cursor, không shadow parser).

Đây là kỹ thuật đáng port nhất từ mosh, **độc lập với transport**. Engine dự đoán kết quả keystroke và render **tức thì** (trước khi packet rời NIC), gạch chân `underline` cho ký tự chưa xác nhận, tự sửa khi server state thật về. Đánh giá gốc (USENIX ATC 2012, 40h / 9 986 keystrokes): **70% keystroke hiển thị tức thì** với confident prediction, chỉ **0.9%** cần within-RTT correction.

#### Engine là portable logic, không phụ thuộc OS

> ✅ **VERIFIED — PredictionEngine fully transport-agnostic.** `terminaloverlay.cc` **không** include bất kỳ class `Network::` nào. Engine chỉ cần **4 giá trị** inject qua plain setters: `local_frame_sent`, `local_frame_acked`, `local_frame_late_acked` (echo_ack từ remote state), `send_interval` (= `ceil(SRTT/2)` clamp `[20,250]`ms). nosshtradamus (thyth/nosshtradamus) đã chứng minh engine chạy trên **TCP/SSH** qua side-band ping reconstruct 4 biến này. Tức là: với TCP byte-stream của ta, chỉ cần maintain epoch counter + RTT estimate → engine chạy nguyên vẹn.

Cơ chế cốt lõi (`terminaloverlay.h/.cc`):
- **`new_user_byte(byte)`**: ký tự printable ASCII (0x20–0x7e, width 1) → advance predicted cursor, lưu `ConditionalOverlayCell` tại `(row,col)`, tag `prediction_epoch` hiện tại.
- **`apply(server_fb)`**: layer overlay lên server framebuffer trước khi compute display diff.
- **Backspace (0x7f)**: decrement cursor.col, shift line trái (mỗi cell = cell bên phải), cell phải cùng đánh `unknown=true` (render underline).
- **Epoch self-correction**: khi server-confirmed khác predicted, gọi `kill_epoch(tentative_until_epoch)` → xóa mọi prediction tentative của epoch đó, `become_tentative()` tăng `prediction_epoch`. Misprediction chỉ kill epoch hiện tại; prediction cũ đã confirmed giữ nguyên. **Control char (arrow, Escape) cũng gọi `become_tentative()`** vì không đoán được.
- **Paste suppression**: nếu `bytes_read > 100` (bulk paste) → `reset()` toàn bộ prediction (tránh flicker khi shell/readline re-wrap).

#### ⚠️ CORRECTION quyết định cho LAN: dùng `DisplayPreference = Always`

> ✅ **VERIFIED (confirmed) — Trên LAN, Adaptive mode cho ZERO local echo.** Trong `cull()`, `srtt_trigger` chỉ flip `true` khi `send_interval > SRTT_TRIGGER_HIGH=30ms` (strict). Mà `send_interval = max(ceil(SRTT/2), 20)` → với **bất kỳ SRTT < ~40ms**, `send_interval = 20ms`, **không** > 30 → trigger im. Với `display_preference == Adaptive`, `apply()` render khi `srtt_trigger || glitch_trigger`; cả hai false → **render rỗng**. Trigger chỉ bật khi SRTT ≥ ~61ms. **Kết luận:** trên LAN-direct (1–5ms) prediction gần như vô ích → **DEFER**. NẾU sau này relay phổ biến mới bật, khi đó set `DisplayPreference=Always`.

Hằng số tham khảo (đã verify): `SRTT_TRIGGER_HIGH=30`, `SRTT_TRIGGER_LOW=20`, `FLAG_TRIGGER_HIGH=80`, `FLAG_TRIGGER_LOW=50`, `GLITCH_THRESHOLD=250ms`, `GLITCH_FLAG_THRESHOLD=5000ms`, `SEND_MINDELAY=8ms` (client set `set_send_delay(1)`=1ms), `SEND_INTERVAL_MIN=20ms`, paste suppression `>100` bytes.

#### Hai lựa chọn implementation

Engine `terminaloverlay.cc` ~750 dòng C++. Hai hướng: (a) **CGo/C interop** (như nosshtradamus dùng go-mosh) — tái dùng code đã battle-tested; (b) **port thuần Swift** — sạch hơn cho native app, tránh C bridge. Corpus không tìm thấy Swift port có sẵn → đây là implementation work thật. **Lưu ý:** vì libghostty opaque (không expose cell grid), full engine cần shadow VT parser riêng client-side — chính lý do **không** làm cho v1 ([17 §2.4]). Nếu Phase 2 cần, đây là điểm tích hợp.

---

### 4. Client renderer — libghostty (only)

Renderer = **libghostty full surface**; quyết định + công thức patch external-backend đã ở §3.1 "Render client — libghostty". **KHÔNG dùng SwiftTerm** (triết lý best-only, no fallback). Wiring: `ghostty_surface_feed_data` ← network bytes; write-callback (`use_custom_io`) → PTY stdin; bọc sau protocol `TerminalRendering` để cô lập C-ABI. (SwiftTerm `Pty.swift`/`LocalProcess.swift` chỉ còn dùng làm *citation* cho POSIX PTY pattern ở Part B §1, không phải dependency.)

### 5. Resize / encoding / scrollback

- **Resize**: client `sizeChanged` delegate → message type 1 → host `ioctl(masterFd, TIOCSWINSZ, &winsize)` → `SIGWINCH` (§1.3). Zero bandwidth.
- **Encoding**: UTF-8 end-to-end. `LANG=en_US.UTF-8` + `IUTF8` + `NCURSES_NO_UTF8_ACS=1` (§1.4). libghostty xử lý grapheme cluster/emoji ở client.
- **Scrollback**: **client-side only**. PTY raw **không có scrollback** — byte đã read là mất khỏi OS buffer. libghostty surface giữ scrollback nội bộ (cấu hình qua surface config). **Server stateless byte relay** → zero cost. Tùy chọn: server giữ **ET-style seq replay buffer** (§6, [17 §2.3]) cho reconnect.

---

### 6. Reconnect / roaming

#### ET-style packet-framed buffering — đúng cách

Eternal Terminal `BackedWriter`/`BackedReader` là prior-art trực tiếp: buffer các **packet hoàn chỉnh** đánh `sequenceNumber` (deque, cap `MAX_BACKUP_BYTES = 64MB`). Reconnect: client gửi reader `sequenceNumber` trong `SequenceHeader` protobuf → server `recover(lastValidSeq)` tính số packet retransmit → đóng gói `CatchupBuffer` → cả hai `revive(newFd)`. **Đơn vị là packet hoàn chỉnh, không phải raw byte slice** → replay luôn bắt đầu ở packet boundary, **loại bỏ structural mid-escape-sequence truncation hazard** ([BackedWriter.cpp](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/BackedWriter.cpp), [Connection.cpp:96-141](https://github.com/MisterTea/EternalTerminal/blob/master/src/base/Connection.cpp)). Reconnect overhead: ~1 RTT cho sequence exchange.

> ⚠️ **Data-loss boundary cần xử lý:** ET `DISCONNECT_BUFFER_BYTES = 4MB` — khi disconnected và buffer vượt 4MB, `write()` trả `SKIPPED` (drop output mới). Với build dài chạy lúc client offline, output có thể mất. Cân nhắc tăng disconnect buffer (bounded by RAM) cho coding use-case.

#### Fallback raw-byte path: DECSTR prefix

> Ta dùng **ET packet-framed buffering** (ở trên) làm đường chính — đây chỉ là ghi chú kỹ thuật cho trường hợp raw-byte replay.

Nếu **không** dùng packet framing mà replay raw VT bytes từ ring buffer, **feed `ESC [ ! p` (DECSTR, Soft Terminal Reset) vào `ghostty_surface_feed_data` trước khi replay tail**. DECSTR reset cursor visibility, insert/origin/autowrap mode, G0–G3, SGR, cursor home, scroll margin — đúng modal state gây corrupt khi replay mid-sequence. (libghostty opaque không có hàm `softReset()` riêng → đẩy chính các byte DECSTR vào stream; cùng VT parser của Ghostty xử lý.) DECSTR **không** loại bỏ hoàn toàn hazard nếu escape sequence straddle wrap point → kết hợp **sync-point marker** (host phát no-op DCS định kỳ, client scan marker cuối, discard trước đó). Vì đường chính là packet-framed (replay bắt đầu ở packet boundary), hazard này **không phát sinh** — đó là lý do chọn ET-style.

#### Persistent PTY — sống sót mọi disconnect

PTY/shell phải sống độc lập với TCP connection: **helper process giữ master FD**, không phải per-client connection handler. Vì helper sở hữu master FD, đóng client socket **không** gây kernel gửi `SIGHUP` cho shell process group. Hai cách: (a) **host daemon persistent** (launchd `KeepAlive=true`) giữ `[UUID: PTYSession]`; (b) **tmux** (v2 upgrade) — server process giữ mọi master FD, session sống vô hạn, reconnect = `tmux -CC attach`, đồng thời cho server-side scrollback + window/pane mapping miễn phí (iTerm2 `TmuxGateway.m` ~884 dòng là reference). Thêm idle-kill timer cấu hình (vd 48h) để tránh tích lũy shell mồ côi.

#### iOS lifecycle + roaming

- **iOS background**: ~30s budget (`beginBackgroundTask`), socket bị OS reclaim khi suspend (TN2277). **KHÔNG cố giữ socket sống qua suspension.** Pattern đúng: scenePhase `.background` → `connection.cancel()` + mark disconnected; scenePhase `.active` → tạo `NWConnection` mới + ET sequence exchange resume. Brief network gap (không có app lifecycle event) → dựa `NWConnection` state `.waiting` với `waitingForConnectivity` tự advance về `.ready`.
- **macOS host wake**: lid-close **ép sleep bất kể** `IOPMAssertion` type. Subscribe **`NSWorkspaceDidWakeNotification`** (NSWorkspace center, không phải defaultCenter) → re-listen `NWListener`, check `NWPathMonitor` trước khi accept. `NSActivityUserInitiated` chặn App Nap + idle sleep nhưng **không** chặn lid-close sleep. (📋 Verify: launchd KeepAlive daemon non-GUI có nhận `NSWorkspace` notification reliably không — cần CFRunLoop chạy.)
- **macOS client Wi-Fi↔Ethernet roaming**: `NWPathMonitor.pathUpdateHandler` fire khi dock/undock; `NWConnection.viabilityUpdateHandler(false)` là signal cancel + tạo connection mới + sequence exchange. Vì `BackedWriter` buffer persist in-process (không gắn socket), catchup deliver output buffered ngay sau 1-RTT.

---

### Tóm tắt khuyến nghị (implementation-ready)

| Hạng mục | Quyết định |
|----------|-----------|
| PTY cấp phát | `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` (tránh fork-in-Swift hazard); hoặc `forkpty()` với fork-then-exec-immediately strict |
| Async I/O | `DispatchIO(.stream)` lowWater=1, highWater=128KB, close trong cleanupHandler |
| Resize | `ioctl(TIOCSWINSZ)` → SIGWINCH |
| Sandbox | host **non-sandboxed** Developer ID, Hardened Runtime, chạy as logged-in user |
| Transport | **TCP** qua Network.framework, type-prefix framing (ttyd-style), **no app-layer TLS** (WireGuard encrypt, [13]). **KHÔNG mosh SSP/UDP** |
| Local echo | ⏸️ DEFERRED (assume P2P; revisit chỉ khi relayed) |
| Client emulator | **libghostty** full surface (patch tự-own, Metal GPU, ligature OK) — **không SwiftTerm** |
| Scrollback | client-side (libghostty surface giữ scrollback nội bộ); server stateless + ET-style seq replay buffer cho reconnect ([17 §2.3]) |
| Reconnect | ET packet-framed sequence buffer (64MB cap, lưu ý 4MB disconnect SKIPPED); persistent PTY helper (v1) → tmux `-CC` (v2) |
| iOS/roaming | eager reconnect on scenePhase `.active`; `NWPathMonitor` + `NSWorkspaceDidWakeNotification` |

Sources chính: [SwiftTerm Pty.swift / LocalProcess.swift / Terminal.swift / AppleTerminalView.swift](https://github.com/migueldeicaza/SwiftTerm), [mosh terminaloverlay.cc / transportsender-impl.h / network.cc](https://github.com/mobile-shell/mosh), [Eternal Terminal BackedWriter/BackedReader/Connection](https://github.com/MisterTea/EternalTerminal), [ttyd protocol.c](https://github.com/tsl0922/ttyd), [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess), [nosshtradamus](https://github.com/thyth/nosshtradamus), Apple [Network.framework](https://developer.apple.com/documentation/network/nwconnection) / [forum thread 747499](https://developer.apple.com/forums/thread/747499) / [thread 734230](https://developer.apple.com/forums/thread/734230), XNU `bsd/sys/termios.h`.

---

## GUI video path (4:2:0 đủ tốt) — đơn giản hóa

> Re-scope: yêu cầu "text crispness" đã được **bỏ** cho path video. Mọi cửa sổ GUI (VS Code, Xcode, browser…) đi qua **ScreenCaptureKit → VideoToolbox HEVC 4:2:0 → Network.framework → decode → Metal**. Path terminal (PTY text) gánh toàn bộ phần text "căng" nhất, nên codec video không còn phải gồng vì text. Tài liệu này thay thế tư duy "tối ưu motion-to-photon < 16ms" của các doc trước bằng tư duy **idle-efficiency + encode-on-change** cho màn hình gần như tĩnh.

---

### TL;DR (GUI video path)

- **4:2:0 HEVC là đủ tốt** cho đọc code trong cửa sổ GUI. Luma (Y) giữ full resolution → cạnh glyph vẫn sắc; chỉ chroma (Cb/Cr) bị subsample → fringing màu nhẹ ở biên màu gắt. Với dark theme (chữ sáng trên nền tối) fringing càng ít lộ. (`claim_to_verify`: "tolerable" là đánh giá chủ quan, phải user-test ở đúng resolution/bitrate đích — xem §6.)
- **4:4:4 bị bỏ hẳn**, không phải vì lười: **Apple HW encoder không có 4:4:4 cho HEVC**. Toàn bộ `kVTProfileLevel_HEVC_*` trong SDK (qua iOS/visionOS 26, 2025) chỉ có Main / Main10 / Main42210 / Monochrome / Monochrome10 — **không tồn tại** profile SCC hay 4:4:4 streaming. Đổi codec không sửa được; đây là giới hạn phần cứng, không phải lựa chọn cấu hình.
- **Các đòn bẩy THẬT SỰ quan trọng giờ là idle-efficiency**, không phải latency: `SCFrameStatus.idle` (zero-encode khi tĩnh) + `dirtyRects` (encode vùng đổi) + `minimumFrameInterval` cap **~24–30 fps** (đủ dùng, giảm băng thông/latency/CPU) + CQ. Màn hình code phần lớn đứng yên → bitrate trung bình tiến gần 0 khi idle, chỉ burst khi gõ/scroll/compile.

---

### 1. Vì sao 4:2:0 đủ tốt (và 4:4:4 bị bỏ)

### 1.1 Cơ chế: luma sắc, chroma mới subsample

ScreenCaptureKit capture frame ở `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) — pixel format rẻ CPU nhất cho VideoToolbox HEVC. 4:2:0 chỉ giảm độ phân giải chroma theo cả ngang lẫn dọc; **kênh luma vẫn full resolution**, mà cạnh chữ (độ tương phản sáng/tối) sống chủ yếu ở luma. Hệ quả:

- Text trắng/xám trên nền tối (VS Code Dark+, Xcode dark): gần như không thấy hại — biên do luma quyết định.
- Text màu trên nền màu gắt (syntax highlight đỏ/xanh trên nền sáng): fringing chroma nhẹ, "mềm" hơn local display nhưng vẫn đọc thoải mái cho daily coding.

Nguồn: ScreenCaptureKit pixel-format guidance (WWDC22 10155); so sánh codec screen-sharing (Microsoft Azure Virtual Desktop graphics-encoding docs).

### 1.2 4:4:4 bị bỏ là vì phần cứng, không phải vì re-scope

Đây là điểm cần nói rõ để không ai sau này định "bật lại 4:4:4 cho nét":

- **Đã verify (confidence: high):** danh sách đầy đủ `kVTProfileLevel_HEVC_*` trong `VTCompressionProperties.h` xuyên suốt mọi SDK từ macOS 10.13 / iOS 11 đến iOS/visionOS 26 (2025) chỉ gồm `Main_AutoLevel` (8-bit 4:2:0), `Main10_AutoLevel` (10-bit 4:2:0), `Main42210_AutoLevel` (10-bit 4:2:2), `Monochrome`, `Monochrome10`. **Không có** `kVTProfileLevel_HEVC_SCC_*` hay biến thể 4:4:4. FFmpeg `videotoolboxenc.c` cũng chỉ load đúng ba symbol HEVC encoder-facing đó. (Nguồn: VTCompressionProperties.h trong xybp888/iOS-SDKs; FFmpeg videotoolboxenc.c lines 122-197.)
- **HEVC-SCC (palette mode, intra block copy) cũng không có** trên VideoToolbox — các công cụ tối ưu riêng cho screen content nằm ngoài cả API surface lẫn (suy ra) khối hardware. Đối thủ như Parsec/Moonlight coi 4:4:4 là đòn bẩy số 1 cho UI/text, nhưng họ bật được nhờ HW encode 4:4:4 của Intel/Nvidia — thứ Apple không có.

→ Vì path terminal đã gánh text căng nhất, **chấp nhận 4:2:0 cho GUI là quyết định kiến trúc đúng**, không phải compromise miễn cưỡng.

---

### 2. Đòn bẩy #1 — `SCFrameStatus.idle`: zero-encode khi tĩnh

Mỗi `CMSampleBuffer` ScreenCaptureKit giao kèm attachment `SCStreamFrameInfo`; key `.status` trả về `SCFrameStatus`. WWDC22 (session 10156) nói nguyên văn: *"An idle frame status means the video sample hasn't changed, so there's no new IOSurface."*

Pattern bắt buộc — guard **trước** khi submit vào encode queue:

```swift
guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, ...),
      let statusRaw = attachments.first?[SCStreamFrameInfo.status] as? Int,
      SCFrameStatus(rawValue: statusRaw) == .complete else {
    return   // .idle / .blank / .suspended → bỏ, KHÔNG encode
}
// chỉ .complete mới có IOSurface mới → đưa vào VTCompressionSessionEncodeFrame
```

**Lưu ý quan trọng (verdict: uncertain, confidence: medium):**
- "Không có IOSurface mới" được Apple xác nhận. Nhưng **"zero GPU work / zero encode" KHÔNG phải thuộc tính của OS** — ScreenCaptureKit không tự encode; encode là việc của app. Idle = zero encode **chỉ khi** app áp guard `status == .complete` trước mọi lời gọi VideoToolbox. Đây chính là pattern Apple khuyến nghị trong sample code.
- Callback **vẫn fire** cho frame idle (bằng chứng: sample code Apple dùng `guard status == .complete else { return }`; OBS route mọi callback không điều kiện rồi mới nil-check IOSurface). Do đó **đừng giả định** thread encode được tự sleep khi idle — nếu muốn ngủ thread encode để tiết kiệm pin, phải tự quản lý dựa trên việc đã lâu không có `.complete` (`open_question`: tần suất callback idle có đúng theo `minimumFrameInterval` hay bị suppress hẳn — Apple forum thread/718356 không rõ ràng).

Tác động: trong lúc đọc/suy nghĩ/debug, màn hình đứng yên hàng giây → bitrate encode+truyền **về 0** một cách tự nhiên, do OS phát tín hiệu idle trực tiếp, không cần timer/poll.

---

### 3. Đòn bẩy #2 — `dirtyRects`: encode-on-change theo vùng

`SCStreamFrameInfo.dirtyRects` (key `.dirtyRects`) trả `[CGRect]` trong toạ độ content, chỉ đúng các vùng đổi so với frame trước (cursor blink, một dòng code, gutter scroll…). WWDC22 (10155) khuyến nghị thẳng: *"use dirty rects to only encode and transmit the regions with new updates, and copy the updates onto the previous frame on the receiver side."*

Hai pattern, chọn theo độ phức tạp chấp nhận được:

| Pattern | Cách làm | Đánh giá |
|---------|----------|----------|
| **A — full-frame + gửi kèm dirtyRects** | Vẫn encode full frame bằng VideoToolbox, nhưng gửi kèm danh sách dirtyRects để receiver chỉ composite vùng đổi lên frame cũ đã cache | Đơn giản, hợp với VideoToolbox (encode nguyên frame). Khuyến nghị cho v1. |
| **B — crop-encode chỉ vùng dirty** | Encode/truyền tile vùng đổi | Cần tiling / điều khiển macroblock ở mức VideoToolbox không expose → phức tạp. Hoãn. |

Tác động: khi chỉ một pane đổi (autocomplete popup, scroll output build trong khi pane khác tĩnh), payload giảm mạnh. Kết hợp với idle-skip → bitrate trung bình cả phiên thấp xa peak.

`open_question`: tỉ lệ dirty thực tế của một phiên coding (autocomplete, cursor blink, scroll) là bao nhiêu phần frame — quyết định liệu pattern B có đáng làm hơn full-frame VBR không. Cần đo thực tế.

---

### 4. Đòn bẩy #3 — variable / low fps

`SCStreamConfiguration.minimumFrameInterval` (CMTime) cap tốc độ giao frame. **Chốt: cap ~24–30 fps** (đủ mượt khi scroll/gõ, giảm băng thông/latency/CPU vs 60fps). (Apple WWDC22 10156 còn gợi ý 10fps cho text rất tĩnh — ta chọn 24–30 để scroll mượt hơn.)

```swift
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // cap ~30 fps; idle-skip giữ near-zero khi tĩnh
config.queueDepth = 3                                            // default thực=8; dùng 2–3 cho latency thấp ([11]); release surface nhanh
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12 4:2:0
```

- Hai cơ chế bổ trợ nhau: **idle-skip** xử lý lúc tĩnh; **minimumFrameInterval** cap tốc độ lúc có chuyển động.
- Với coding, **24–30 fps** là điểm cân bằng (mượt khi scroll, mà vẫn ~nửa băng thông/CPU của 60fps). Cap 30 + idle-skip = ≤30 encode/giây khi active, **0 khi nghỉ**.
- `queueDepth`: frame phải được xử lý + release trong `minimumFrameInterval × (queueDepth − 1)` giây để không rớt frame. Trên `.idle` return ngay không giữ surface; trên `.complete` submit rồi release sau khi encoder đã nuốt pixel (VideoToolbox tự giữ internal).

---

### 5. Cấu hình VideoToolbox cho màn hình tĩnh

Giữ pipeline trên Apple Silicon Media Engine (encode HEVC chạy ngoài CPU P/E core → pin/nhiệt thấp, đúng tinh thần laptop coding tool):

```swift
// Encoder spec
kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = kCFBooleanTrue

// Properties
kVTCompressionPropertyKey_ProfileLevel       = kVTProfileLevel_HEVC_Main_AutoLevel   // 4:2:0, auto level
kVTCompressionPropertyKey_RealTime           = kCFBooleanTrue
kVTCompressionPropertyKey_AllowFrameReordering = kCFBooleanFalse                      // P-frame only, không B-frame, không bubble lookahead
kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration = 2.0                           // I-frame mỗi ~2s để repair lỗi, không phình keyframe
```

**Chọn chế độ rate control theo môi trường:**

- **LAN (mặc định cho tool này): constant-quality** — `kVTCompressionPropertyKey_Quality = 0.6`. Dễ tune hơn bitrate+DataRateLimits: frame tĩnh sinh NALU rất nhỏ, burst (compile/scroll) tự lấy đủ bit. Trên LAN băng thông không phải nút thắt nên CQ là lựa chọn tự nhiên cho "near-zero khi idle, đủ bit khi active".
  - **Đã verify (confidence: medium):** CQ chỉ có trên **Apple Silicon (macOS ARM64)**, không có trên Intel/T2. FFmpeg gate bằng `!TARGET_OS_IPHONE && TARGET_CPU_ARM64` với comment "constant quality only on Macs with Apple Silicon". Apple **không** document per-chip cho key này → **feature-detect / test thực tế**, có fallback sang bitrate mode cho Intel host.
- **WAN / băng thông giới hạn (nếu sau này mở rộng):** `AverageBitRate` + `DataRateLimits` (CFArray `[peak_bytes, duration_seconds]` cho burst).

**Low-latency rate control với HEVC (verdict: uncertain — đừng coi là đảm bảo):**
- `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` **có bằng chứng thực nghiệm chạy với HEVC trên Apple Silicon** (FFmpeg patch merged commit d87210745e, 9/2025, gate `TARGET_CPU_ARM64`) — nhưng **Apple chưa document** HEVC cho key này; WWDC21 nói "supported video codec type in this mode is H.264". Header chỉ khai báo symbol available từ macOS 11.3 không kèm ràng buộc codec, cũng không xác nhận HEVC.
- → Với re-scope này, low-latency mode **không còn là mục tiêu**: fps không phải goal, motion-to-photon < 16ms đã bị bỏ. Có thể bật cho HEVC-on-Apple-Silicon nếu test thấy ổn, nhưng **không phải feature load-bearing** nữa. `AllowFrameReordering=false` (loại B-frame) đã đủ cho input responsiveness ở mức cần.

`claim_to_verify`: `kVTCompressionPropertyKey_AllowTemporalCompression=false` (tắt inter-frame) cho HEVC có khiến VideoToolbox rớt về software encode không — WWDC21 minh hoạ pattern này cho H.264; chưa verify cho HEVC. Chỉ dùng nếu thật sự cần encode từng frame độc lập.

---

### 6. Bar chất lượng tối thiểu để đọc code

`open_question` chưa có số cứng từ nguồn — đây là khung suy ra từ hành vi HEVC VBR/CQ, **phải user-test ở đúng cấu hình đích**:

- **Resolution:** capture per-window ở **backing resolution** của cửa sổ (`width/height = logical size × NSScreen.scaleFactor`), không hardcode 2×. Capture ở scale retina đầy đủ → mỗi glyph nhiều pixel chroma hơn → 4:2:0 đỡ hại. Capture đúng 1 cửa sổ (`SCContentFilter(desktopIndependentWindow:)`), không capture full desktop: cửa sổ 1920×1080 trên màn 2560×1440 đã giảm ~44% pixel cần encode.
- **Bitrate (ước lượng, derived — không phải số đo Apple):** HEVC 4:2:0 1080p VBR cho cửa sổ code tĩnh ~ **0–50 kbps khi idle**, **~500 kbps–2 Mbps khi gõ/scroll tích cực**. Với CQ thì bitrate tự bám độ phức tạp nội dung, không cần đặt trần trên LAN.
- **Câu hỏi mở cần đo:** bitrate tối thiểu để code 12pt trong VS Code Dark+ ở 2560×1440 (logical) còn đọc tốt khi render ở 1920×1200 trên iPad? **Không có số trong nguồn** — bench thực tế.

So sánh tham chiếu: HEVC tiết kiệm ~25–50% bitrate so với H.264 ở chất lượng tương đương (Azure Virtual Desktop docs). Trên Apple Silicon, encode HEVC 1080p60 ~18ms/frame, capture overhead ~1.9% một CPU core ở 60fps (số Lumen/Sunshine fork + WWDC22; `claim_to_verify` vì là số bên thứ ba, biến thiên theo quality/complexity).

---

### 7. Khác gì so với các doc latency-obsessed trước

| Tư duy cũ (10-latency-optimization, 11-absolute-latency) | Tư duy mới (re-scope hybrid) |
|---|---|
| Motion-to-photon < 16ms là mục tiêu hàng đầu | **Bị bỏ.** Màn hình code phần lớn tĩnh; responsiveness gõ/cursor lo bởi **path PTY/terminal** (bytes vào PTY stdin, không cần CGEvent), không phải path video |
| fps cao (60/120 ProMotion) | **Cap ~24–30 fps** (đủ dùng, giảm băng thông/latency/CPU); ưu tiên **idle-efficiency** + encode-on-change |
| 4:4:4 / độ nét text là đòn bẩy số 1 | **Bỏ hẳn 4:4:4** (HW không có). Text căng đi path terminal. 4:2:0 đủ tốt cho GUI |
| Low-latency rate control là feature load-bearing | Hạ xuống "nice-to-have, uncertain cho HEVC". `AllowFrameReordering=false` đã đủ |
| Tối ưu cho mọi frame | Tối ưu cho **đa số frame là idle**: `SCFrameStatus.idle` guard + `dirtyRects` là trung tâm |

Điểm bất biến vẫn giữ từ doc cũ: encode HW HEVC trên Apple Silicon Media Engine (pin/nhiệt thấp), capture per-window bằng `SCContentFilter(desktopIndependentWindow:)`, NV12 4:2:0 input, P-frame-only.

---

### 8. Câu hỏi mở còn lại

- `SCFrameStatus.idle` có giao callback đều theo `minimumFrameInterval` hay suppress hẳn? Ảnh hưởng việc có thể ngủ thread encode hay không (Apple forum thread/718356 mơ hồ).
- VideoToolbox HEVC trên Apple Silicon có expose `kVTCompressionPropertyKey_ConstantBitRate` không, hay chỉ `AverageBitRate` + `DataRateLimits`? CBR hữu ích cho network buffer nhưng có thể hại idle-efficiency.
- HEVC hardware decode trên iPad có thêm latency bù lại phần tiết kiệm encode phía Mac so với H.264 không? Kỳ vọng rất thấp nhưng không có số trong nguồn.
- Fringing 4:2:0 trên dark-theme VS Code/Xcode có thật sự "tolerable" ở resolution/bitrate đích? **Đánh giá chủ quan — bắt buộc user-test.**

---


---

## Roadmap & cập nhật docs cho kiến trúc hybrid

> Section này ghi đè định hướng phase của [07-roadmap.md](07-roadmap.md) và đánh dấu phần over-engineering trong [05](05-input-window-control.md), [09](09-codec-choice.md), [11](11-absolute-latency.md) cho kiến trúc **hybrid** mới: **terminal path (PTY byte-stream như SSH/mosh, render bằng libghostty)** + **GUI window path (ScreenCaptureKit -> VideoToolbox HEVC 4:2:0)**. Tất cả claim dưới đây bám corpus đã verify; chỗ nào corpus đánh `refuted`/`uncertain` đều phản ánh thành correction/uncertainty.

---

### 1. Xếp hạng kỹ thuật cho tool hybrid (đòn bẩy lớn nhất -> biên)

Thứ tự = (giá trị mang lại cho coding daily) × (độ chắc chắn) ÷ (rủi ro + công sức). Cột "Apple" = mức hỗ trợ native theo corpus.

| # | Kỹ thuật | Vì sao thắng lớn | Apple | Khó | Rủi ro |
|---|----------|-------------------|-------|-----|--------|
| **1** | **PTY bridge text-path** (`forkpty()`/`openpty()` + DispatchIO + stream byte VT qua TCP, client render) | **Né hoàn toàn bài toán input injection của macOS**: keystroke chỉ là byte ghi vào PTY master fd — không CGEvent, không Accessibility, không activate-then-control, không TCC. Text nét **by construction** (không qua video codec). Idle near-zero (PTY tĩnh thì không có byte chảy). Bandwidth ~36–52 byte/keystroke. | native | thấp | thấp |
| **2** | **libghostty làm client renderer** (full surface + **patch external-backend tự own**, ref daiimus External.zig; `ghostty_surface_feed_data` ← network, write-callback → host) | Render Ghostty-class: Metal GPU, VT fidelity cao nhất, Kitty graphics, ligatures. Proven trên iOS (VVTerm/Moshi). Giá: ~1–3 tuần dựng Zig build + own patch + vendor XCFramework. Bọc sau `TerminalRendering` để cô lập C-ABI. **Không fallback** (best-only — không SwiftTerm). | native (qua patch tự own) | **cao** | trung bình (ABI-instability tax + tự rebase patch; né được bus factor) |
| **3** | **TCP stream transport qua Network.framework** (`NWConnection`/`NWListener` + framing 1-byte type + 4-byte big-endian length, kiểu ttyd) | Đơn giản nhất hợp LAN: RTT <1ms nên TCP head-of-line blocking không đáng kể; idle hiệu quả tuyệt đối (PTY không phát thì không byte nào chảy). Không cần SSP/UDP của mosh. | native | thấp | thấp |
| **4** | **Persistent PTY qua helper process giữ master fd** (launchd agent `KeepAlive`, hoặc tmux) | Shell sống sót qua mọi lần client disconnect (iPad sleep, lid-close, Wi-Fi handoff). Vì master fd thuộc helper process — không thuộc TCP handler — đóng socket không gửi SIGHUP cho shell. | native | trung bình | trung bình |
| **5** | **ET-style packet-framed ring buffer + sequence-number ACK catchup** (BackedWriter/BackedReader) | Reconnect liền mạch sau gián đoạn LAN. **Replay ở packet boundary** nên loại bỏ hẳn nguy cơ replay cắt giữa escape sequence (corrupt emulator). | partial | trung bình | trung bình |
| **6** | **iOS eager-reconnect on foreground** (`scenePhase .active` -> tạo NWConnection mới + sequence exchange; **không** cố giữ socket sống qua suspension) | Đúng với thực tế iOS: socket bị OS thu hồi khi app suspend (~30s background budget). Coi reconnect là fast path bình thường, không phải recovery ngoại lệ. | native | trung bình | trung bình |
| **7** | **Clipboard sync: OSC 52** cho terminal path (libghostty action callback OSC 52; SwiftTerm `clipboardCopy`/`clipboardRead` chỉ là *citation* cho cơ chế) | Copy host->client gần như miễn phí, nằm trong PTY byte stream. tmux/Neovim cấu hình emit OSC 52 sẵn. | native | thấp | trung bình (read = exfiltration, default-deny) |
| **8** | **ScreenCaptureKit per-window + `SCFrameStatus.idle` skip + `dirtyRects`** (GUI video path) | Near-zero bandwidth khi màn hình tĩnh — đòn bẩy idle quan trọng nhất cho coding. `guard status == .complete` trước khi encode = zero encode work lúc idle. | native | trung bình | thấp |
| **9** | **VideoToolbox HEVC 4:2:0, `AllowFrameReordering=false`, `RealTime=true`, quality-mode** (GUI path) | HW encode trên Media Engine (~0% CPU core), P-frame-only (no B-frame lookahead). 4:2:0 **chấp nhận được** vì text-crispness constraint đã bỏ. | native | trung bình | thấp |
| **10** | **CGEvent/SkyLight input injection** (GUI video path) | Chỉ cần cho **GUI window**, không cho terminal. Giữ nguyên độ phức tạp activate-then-control + private SPI. | partial/unsupported | cao | **cao** (Electron mouse reject, private API, no MAS) |
| **11** | **Mosh SSP + speculative local echo** (PredictionEngine) | **Trên LAN không cần.** Adaptive mode `srtt_trigger` chỉ bật khi `send_interval > 30ms`; LAN clamp ở 20ms -> local echo **dormant** (verified). Nếu vẫn muốn echo tức thì phải `DisplayPreference=Always`. Đòn bẩy biên cho LAN. | native (logic) | cao | trung bình |

**Lưu ý uncertainty/correction bám corpus:**
- `forkpty()` từ Swift **an toàn** nếu child gọi `execve()` ngay (fork-then-exec), parent chỉ nhận master fd — claim "unsafe to call from Swift" đã bị **refuted** ở mức call-site; nguy cơ thật chỉ khi chạy Swift/ObjC runtime trong child *trước* exec ([forums.swift.org/t/51457], [developer.apple.com/forums/thread/747499]). Workaround được Apple khuyến nghị: `openpty()` + `posix_spawn(POSIX_SPAWN_SETSID)` + `login_tty()` — đúng path mà SwiftTerm đang migrate (hiện guard `#if false //canImport(Subprocess)`).
- `posix_openpt()` **không "broken"** trên macOS (claim refuted) — giới hạn thật chỉ là `fcntl(O_NONBLOCK)` trên master fd fails với EINVAL nếu chưa open slave; `openpty()` né được vì nó tự open slave ([apple-oss Libc/util/pty.c]).
- HEVC + `EnableLowLatencyRateControl` trên Apple Silicon: **uncertain/empirical** — confirmed qua FFmpeg patch (`TARGET_CPU_ARM64`, commit d87210745e, 9/2025) nhưng **Apple không document HEVC** cho property này (WWDC21 nói H.264 only). Dùng được nhưng phải feature-detect runtime ([VTCompressionProperties.h]).

---

### 2. "Do first" — shortlist khởi động

Đây là tập tối thiểu để có một tool dùng được hàng ngày, rủi ro thấp nhất, giá trị cao nhất:

1. **PTY bridge trên host** — `openpty()` + `posix_spawn` (login_tty, `POSIX_SPAWN_SETSID`), set env `TERM=xterm-ghostty`, `LANG=en_US.UTF-8`, `COLORTERM=truecolor`, `IUTF8` termios flag (confirmed có trên Darwin: `IUTF8 = 0x00004000` trong XNU `bsd/sys/termios.h`), prepend `-` vào argv[0] cho login shell. Đọc master fd bằng `DispatchIO(.stream, lowWater:1, highWater:131072)`.
2. **Resize**: `ioctl(masterFd, TIOCSWINSZ, &winsize)` khi client báo size mới -> kernel gửi SIGWINCH (SwiftTerm `sizeChanged` delegate -> message resize -> host ioctl).
3. **Transport**: `NWConnection`/`NWListener` TCP, framing 1-byte type (0=terminal data, 1=resize) + 4-byte length. **No app-layer TLS** — WireGuard encrypt; authorization qua NetBird ACL ([13]).
4. **Client libghostty** (full surface + **patch external-backend tự own**, ref daiimus External.zig): `ghostty_surface_feed_data` ← NWConnection receive loop; write-callback (`use_custom_io=true`) -> NWConnection -> PTY stdin host. Build `GhosttyKit.xcframework` (zig), vendor + pin upstream SHA, re-apply patch khi bump. Bọc sau `TerminalRendering`. **Không fallback** (best-only — không SwiftTerm).
5. **Persistent PTY**: host helper là launchd agent `KeepAlive=true` giữ tất cả master fd; PTY sống qua disconnect.
6. **Reconnect tối thiểu**: iOS `scenePhase .active` -> reconnect; macOS client `NWPathMonitor.pathUpdateHandler` -> reconnect khi Wi-Fi↔Ethernet đổi.

> ⚠️ **Threading caveat (load-bearing, từ corpus `uncertain` verdict):** `feed(byteArray:)` có doc nói "can be invoked from a background thread" **nhưng** `feedPrepare()` mutate `selection.active`/`search.invalidate()` và `queuePendingDisplay()` đọc-ghi `pendingDisplay: Bool` **không khóa** trên thread caller -> data race thật. Mitigation: hop về main queue trước khi gọi `feed()` từ network receive loop, hoặc serialize. Stress-test trước khi ship.

> ℹ️ **Ligature:** libghostty (Ghostty) xử lý ligature đúng qua HarfBuzz shaping — không lệch cột.

---

### 3. Docs thay đổi thế nào

#### 3.1. [05-input-window-control.md] — rủi ro lớn nhất **biến mất cho terminal path**

Doc 05 mở đầu bằng câu "Đây là rủi ro kỹ thuật lớn nhất của dự án". Với hybrid, **điều này chỉ còn đúng cho GUI video path**:

- **Terminal path không chạm CGEvent/AX/activate-then-control gì cả.** Input = byte ghi vào PTY master fd qua `DispatchIO.write`. Không cần TCC Accessibility, không `CGEventPostToPid`, không heuristic match `AXUIElement`↔`CGWindowID` (điểm "dễ vỡ thật sự" mà doc 05 §4 tự nhận), không caveat macOS 14 cooperative-activation (doc 05 §4 → "Caveat macOS 14+" — "FAIL khi trigger bởi timer/network" chính là case remote control). **Toàn bộ chuỗi rủi ro này bay đi cho phần lớn workflow coding (terminal/Neovim/tmux/git/build).**
- **Hệ quả với Phase 0 gate:** các spike 0.4–0.6 trong [07-roadmap.md] (AXRaise đúng cửa sổ, CGEventPostToPid click trúng, đo tỉ lệ activate từ callback mạng) **không còn là gate chặn dự án**. Chúng tụt xuống thành điều kiện cho **GUI video path (phase sau)**, không phải điều kiện sống-còn của MVP.
- **Việc cần làm với doc 05:** thêm banner đầu file "Áp dụng cho GUI window path; terminal path sidestep hoàn toàn injection — xem PTY bridge". Giữ nguyên nội dung kỹ thuật (vẫn đúng cho VS Code/Xcode window) nhưng hạ mức ưu tiên rủi ro.
- **Electron correction (đã reflect trong [05] banner):** keyboard inject qua `CGEventPostToPid` được Electron/VS Code chấp nhận; chỉ **mouse** bị từ chối (cần SkyLight SPI) — test macOS 14/15.

#### 3.2. [09-codec-choice.md] — bài toán 4:4:4 / text-crispness **bị drop hẳn**

Doc 09 TL;DR hiện viết "Trần chất lượng text thật là chroma 4:2:0 ... đòn bẩy số 1 ... thứ Apple không có". Với hybrid, **đây không còn là vấn đề trung tâm**:

- **Text crispness không còn là ưu tiên #1.** Toàn bộ text vốn stress codec nhất (terminal, code) **đi qua PTY path render bằng libghostty — nét tuyệt đối, không qua codec**. Video chỉ phục vụ GUI window (VS Code/Xcode editor view), nơi **4:2:0 HEVC chấp nhận được** (constraint đã nới).
- **Over-engineering cần đánh dấu DROP trong doc 09:**
  - §2 "Đòn bẩy khả dụng" mục 3 — **"Software encode 4:4:4 ultra-text tier"**: bỏ hoàn toàn. 4:4:4 problem dropped; không tối ưu cho nó nữa.
  - §2 mục 1 — **HEVC 10-bit (Main 10) mặc định "để nét cạnh hơn"**: hạ xuống optional. Corpus xác nhận VideoToolbox không có HEVC-SCC (palette/intra-block-copy — claim `confirmed`: không tồn tại `kVTProfileLevel_HEVC_SCC_*` trong bất kỳ SDK nào). Với GUI path, **HEVC Main 8-bit 4:2:0** là đủ; 10-bit chỉ là tweak biên.
  - **Khuyến nghị mới cho GUI path:** `kVTCompressionPropertyKey_Quality = 0.6` (constant-quality, **chỉ Apple Silicon macOS ARM64** — FFmpeg `vtenc_qscale_enabled()` gate `!TARGET_OS_IPHONE && TARGET_CPU_ARM64`, claim `confirmed`) + `pixelFormat = 420YpCbCr8BiPlanarVideoRange` + `minimumFrameInterval = CMTime(1, 30)` (cap ~24–30 fps — đủ dùng, giảm băng thông/CPU) thay vì tối ưu chroma.
- **Việc cần làm với doc 09:** sửa TL;DR thành "GUI window path dùng HEVC 4:2:0 8-bit quality-mode; text-heavy content đi PTY path không qua codec". Phần codec so sánh (Parsec/Moonlight muốn 4:4:4) giữ làm bối cảnh lịch sử nhưng note rõ "không áp dụng cho hybrid vì text đã tách sang terminal path".

#### 3.3. [11-absolute-latency.md] + [01 §5 latency budget] — floor <16ms / 120fps / vsync là **over-engineering**

Doc 11 là "nghiên cứu sâu nhất (73-agent)" về **absolute latency floor**: floor 10–16ms @120fps ProMotion, hai stage dominant là capture-vsync + scanout-vsync, beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`. Doc 01 §5 đặt mục tiêu "glass-to-glass ~30–50ms, 60fps". **Với hybrid coding profile, toàn bộ tầng tối ưu này là over-engineering cần hạ cấp:**

- **Motion-to-photon <16ms không còn là goal.** README đã ghi coding chịu được 40–80ms. Vì vậy:
  - **DROP**: theo đuổi floor 10–14ms, 120fps/ProMotion path (doc 11 budget @120fps; doc 01 §5 ghi chú "ProMotion 120Hz" — README cũng đã nói "120fps/ProMotion: bỏ").
  - **DROP**: beam-racing, `CAMetalDisplayLink preferredFrameLatency=1`, slice/sub-frame pipelining (corpus xác nhận "Slice / sub-frame pipelining KHÔNG khả dụng qua public VideoToolbox API" — `refuted`, vốn đã nên bỏ).
  - **DROP cho terminal path**: cả khái niệm vsync-dominant budget. **Latency terminal path = RTT mạng + PTY round-trip (~1–5ms LAN), KHÔNG có capture-vsync, không có scanout-coupling, không có encode/decode.** Mọi phân tích "capture compositor vsync + scanout vsync là hai khoản chi không nén được" của doc 11 **chỉ áp dụng cho GUI video path**.
  - **fps không phải mục tiêu**: corpus correction "`minimumFrameInterval` macOS 15+ default âm thầm = 1/60" vẫn cần biết, nhưng cho GUI path ta **chủ động set THẤP** (10fps cho text content) thay vì cố đẩy 60/120. `(1/fps)×0.9` (OBS PR#11896), không `kCMTimeZero` (refuted).
- **Giữ lại từ doc 11 (vẫn đúng, low-risk cho GUI path):** `queueDepth` default thực là 8 (không phải 3), `2` hợp lệ cho latency thấp; `AllowOpenGOP` default true -> set `false`; `MaxFrameDelayCount=0`; **tắt AWDL/`includePeerToPeer`** (gây spike 40–336ms — quan trọng cho GUI video trên Wi-Fi); idle-frame skip + dirtyRects.
- **Việc cần làm với doc 11:** thêm banner "Toàn bộ floor analysis này áp dụng cho **GUI video path**. Terminal path (mặc định, Phase 1) có latency model hoàn toàn khác: dominated by network RTT, không vsync." Hạ doc 11 từ "nghiên cứu trung tâm" xuống "tham chiếu cho phase video sau".
- **Việc cần làm với doc 01 §5:** tách latency budget thành 2 bảng: (a) **Terminal path** = keystroke -> PTY -> byte stream -> render, ~1–5ms LAN + local echo optional; (b) **GUI video path** = giữ bảng 6-stage hiện tại nhưng nới target lên 40–80ms, bỏ cột 120fps.

---

### 4. Revised phased roadmap (ghi đè [07-roadmap.md])

Đảo ngược thứ tự: **terminal text-path là Phase 1** (đơn giản hơn + giá trị cao hơn + né bài toán injection khó nhất). GUI video path lùi về phase sau.

```
Phase 1 (terminal PTY) ──▶ Phase 2 (persist+reconnect+clipboard) ──▶ Phase 3 (iOS client)
   giá trị cao, rủi ro thấp        làm "dùng được hàng ngày"            mở rộng thiết bị
                                                                          │
                                            Phase 4 (GUI video) ◀─────────┘  ← rủi ro injection dồn về đây
                                            Phase 5 (security + polish)
```

#### Phase 0 — Spike (đổi trọng tâm)
Bỏ gate input-injection khỏi vị trí chặn dự án. Spike mới:
- [ ] `openpty()` + `posix_spawn(createSession)` spawn login shell, đọc master fd qua DispatchIO, echo byte qua TCP — verify shell chạy, vim/tmux render box-drawing đúng (env `LANG`/`IUTF8`). (forkpty unsafe từ Swift — đã giải.)
- [ ] **libghostty spike:** áp patch external-backend (ref daiimus External.zig / Lakr233 `0002-host-managed-io.patch`), build XCFramework, feed byte stream → render macOS + iOS device. Verify: fullscreen/alt-screen chạy, route key qua `ghostty_surface_key` (kitty/DECCKM đúng), action callbacks (COMMAND_FINISHED/PWD) bắn ra.

> 🔬 **Phase 0 — checklist SPIKE "phải đo trên device" (gate, không research được):**
> - [ ] **binary-size** `GhosttyKit.xcframework` (Metal renderer) trên iOS — chấp nhận được không.
> - [ ] **OSC 133 shell-integration e2e** qua network (host shell thật emit → action callback ở client).
> - [ ] (codec, Phase 4) `AllowTemporalCompression=false` có ép HEVC software-encode không (nếu có → dùng `MaxKeyFrameInterval=1` như FFmpeg); `ConstantBitRate` HEVC khả dụng trên OS đích không (probe `VTSessionCopySupportedPropertyDictionary`, else fallback `AverageBitRate`+`DataRateLimits`); `ForceLTRRefresh` nhận `kCFBooleanTrue` hay `@(1)`.
> - [ ] `mach_timebase` numer/denom trên M2/M3/M4 — **luôn gọi API, đừng hardcode 125/3**.
> - [ ] (codec, Phase 4) bitrate tối thiểu cho text đọc được + fringing 4:2:0 "tolerable" — perceptual test trên display đích.
> - [ ] `EnableLowLatencyRateControl` + HEVC + `EnableLTR` feature-detect runtime (`VTCopySupportedPropertyDictionaryForEncoder`).

#### Phase 1 — Terminal MVP (Mac host -> Mac client), **thay cho "MVP video" cũ**
- [ ] PTY bridge host: spawn shell, stream byte, `TIOCSWINSZ` resize.
- [ ] Transport TCP framing (1-byte type + 4-byte length) qua Network.framework.
- [ ] Client libghostty: full surface + **patch external-backend tự own** (XCFramework build), `feed_data` ← network / write-callback → host, bọc sau `TerminalRendering`. **Không fallback** (best-only).
- [ ] Bonjour discovery host advertise / client list (giữ từ [03]).
- [ ] **Done:** mở shell host trên client Mac, gõ + chạy vim/tmux/git mượt, text nét tuyệt đối, **không một dòng CGEvent/Accessibility**.

#### Phase 2 — Persistence, reconnect, clipboard
- [ ] Persistent PTY qua launchd agent giữ master fd (sống qua disconnect).
- [ ] ET-style packet-framed ring buffer + sequence-number catchup (reconnect không corrupt; nếu giữ raw-byte ring buffer thì prefix DECSTR `ESC[!p` trước khi replay tail — `Terminal.softReset()`).
- [ ] Reconnect: iOS `scenePhase`, macOS `NWPathMonitor`; host `NSWorkspaceDidWakeNotification` re-listen sau sleep.
- [ ] Clipboard OSC 52 (copy host->client free; read default-deny + permission prompt). Paste client->host nên dùng **bracketed paste** (`ESC[200~`…`ESC[201~`) thay vì OSC 52 query để né freeze Neovim ~10s.
- [ ] **Done:** session sống qua iPad sleep / lid-close / Wi-Fi handoff; copy-paste 2 chiều.

#### Phase 3 — iOS / iPadOS client
- [ ] libghostty surface trong UIView (iOS), soft keyboard + hardware keyboard -> PTY byte (Ghostty hỗ trợ Kitty keyboard protocol cho Neovim/Helix).
- [ ] iOS clipboard: `UIPasteboard.changedNotification`, export `UIDocumentPickerViewController(forExporting:asCopy:true)`.
- [ ] **iOS UX (đã chốt): libghostty TUI (như desktop) + read-only inspector [16] cho structured view.** KHÔNG làm SDK-driven pane (B2 bỏ). Inspector read-only đã cho native cards (tool/subagent/todo) mà không phải drive agent → giải bài toán "raw ANSI trên màn nhỏ" mà Happy/Happier nêu, nhưng không mất TUI fidelity.
- [ ] **Done:** code từ iPad qua LAN, terminal đầy đủ.

#### Phase 4 — GUI video path (đẩy lùi tại đây — nơi tập trung mọi rủi ro injection)
- [ ] ScreenCaptureKit per-window + idle skip + dirtyRects + HEVC 4:2:0 8-bit quality-mode (doc 09 mới).
- [ ] VideoToolbox decode + Metal render (target 40–80ms, **không** 120fps/beam-racing — doc 11 hạ cấp).
- [ ] Input injection cho GUI window: activate-then-control + `CGEventPostToPid` (keyboard) + SkyLight SPI (mouse Electron) — **đây mới là phần "khó nhất" của doc 05**, giờ là feature opt-in per-window, không phải nền tảng.
- [ ] **Done:** "mirror this window" cho VS Code/Xcode khi cần GUI.

#### Phase 5 — Security & polish
- [ ] **Security = dựa vào NetBird (WireGuard mesh), KHÔNG encrypt tầng app** — xem [13](13-netbird-transport.md). WireGuard đã lo E2E encryption + node auth; thêm TLS/QUIC-crypto là **thừa** (double-encrypt, latency vô ích). → **Bỏ** Network.framework TLS / CryptoKit ECDH ở tầng app.
  - **Authorization** dùng **NetBird ACL** (deny-by-default, per-port): chỉ mở port app từ group client → group host. WireGuard auth *node*; ACL giới hạn *peer→port*.
  - ⚠️ **NetBird mesh LÀ security boundary** (khác LAN trần): PTY=RCE bị giới hạn trong các peer đã authorize (bạn kiểm soát membership). Vẫn nên: app-level device-allowlist nhẹ + per-user nếu nhiều user chung máy (OIDC NetBird).
- [ ] File transfer (NWProtocolFramer multiplex channel hoặc OSC 1337 cho file nhỏ).
- [ ] Hardened Runtime + Developer-ID + notarize (host helper **không** sandbox được vì spawn shell — ship ngoài MAS).
- [ ] ~~Speculative local echo~~ — **KHÔNG cần.** Assume NetBird direct P2P (~5–20ms, loss~0) → terminal = **TCP byte-stream + libghostty render, không mosh/SSP, không predictive echo**. Lợi ích SSP chỉ phát huy khi relayed mà ta **không engineer cho relay** ([13 §4](13-netbird-transport.md)).

**Lý do đảo phase (tóm tắt corpus):** terminal path (a) đơn giản hơn [video+injection] — chỉ byte stream, né input injection (renderer libghostty là công sức một lần); (b) giá trị cao hơn — coding daily là terminal/Neovim/tmux/git/build, đúng cái mọi tool prior-art (Blink, code-server, JetBrains Gateway bỏ Projector) hội tụ vào "semantic/text streaming thắng pixel streaming"; (c) né bài toán khó nhất — input injection. GUI video path là fallback cho window không có semantic alternative, đúng vị trí Phase 4.
