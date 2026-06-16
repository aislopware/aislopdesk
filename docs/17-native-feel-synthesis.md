# 17 — Best-solution synthesis: lowest latency + "real machine" feel (TUI & GUI per-window)

> **STATUS: CURRENT.** Synthesized from 7 "families" of OSS + commercial solutions to lock in the **best** design for the 2 paths, prioritizing (a) lowest latency and (b) the feel of **using a local machine**, not a remote one. Corpus: [research/17-tui-gui-best-solution.json](research/17-tui-gui-best-solution.json). Decisions are in [DECISIONS.md](DECISIONS.md); this doc is the **why + mechanics**.
>
> Guiding philosophy (see [00](00-overview.md)): **one good choice per problem** (one renderer, one structured view, one core).

## TL;DR (headline)

1. **PATH 1 (terminal) is already nearly local** at a private-mesh 5–20ms RTT. Raw VT byte-stream over **plain TCP + `TCP_NODELAY`** + **libghostty external-IO** = full fidelity, no protocol round-trips. **Do NOT build a Mosh shadow-framebuffer predictor for v1** (see §2.4). Add: **dual data/control channels** + an **ET-style replay buffer** so reconnects lose no bytes.
2. **PATH 2 (GUI per-window), the highest-value decision = client-side cursor rendering**: split the pointer out of the video, send position+bitmap over a separate UDP side-channel, composite on the client at display-refresh → **pointer latency = RTT**, fully independent of encode/decode. This is the boundary between "feels remote" and "feels local".
3. **PATH 2 sharp text for editor windows**: **lossy-first → lossless-upgrade** (encode at quality ~0.65 and send immediately, then re-encode the dirty-rect with `kVTCompressionPropertyKey_Lossless` when idle) — both fast and pixel-perfect once the user stops to read.
4. **PATH 2's hardest risk** was **mapping the client's video-region coordinates → the host's window/screen** for CGEvent injection (Retina scaling + window moves) — now **SOLVED** ([18 B], §3.9).

---

## 1. Method & sources

Fan-out across 7 families, each **survey → deep-dive verify** (cross-checked against source code/RFCs/patents), then synthesis:

| # | Family | Core takeaway |
|---|----|----------------|
| 0 | Terminal/TUI protocols (Mosh, Eternal Terminal, tmux/zellij, WezTerm mux) | Mosh predictive echo + ET replay buffer + dual-channel |
| 1 | iOS terminal clients (Blink, VVTerm, Geistty, SwiftTerm, Termius) | libghostty external-IO (a real fork) + UIKit native-feel table stakes |
| 2 | Commercial GUI (Parsec, Jump Fluid, Splashtop, AnyDesk, NoMachine NX) | VideoToolbox low-latency recipe + cursor side-channel (Parsec patent) |
| 3 | Open-source GUI (Moonlight/Sunshine, RustDesk, Chrome RD, Selkies) | **Client-side cursor** + LTR/FEC loss recovery + frame pacing |
| 4 | Per-window remoting (RDP RemoteApp, X11, Xpra, waypipe, SCKit per-window) | **Lossy-first→lossless-upgrade** + idle-skip + window-geometry channel |
| 5 | Apple-native (Sidecar, ARD High-Perf, ScreenCaptureKit, VideoToolbox) | 4-flag recipe + NV12 zero-copy + concurrent-session limit |
| 6 | Feels-native cross-cut (prediction, cursor, jitter, pacing, FEC, coalescing) | Technique ranking by impact (§4) |

Every claim was verified back to source. Notable **corrections** (survey was wrong → fixed) are scattered through §2–§3 marked with "⚠️".

---

## 2. PATH 1 — Terminal: best design

### 2.1 Transport: raw TCP + `TCP_NODELAY` (mandatory) + dual channels

- Raw PTY byte-stream over **plain TCP** (decided in [13]). **NEW ADD: enable `TCP_NODELAY` right after `connect()`** on every socket. Nagle coalescing of 1-character writes can add **up to 200ms** to echo — this is the single omission that showed up in every terminal stack surveyed. One `setsockopt` line, **high** impact.
- **Dual channels**: the data channel (PTY bytes) separated from the control channel (`TIOCSWINSZ` resize + intent/disconnect). Lesson from Zellij: a Claude Code output burst must not delay the resize-ack. Low effort (a 2nd framed channel or sub-stream multiplexing). The wire framing + channel mux + per-channel flow control are implemented in the Rust core's terminal namespace (behind the C-ABI), called by the Swift host/client.
- **No-buffer relay** (lesson from NoMachine NX): don't insert a ring buffer between `posix_spawn`→TCP write; lockless relay, relay thread set to **`QOS_CLASS_USER_INTERACTIVE`**.

### 2.2 Renderer: libghostty external-IO — the truth about the forks

- `ghostty_surface_feed_data` / `ghostty_surface_set_write_callback` **do NOT exist at upstream Ghostty HEAD** (verified: `include/ghostty.h` is 1208 lines, neither function present). They only exist in forks:
  - **`wiedymi/ghostty` branch `custom-io`** — VVTerm ships on this (`scripts/build.sh` clones exactly this ref).
  - **`daiimus/ghostty` branch `ios-external-backend`** — Geistty ships on this; adds `External.zig` (~379 lines) + has a resize callback + tests.
- The decision ([12]/[DECISIONS]) to **own a minimal patch, referencing `daiimus/External.zig`** remains correct and is now confirmed as a pattern **proven in 2 shipping iOS apps**. `use_custom_io = true` switches the termio backend from `Exec.zig` (PTY) to `External.zig` (no local shell spawn).
- **Data IN**: incoming TCP bytes → `ghostty_surface_feed_data(...)` → `ghostty_surface_refresh` + `ghostty_surface_draw` via a **coalescing `DispatchQueue.main.async` guard** (VVTerm's `scheduleCustomIORedraw` pattern). **Data OUT**: keypress → C write-callback (fires **synchronously on the main thread** from Ghostty's key encoder) → schedule a `Task(.userInitiated)` to write to TCP.
- ⚠️ **Mandatory threading spike**: can `ghostty_surface_refresh/draw` be safely driven from a background TCP-receive thread, or must **everything funnel through `@MainActor`**? (Geistty/VVTerm both call feed on `@MainActor`.) The coalescing-redraw decision + the fork's viability hinge on this answer.
- Building the XCFramework requires **Zig + Apple Silicon** at build time → budget the build-infra cost upfront.

### 2.3 Reconnect: ET-style replay buffer (chosen over tmux)

- **Eternal Terminal `BackedWriter`**: the host keeps a **64MB** circular buffer (`MAX_BACKUP_BYTES`, verified) of PTY output packets tagged with a monotonic **sequence number**. Client reconnects → sends the last seq it received → host `recover(lastValidSeq)` replays the tail. **Lossless resume**, no UDP needed, no tmux on the host.
- **Why NOT to depend on tmux for reconnect**: the iOS family suggests tmux for session persistence, but making reconnect *depend* on tmux = a **hard dependency** (host must install tmux + manage named sessions). We **own** the replay buffer inside the app → reconnect needs no tmux. (For process survival we use a persistent daemon holding the master FD — [12 §6]; tmux remains a purely convenient **v2 option** for server-side scrollback + pane mapping, not required.)
- ⚠️ Spike: validate the reconnect handshake through a real iOS background→foreground cycle (including `beginBackgroundTask` suspend timing) to confirm byte-exact resume.

### 2.4 Predictive echo: why NOT full Mosh (CHANGE) + glitch-caret (optional)

This is an important and **counter-intuitive** conclusion:

- Mosh's `PredictionEngine` (speculative local echo on a **shadow VT framebuffer**) is the classic technique making typing feel "instant" on slow links (mosh.org: median SSH 503ms vs mosh near-instant, EV-DO ~500ms RTT). But:
  1. `ghostty_surface_t` is an **opaque `void*`** (verified — no cell-reading function in the C API). To predict, you **must** build a **2nd VT parser** running in parallel maintaining a shadow framebuffer → maintenance burden + **desync** risk (a parser less complete than libghostty → mispredictions + jarring snaps).
  2. Mosh **disables prediction itself in full-screen apps** using cursor positioning (vim/emacs/htop). **Claude Code's TUI also uses alt-screen + cursor positioning** → prediction would be **OFF** inside Claude Code itself. The benefit only remains at a **bare shell prompt**.
  3. In **adaptive mode**, Mosh **withholds prediction on fast links** (SRTT_TRIGGER_HIGH=30ms → corresponding to raw SRTT ~60ms). A 5–20ms private-mesh RTT → prediction would be almost always off by Mosh's own design.
- ⚠️ Correction from source verification (don't let other docs copy it wrong): the underline threshold gates on **`send_interval`** (= `ceil(SRTT/2)` clamped to [20,250]ms), **not** raw SRTT; `FLAG_TRIGGER_HIGH=80` ⇒ raw SRTT ~160ms. **CR (0x0d) DOES call `become_tentative()`** (it is not excluded); only CSI `C`/`D` (←/→) are predicted, every other CSI → tentative.
- **Decision**: do **not** build a full shadow-framebuffer predictor for v1 — saving 5–20ms only at the shell prompt isn't worth the desync risk. **Cheap option (Phase 2)**: a **glitch-window speculative caret** — track only the **cursor column**, nudge a dim caret when no echo arrives within ~150–250ms ("input received" feedback while Claude Code stalls) without a shadow VT parser. 80% of the benefit at ~0 desync risk.
- ⚠️ Spike #1 (also decides the above): **measure real end-to-end echo latency on the private mesh** (PTY relay → TCP → shell echo → libghostty render) at both 5ms and 20ms RTT. This single number decides whether a predictor is ever needed.

### 2.5 iOS native feel: table stakes (ADD)

Missing any item below means it "works" but does **not** feel like a native iOS app (verified from Blink/VVTerm/SwiftTerm):

- **Key-repeat = a manual `DispatchSourceTimer`**: UIKit only fires `pressesBegan`/`pressesEnded` **once**, no auto-repeat. Use an initial delay of **350ms**, repeat at **50ms** (20Hz) → re-fire the key event. Without this, holding arrow/Delete doesn't repeat — breaking the most common navigation pattern.
- **IME proxy = a separate hidden `UITextView`**, do NOT implement `UITextInput` on the same view receiving `pressesBegan` (undefined responder ordering → breaks **CJK** input; Claude Code has Japanese users). Ctrl/Alt+letter routes straight to `ghostty_surface_key`; everything else through the IME proxy → `ghostty_surface_text`.
- **Floating cursor** (`updateFloatingCursor(at:)`): horizontal drag > **5pt** → arrow ←/→ (SwiftTerm verified). On an iPhone without a hardware keyboard, this is the **only way** to move the cursor. (Note: SwiftTerm gates vertical drag to alt-screen only.)
- **Accessory bar** (Ctrl/Esc/Tab/arrows) shown only when the software keyboard is visible (detect a hardware keyboard via keyboard frame height < ~150pt).
- iOS kills TCP a few seconds after backgrounding → solved by the **ET replay buffer** (§2.3) + `beginBackgroundTask` (`MIN(backgroundTimeRemaining*0.9, 300s)`).

---

## 3. PATH 2 — GUI per-window: best design

> PATH 2 is a pipeline **fully separate** from PATH 1 — don't merge the libghostty surface with video. (A negative lesson from the iOS family: libghostty only renders its own cell grid.)

### 3.1 Capture: SCContentFilter(window:) + NV12 zero-copy + queueDepth

- **`SCContentFilter(window:)`** per-window captures the window's **backing store** → correct even when occluded (verify on macOS 26).
- **`pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12)** → **zero-copy** hand-off to `VTCompressionSession`, **avoiding the BGRA→NV12 step** (FFmpeg-wrapped paths like Lumen must convert because they go through avcodec). ⚠️ Lumen actually uses `32BGRA` + captures a **virtual display**, not per-window — don't blindly copy Lumen's config.
- **`showsCursor = false`** on `SCStreamConfiguration` → the cursor is **excluded from the frame** (this is the per-window-correct way; do **NOT** use system-wide `CGDisplayHideCursor`). This is the prerequisite for the client-side cursor (§3.3).
- **queueDepth — a real tension, spike it, don't lock it blindly:**
  - [11]/[12] (the 73-agent latency workflow): actual default = **8**; use **2–3** for lowest latency (each slot = 1 frame-interval of potential latency).
  - This workflow: **5** (the value Sunshine/Apple-sample proved); the claim "3 is the minimum" is unverified community inference.
  - **Reconciliation**: 5 is the value Sunshine tuned for **60–120fps game-streaming under heavy GPU load**. Our profile = **default 60fps with idle-skip (→ ~0 bandwidth when static), 1 window, HW HEVC ~5–18ms** → the release budget `minimumFrameInterval × (queueDepth−1)` at depth-3/60fps = 33ms ≫ 18ms encode → **keep 2–3 for lower latency**. ⚠️ Spike under real GPU contention; if frames drop, raise to 5.
- **Release constraint (verified WWDC22 s10155)**: surfaces must be released within `minimumFrameInterval × (queueDepth−1)`; release the `CMSampleBuffer` surface **immediately** after handing the `CVPixelBuffer` to the encoder.

### 3.2 Encode: VTCompressionSession 4-flag low-latency recipe (ADD/refine)

Native `VTCompressionSession` (NOT an FFmpeg wrapper), HEVC 8-bit 4:2:0 (`kVTProfileLevel_HEVC_Main_AutoLevel`):

- **Specification keys** (set in the dict at **session creation**, not via `SetProperty` — this is the common trap):
  - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` — ✅ **verified valid for HEVC on Apple Silicon** (our host). (FFmpeg `videotoolboxenc.c`: `TARGET_CPU_ARM64 && AV_CODEC_ID_HEVC`.) Resolves the old doubt "is HEVC low-latency available?".
  - `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = true` — hard-fail instead of silently dropping to software.
- **Property keys** (via `VTSessionSetProperty`): `RealTime=true`, `ExpectedFrameRate=60`, `PrioritizeEncodingSpeedOverQuality=true` (exactly Apple's 4-flag recipe), `AllowFrameReordering=false` (no B-frames), `MaxKeyFrameInterval=INT_MAX` (IDR on-demand).
- ⚠️ **Corrections vs doc 09/DECISIONS**:
  - `MaxFrameDelayCount=0` and `AllowOpenGOP=false`, which we listed as "canonical SDK recipe", are actually **not verified as part of the SDK recipe** — harmless, but don't claim they're the Apple standard. Keep as belt-and-suspenders, mark for verification.
  - **`EnableLowLatencyRateControl` requires a target bitrate** (bitrate-based, not constant-quality). ✅ **RESOLVED by measurement ([18 §0]):** live frames use **low-latency-RC** (measured 7.5ms) — NOT constant-quality (measured 24ms, too slow). The crisp-upgrade moves to a separate **Session B** with `Quality=1.0` all-intra. Tension gone (2 sessions, one rate-controller each).
  - **Do NOT set `max_ref_frames=1` for H.264** (verified in Sunshine `video.cpp`): on Apple Silicon VideoToolbox H.264 it turns **every frame into an IDR** → ~3× bandwidth. HEVC is unaffected (safe). A trap if H.264 is ever tried later.
  - **Don't query `UsingHardwareAcceleratedVideoEncoder` while low-latency mode is on** (returns -12900).

### 3.3 Client-side cursor rendering — the HIGHEST-impact technique (ADD)

Independently confirmed **by 3 families** (Parsec, Moonlight, Selkies). It is the single differentiator between "feels remote" and "feels local":

1. Host: `showsCursor=false` (cursor never enters the video) — §3.1.
2. Host: sample the `NSEvent` mouse position at ~**120Hz**; send **position (host-space CGPoint) + shape (`NSCursor` image + hotspot)** over a **dedicated <64-byte UDP socket**, **NOT multiplexed onto the video socket** (if shared, video backpressure would delay the cursor).
3. Client: composite the cursor as a **Metal quad / `CALayer`** on top of the decoded frame, at **display-refresh**.
- ⟹ **Pointer latency = pure RTT** (5–20ms), fully decoupled from encode/decode (typically 30–50ms).
- ⚠️ Correction: the Parsec patent is actually **US 9,798,436** (the survey had it wrong). moonlight-qt currently only toggles `SDL_ShowCursor()` and has no dedicated cursor-shape-over-side-channel — the full pattern comes from **Selkies**.
- ⚠️ Spike: confirm `showsCursor=false` **actually** removes the cursor from the per-window `CMSampleBuffer` on the target macOS (the cursor may already be composited into the IOSurface).

### 3.4 Lossy-first → lossless-upgrade — sharp text for editors (ADD)

Solves the "fast vs readable" problem for coding (extending the "4:4:4 dropped, sharp text only via PTY" decision — now **GUI windows also get pixel-perfect text** once the user stops):

1. On each `SCFrameStatus.complete`: encode with **Session A low-latency-RC** (NOT constant-quality) and send **immediately** → first frame ~RTT. 📏 **Measured on M1 Max ([18 §0]): low-latency-RC 7.5ms vs constant-quality 0.65 = 24ms** → live frames must use low-latency-RC.
2. Accumulate the **dirty-rect union**; start a `DispatchSourceTimer` (GCD) with a **~200–600ms** delay = `max(batch_delay×5, 200ms)`. ⚠️ **NOT 1000ms** — 1000ms is Xpra's `LOCKED_BATCH_DELAY` for iconic/idle windows, not the refresh timer.
3. A new frame arriving before the timer fires → **cancel & reschedule** (Xpra's `cancel_refresh_timer` logic).
4. Timer fires after true idle → re-encode the dirty union. **Update [18 E]: use a SEPARATE SESSION (Session B)**, all-intra `Quality=1.0`+`AllowTemporalCompression=false` (don't cram it into the live session — low-latency-RC needs a bitrate, conflicting with constant-quality). Encode as an **INTRA slice** → UDP loss of the upgrade can't corrupt decode state.
5. **Window chrome** (title/scroll bar, height < ~40px) → always lossless on the first pass.
- ⚠️ Spike: confirm `kVTCompressionPropertyKey_Lossless` availability + measure lossless frame size for a 1080p editor window (to size the UDP send queue).

### 3.5 Idle-skip + damage tracking (refine)

- In `didOutputSampleBuffer` read `SCStreamFrameInfo.status`; if `== .idle` → **return immediately** (no IOSurface, no encode, no send). This is the **zero-cost damage check** (equivalent to X11 DAMAGE DeltaRectangles) and keeps the **encoder slot free** so the next real frame (from a keystroke) gets HW immediately. >90% of frames in a coding session are static.
- Heartbeat **IDR ~every 1s** on an idle window (so a reconnecting/loss-recovering client can catch a frame).

### 3.6 Transport + loss: UDP seq + FEC + LTR (refine)

> The packet seq, FEC + frame reassembly, LTR/recovery admission, and congestion/ABR all live in the Rust core's video protocol (behind the C-ABI); the Swift video host/client own only capture, the socket, and the HW codec.

- Plain UDP over the trusted mesh (no DTLS/QUIC — a WireGuard mesh is already ChaCha20-Poly1305; inner crypto is pure overhead). A **4-byte sequence number/packet** for ordering/loss detection.
- **Reed-Solomon FEC at ~20% parity/frame** (Sunshine's default).
- **Prefer LTR-frame recovery over forced IDR**: `kVTCompressionPropertyKey_EnableLTR` + `ForceLTRRefresh` on loss → avoids the keyframe's bandwidth/latency spike. Needs a small **client→host ACK channel** (cheap at our RTT), with an IDR fallback after a 2-RTT timeout. ⚠️ Correction: the invalidation direction is **client→server** (the client sends the RFI range; the server marks the ref frame invalid).
- Cap the encode queue at **2–3 frames in flight**; drop oldest; **never** backpressure SCKit's callback thread.

### 3.7 Client frame pacing (ADD)

- Drive client display from **`CADisplayLink` (VSync)**, NOT from decode completion. Empty queue → **hold the last decoded frame** (Moonlight pacer: `TIMER_SLACK ~3ms`, time-critical thread). Late frames are **skipped**, not queued → avoids latency accumulation.
- Decode session `RealTime=true`; **`CVMetalTextureCache`** for zero-copy CVPixelBuffer→Metal; **`CAMetalLayer.maximumDrawableCount=2`** keeps display latency ~1 vsync.
- ⚠️ Spike: measure `VTDecompressionSession` decode latency on a real Apple Silicon client — confirm **single-frame**, no silent 2-frame buffering (`RealTime=true` does **not** guarantee this) → decides whether the 60fps motion-to-photon budget holds.

### 3.8 Window-geometry metadata channel (ADD)

A **dedicated** metadata channel carrying window **move/resize/title** → the client `NSWindow` repositions **immediately, before the next video frame**. Every per-window remoting solution (RDP RemoteApp/RAIL, X11, Xpra) has one. ⚠️ RAIL correction (MS-RDPERP §1.3.2.5): mouse-driven moves do **not** send a Client-Window-Move PDU — only the mouse-button-up is sent, the server infers the position; the PDU is only needed for keyboard-driven moves.

### 3.9 Input: CGEvent + coordinate-mapping RISK (KEEP + PATH 2 spike #1)

- `CGEventPost(kCGHIDEventTap, ...)` for clicks/keys (Accessibility must be granted before launch; non-sandboxed; outside MAS — decided in [06]). `CGWarpMouseCursorPosition` for absolute moves. **Tag every event with `eventSourceUserData`** so the host filters self-injected events (avoiding loops).
- **Mouse-move coalescing**: drain pending moves, accumulate deltas, send once (Moonlight's `SDL_PeepEvents` pattern).
- ✅ **Coordinate mapping = SOLVED ([18 B]):** `kCGWindowBounds` (CG top-left)→normalize→`postToPid` (needs the TCC **"Post Event"** permission); fix multi-monitor by **flipping to Cocoa space** (`primaryH − y − h`) before `NSScreen.frame.intersection` to get the correct `backingScaleFactor`; window-move = AX `kAXWindowMovedNotification` (fires at the END) + poll `CGWindowListCopyWindowInfo` during the drag. Tag `eventSourceUserData` to filter self-injection.
- **Background input:** decided as **activate-then-control, 1 window at a time (must focus)** → the target window becomes frontmost → `CGEventPost` is universal (every kind of app), avoiding the SkyLight private API. ([18 A])

### 3.10 Concurrent window limit (ADD constraint)

- **2–4 simultaneous HEVC HW `VTCompressionSession`s** on Apple Silicon before dropping to software → the **upper bound on simultaneous remote GUI windows**. ⚠️ Spike to benchmark the exact number on the target hardware.
- 1 `VTCompressionSession` per tracked window (keeps encoder state across frames; avoids waypipe's per-buffer flicker bug).

---

## 4. Native-feel techniques — ranked by impact

| Technique | Path | Impact | Effort |
|----------|------|--------|--------|
| **Client-side cursor** (strip + UDP side-channel + composite at refresh) | GUI | **High** — pointer = RTT, decoupled from codec; the local/remote boundary | Medium |
| **`TCP_NODELAY`** on every PATH 1 socket | TUI | **High** — Nagle can add +200ms/keystroke | Trivial |
| **libghostty external-IO** over raw TCP | TUI | **High** — full fidelity, event-driven redraw, 0 round-trips | Medium-high (own fork) |
| **`SCFrameStatus.idle` skip** + heartbeat IDR | GUI | **High** — >90% of frames static; keeps the encoder slot free | Low |
| **Lossy-first → lossless-upgrade** | GUI | **High** — fast + pixel-perfect text on pause | Medium |
| **VideoToolbox 4-flag low-latency + NV12 zero-copy** | GUI | **High** — encode ~5–18ms, no reorder, no BGRA conversion | Medium |
| **ET replay buffer** for reconnect | TUI | **High** — byte-exact resume through iOS backgrounding | Medium |
| **CADisplayLink pacing + show-last-frame** | GUI | Medium-high — no judder, latency ~1 vsync | Low-medium |
| **iOS UIKit table stakes** (key-repeat/IME/floating-cursor/accessory) | TUI | Medium-high — "works" → "native iOS" | Medium |
| **Dual data/control channels** | TUI | Medium — output bursts don't delay resize | Low |
| **Glitch-window speculative caret** (cursor column) | TUI | Medium — feedback during stalls, ~0 desync risk | Low |
| **LTR + ~20% Reed-Solomon FEC** instead of forced IDR | GUI | Medium — avoids spikes; near-irrelevant at mesh loss rates but ~0 cost, hardens WiFi | Medium |
| **QoS `USER_INTERACTIVE`** on PTY-relay & capture+encode threads | both | Medium — keeps the latency-critical path scheduled first | Trivial |

---

## 5. Gap analysis vs current decisions

> **KEEP** = correct, keep. **CHANGE** = fix/clarify. **ADD** = new addition. (Pushed into [DECISIONS.md](DECISIONS.md).)

**PATH 1**
- KEEP — raw VT bytes over plain TCP + libghostty; no app-level crypto; input = bytes→PTY stdin (avoiding input injection).
- CHANGE — do **not** build the full Mosh predictor for v1 (opaque ghostty → duplicate parser; benefit only at the shell prompt). Glitch-caret is a Phase 2 option.
- CHANGE — libghostty external-IO **exists only in forks** (wiedymi `custom-io` / daiimus `ios-external-backend`); committing to our own patch is a tracked dependency (already the right direction).
- ADD — `TCP_NODELAY`; ET 64MB seq replay buffer (chosen over tmux); dual data/control channels; QoS USER_INTERACTIVE relay; iOS UIKit table stakes.

**PATH 2**
- KEEP — `SCContentFilter(window:)`; HEVC 8-bit 4:2:0; plain UDP; default 60fps + idle-skip (→ ~0 bandwidth when static); CGEvent injection (accepting Accessibility/non-sandbox/outside-MAS).
- CHANGE — **`EnableLowLatencyRateControl` MEASURED for HEVC on Apple Silicon** (7.5ms; CQ 24ms too slow → live = low-latency-RC, crisp = Session B). queueDepth: keep **2–3** (latency) instead of Sunshine's 5, with a spike.
- ADD — client-side cursor (highest impact); 4-flag recipe + RequireHWEncoder + NV12 zero-copy; lossy-first→lossless-upgrade; CADisplayLink pacing; LTR+FEC instead of forced IDR; window-geometry channel; coordinate mapping as risk #1; 2–4 concurrent VTCompressionSession limit.

---

## 6. Open spikes → **mostly resolved, see [18](18-risk-resolutions.md)**

The 8 spikes in the first draft have been researched to solutions + skeptic-verified ([18]): #2 threading, #3 coordinate, #7 reconnect, #8 rate-control = **SOLVED**; #5 cursor-strip, #4 decode, #6 concurrent-encoder = **BOUNDED** (spikes with decision rules). What remained was **measurement on hardware** (now done — see [18 §0]):

1. **Real PATH 1 echo latency on the mesh** at 5ms & 20ms RTT → decides whether a predictor is needed. *(most important for PATH 1; unresolved because it needs measurement)*
2. **SPIKE F** decode→display p99 < 1 frame (16.7ms@60fps) on a real client.
3. **SPIKE G** N HW `VTCompressionSession`s per chip @1080p/1440p → concurrent-window bound.
4. **SPIKE D** `showsCursor=false` cleanly strips the per-window cursor (window on-screen).

> **The old risk #1 (CGEvent coordinates / background input) is gone:** the **activate-then-control, 1 window at a time** decision ([18 A]) eliminates the SkyLight private API + the Chromium background failure + macOS 26 fragility.

---

## 7. Sources

Full corpus (7 families × survey+deepdive + synthesis, with verified source/patent/RFC URLs): **[research/17-tui-gui-best-solution.json](research/17-tui-gui-best-solution.json)**.

Main anchors: Mosh `terminaloverlay.{h,cc}` + `transportsender`; Eternal Terminal `BackedWriter/BackedReader`; WezTerm `renderable.rs`; VVTerm + Geistty (libghostty external-IO in production) + the `wiedymi/daiimus ghostty` forks; Blink/SwiftTerm (iOS UIKit); Sunshine `video.cpp`/`sc_capture.m` + Moonlight `RtpVideoQueue`; Parsec patent US 9,798,436; Xpra auto-refresh; FFmpeg `videotoolboxenc.c`; WWDC22 s10155 (SCKit) + WWDC21 (VideoToolbox LTR).
