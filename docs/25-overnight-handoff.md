# 25 — Overnight handoff (2026-06-04): mouse-delay fix, connection-mux foundation, resize foundation, audit

Branch: **`feat/video-overnight`** (off `main`, **not pushed**). All work is committed; `main` is untouched and remains the stable fallback.

Working constraints this session (recorded so the rationale is clear):
- The MacBook Pro was OFF; all testing was on the Mac Studio (loopback / synthetic / headless).
- **No runtime GUI/hardware verification was possible autonomously** (TCC + a real unlocked GUI session are required for capture/inject/render; `kill`/`pkill` are permission-blocked here so a verification host daemon couldn't be spawned-and-cleaned). Every "passes" claim below is from a real `swift build` + `swift test --filter` run **in the main agent** (never a relayed sub-agent self-report); every feature's *runtime* is flagged hardware-pending where it applies.
- Never ran a bare `swift test` (the HostServer E2E suites hang). Only `swift build` + `swift test --filter <Class>`.

## Commits (in order)

| Commit | What | Verified |
|--------|------|----------|
| `f1b9d7f` | host `captureScale` clamp to display backing-scale (the "1 góc" render + click-desync fix) | hardware (user, earlier) |
| `93bdc16` | **host motion coalescer** — the mouse-delay fix | headless (43 tests) |
| `19dfa66` | **client motion throttle** — complements the coalescer | headless (139 tests) |
| `dfdca75` | **connection-mux S0** — pure multiplexing foundation (additive) | headless (69 tests) |
| `bfa0205` | **resize S0** — protocol + pure negotiation foundation (additive/inert) | headless (108 tests incl. regression) |

---

## 1. Mouse "delay vài giây" — FIXED (done)

**Root cause** (multi-agent diagnosis, source-verified): the host inbound `AsyncStream` was *unbounded* and the single consumer *strictly serial* behind 3 synchronous WindowServer round-trips per motion event (`CGWarpMouseCursorPosition` + `CGAssociateMouseAndMouseCursorPosition` + `CGEvent.post`). A real trace was ~150:1 motion:button (1664 move + 163 drag vs 11 down), so under flood the backlog was ~99% stale pointer positions replayed FIFO → the cursor crawled through old positions seconds behind the user. The video path is latency-correct (FramePacer is most-recent-wins) and was **not** touched.

**Fix:**
- `InputMotionCoalescer` (pure, `VideoSessionLogic.swift`): collapse each consecutive same-class motion run (`.mouseMove` / `.mouseDrag`, separate buckets) to its latest; every button/key/scroll/text is a hard barrier that flushes pending motion first (never reorders → down/up framing + `InputButtonBalance` + stateless-drag intact).
- `InboundQueue` (lock-protected FIFO, appended on the transport serial queue, no actor hop) + a `bufferingNewest(1)` wakeup signal replace the unbounded datagram stream. The consumer batch-drains and coalesces — **self-regulating**: a no-op when keeping up (batch ~1), collapses runs only when injection falls behind, bounding lag to ~one injection regardless of flood.
- Client `VideoWindowPipeline` `@MainActor` motion pump: coalesce motion to one send per video-frame interval; buttons flush-before-send.
- Grounded in TigerVNC/noVNC `_flushMouseMoveTimer` latest-position rule + SE-0314.
- Legacy `RWORK_INPUT_UNORDERED` A/B path untouched.

**Hardware feel-test (morning):** move/drag-select fast on the Mac Studio loopback (or MacBook over NetBird) and confirm the cursor tracks live with no multi-second lag. `RWORK_INPUT_TRACE=1` on the host will now show far fewer `inject #N mouseMove` lines (coalescing visible).

---

## 2. Reuse 1 TCP + 1 UDP connection (#11) — S0 foundation done; wiring deferred

**Why only the foundation:** the full feature is a deep protocol change to the two most load-bearing wire paths. The terminal path's real E2E tests are exactly the HostServer suites that hang headlessly, so a transport refactor can't be E2E-verified autonomously — it should land with the user able to run `check-macos --connect` + the hardware A/B. The env-gate design means deferring costs nothing (default OFF = today byte-identical).

**S0 (committed `dfdca75`, additive — nothing constructs these yet, zero behaviour change):**
- TCP (`Sources/RworkProtocol/Mux`, `Sources/RworkTransport/Mux`): `MuxEnvelope`/`MuxFrameType`/`MuxEnvelopeCodec` (outer frame `[len][channelID][muxType][body]`, `channelData` carries an opaque `WireMessage` frame), `MuxFrameDecoder` (streaming splitter, `FrameDecoder` analogue), `ChannelTable` (odd-id allocator + SSH `CHANNEL_CLOSE`-symmetric lifecycle), `FlowCreditPolicy` (SSH-window credit math), `MuxRouter`/`HostChannelRouter` over `MuxRoutingCore` (pure channelID demux; unknown/closed-channel data dropped).
- UDP (`Sources/RworkVideoProtocol/Mux`, `Sources/RworkVideoHost/Mux`): `VideoMuxHeaderCodec` (channelID prefix + 19-byte `MuxFrameFragmentHeader`), `VideoMuxRouter` (admit/reject/dropRetired with reconnect-generation safety).

**Full staged design (the authoritative plan — implement on top of S0):**
- **S1** TCP mux wiring behind `RWORK_TCP_MUX` (default OFF): `ConnectionRegistry` (@MainActor refcounted Endpoint→shared connection, injected at `makeSession`/`VideoWindowFactory.shared`), `MuxClientTransport` (2 shared `NWConnection`s — keep the CONTROL/DATA split so a PTY burst can't stall a resize across panes — + one receive loop each + client `MuxRouter`), `MuxSubChannel` (conforms to the existing `MessageChannel` protocol, backed by a channelID, so `HostSessionTransport`/`RworkClient` stay structurally intact), host `HostChannelRouter` + `MuxSessionTransport`. Verify via an **in-memory loopback pipe test** (two `MuxSubChannel`s, no socket, no HostServer) + env-OFF parity via `RworkClientUITests`/`RworkTransportTests`/`RworkProtocolTests`.
- **S2** SSH-style `WINDOW_ADJUST` per-channel backpressure (`FlowCreditPolicy` wired) + reconnect-as-channel-reopen with full-physical-reconnect fallback.
- **S3** UDP video mux behind `RWORK_VIDEO_MUX`: client stamps channelID (= adopted `helloAck` streamID) on every datagram + filters inbound; host replaces the single-client pin (`NWVideoDatagramTransport`) with `VideoMuxRouter` dispatch + a `WindowSessionRegistry` so one daemon serves N windows on one port pair. Swap `FrameFragmentHeader` 15→19 bytes (bump video `version`). Runtime needs hardware (two-window HEVC decode).
- **S4** `WorkspaceStore.liveVideoCap` counts decode stacks, not channel refs.
- **S5** flip defaults ON after a hardware A/B confirms parity; keep the env var as an OFF escape hatch one release (like `RWORK_INPUT_UNORDERED`).
- **Honest tradeoffs:** one TCP for N terminals = head-of-line blocking (mitigated by the CONTROL/DATA split + per-channel WINDOW_ADJUST + a fallback second connection above a pane threshold); one UDP for N video streams = shared congestion (mitigated by keeping cursor on its own socket + per-channel pacing; QUIC via `NWMultiplexGroup` is the forward-compatible upgrade, deliberately deferred).
- **Known S0 follow-up for the wiring stage:** `MuxRoutingCore` opens a channel on `channelOpenAck` without checking the `accepted` flag — the IO layer must honor `accepted == false`.

---

## 3. Host-window resize to pane (#12) — feasibility YES; Stage 0 done

**Feasibility verdict: YES.** Both halves are platform-supported (macOS 12.3+/14+): foreign-window resize via `AXUIElementSetAttributeValue(kAXSizeAttribute)` and live capture re-size via `SCStream.updateConfiguration`. The dominant constraint is *not* API availability — it is moving the per-session `decodedSize` denominator (shared by input-normalize, renderer aspect-fit, cursor overlay, videoScale) mid-stream without desync, plus the fact that AX is best-effort (some apps refuse/clamp; treat the *achieved* size as authoritative, never echo the request).

**Key design insight:** `decodedSize` must follow the **decoded pixels**, not the control message — adopt the new size only when a decoded frame at that size actually arrives (frame-gated, with a forced IDR right after `updateConfiguration`), so input/cursor/render never disagree even for one frame.

**Stage 0 (committed `bfa0205`, additive + inert — no client sends resize yet, the new effect is a no-op, so the fixed-size path is byte-identical):**
- `VideoControlMessage.resizeRequest` (type 4, Float64 desired w/h + epoch) + `.resizeAck` (type 5, UInt16 w/h + epoch); types 1–3 byte-identical (regression-asserted).
- `SizeNegotiation` (pure): clamp to host min/max, UInt16-safe, never 0, NaN/inf-safe, swapped-bounds-safe; `isStaleEpoch` for UDP reorder/dup drop.
- `ResizeDebounce` (pure, client): coalesce a resize-drag burst to the settled size (settleInterval quiet + minDelta jitter floor), monotonic epoch; pass-time-in discipline like `LTREscalationTracker`. Not yet wired.
- `VideoSessionStateMachine.handleControl(.resizeRequest)`: streaming-only, stale-epoch drop, `resolveResizeSize` clamp (nil rejects without advancing epoch), emits `.resizeCapture`; no new streamID. Actor `apply(.resizeCapture)` is an inert dbg-only no-op with a `TODO(resize-stage)`.

**Remaining stages (flag-gated `RWORK_VIDEO_RESIZE`, hardware on the Mac Studio):**
- **Stage 1** client: wire `requestCaptureSize` into `VideoWindowPipeline.layoutChanged`, a lock-step `setCaptureSize`, and rewrite `updateDecodedSize` to **frame-gated adoption** (adopt `pendingCaptureSize` only when a decoded frame's `CVPixelBuffer` dims match) replacing the `width==0` one-shot. (Touches the working decode path — verify flag-OFF parity carefully.)
- **Stage 2** host: `InputInjector.resizeTargetWindow` (AX set/re-read achieved size), `WindowCapturer.updateSize` (`SCStream.updateConfiguration` + forced IDR), encoder reconfigure, actor `.resizeCapture` handler emitting achieved-size `.resizeAck`. Compiled + reviewed only (never called from a test, like `WindowCapturer.start`).
- **Stage 3** hardware bring-up + an AX-refusing-app fallback test.
- **Firewall:** keep `WindowGeometryMessage.resize` a client no-op so a host-driven resize can't echo back as a fresh request; epoch monotonicity drops stale/echoed requests.

---

## 4. Audit (#13) — `aa55aaa`

Adversarial sweep (find → **refute** → synthesize, 23 agents) across input / video / concurrency / protocol / UI. **4 real bugs** survived refutation; **12 candidates refuted** (e.g. WireGuard's Poly1305 MAC makes corrupt-but-parseable datagrams impossible → corruption is a *lost* fragment the existing FEC/loss machinery already handles; the input-ordering claims misread MainActor-inherited Task isolation, which preserves submission order).

| ID | Sev | Status | What |
|----|-----|--------|------|
| VIDEO-UI-1 | high | **fixed + tested** | Same-tick close+reopen stuck on "Video paused" — teardown freed the cap slot without re-bumping `videoPromotionGeneration`. Fix: bump at the teardown-completion site (gated on an actual release) + regression test. |
| CONCURRENCY-HOST-1 | high | **fixed** (runtime hardware-pending) | **Reconnect after a clean `bye` silently refused** until daemon restart (pinned UDP flow slot never cleared — UDP has no FIN). *This is the root of the chronic "restart the host before each client launch."* Fix: `VideoDatagramTransport.resetClientFlow()`, called on `bye`. **Crash-without-bye still needs an idle-timeout reaper (follow-up).** |
| VIDEO-CLIENT-1 | med | **fixed** | Hard decode failure only logged → pacer froze on the last good frame. Fix: `requestIDR()` in the generic decode catch (mirrors `awaitingKeyframe`). |
| VIDEO-HOST-1 | high | **documented, not shipped** | Client-recovery + ~1s heartbeat IDR never fire on a **static** window (both below `guard status == .complete`; only `.idle` frames arrive) → a recovering/joining client freezes until the window changes. Correct fix = retain the last `CVPixelBuffer` + timer re-encode a forced IDR, but it depends on SCStream IOSurface/queue-depth runtime behaviour that can't be verified headlessly (a wrong retain could stall capture / emit a stale surface). Documented at `WindowCapturer.swift:142` + here for hardware-in-the-loop. |

VIDEO-HOST-1 + VIDEO-CLIENT-1 **compound**: a single bad decode on a then-static window = indefinite freeze with input still live. Fix both together when bringing up VIDEO-HOST-1 on hardware.

**Top remaining follow-ups (need the Mac Studio):**
1. VIDEO-HOST-1 — forced/heartbeat IDR on a static window (retain-last-buffer + timer).
2. CONCURRENCY-HOST-1 residual — idle-timeout reaper for a crash-without-`bye` (the `bye` reset only covers clean disconnects; a lost `bye` datagram or a crash still wedges the slot until the path errors).
3. Resize Stage 0 latent note: `VideoSessionStateMachine.lastResizeEpoch` is not reset on a fresh `hello`-accept — reset it when the resize wiring (Stage 1+) lands, else a reconnected session would treat a low epoch as stale.

---

## Morning hardware checklist (Mac Studio, real unlocked GUI session; host BEFORE client — no hello-retry)

1. **Mouse delay** — fast move + 3-finger drag-select; confirm live tracking, no multi-second lag.
2. **(opt-in) connection mux** — once S1/S3 land: `RWORK_TCP_MUX=1` two terminal panes share one TCP; `RWORK_VIDEO_MUX=1` two remote-GUI panes share one UDP pair; A/B vs OFF.
3. **(opt-in) resize** — once Stage 1/2 land: `RWORK_VIDEO_RESIZE=1`, resize the pane, watch the host window + capture follow, click-after-resize lands correctly; test an AX-refusing app.

---

## Session 2 (2026-06-04) — resize + connection mux WIRED (was foundation-only); runtime [MS-confirm]

All on `feat/video-overnight` (not pushed). Each feature: ultracode research→design→implement→adversarial-review; every "green" below is my own `swift build` / `swift test --filter` / `scripts/check-ios.sh` run, not agent-reported. OFF paths proven byte-identical. **Both ends must set the same flag** (the mux wires are NOT backward-compatible). Runtime (AX resize / encoder rebuild / host TCP relay / live UDP+HW-HEVC / settle-timer firing) cannot be verified headlessly — that is what this checklist is for.

| Feature | Commit | Flag (default OFF) | Headless proof |
|---|---|---|---|
| Resize host window PATH A | `e202c34` | `RWORK_VIDEO_RESIZE` | macOS+iOS build, 75 tests (incl. `ResizeAdoptionTests`) |
| Mux Stage-0 accepted-flag fix | `cc636b9` | — (always on) | 56 mux tests |
| TCP mux S1 | `566af72` | `RWORK_TCP_MUX` | macOS+iOS build, 71 tests (loopback + ordering guard + refcount + OFF-identity) |
| UDP mux S3 | `6184915` | `RWORK_VIDEO_MUX` | macOS+iOS build, 47 tests (routing + registry + OFF-identity) |

### Resize PATH A test (`RWORK_VIDEO_RESIZE=1` on Rwork.app + rwork-videohostd)
1. The host needs the **Accessibility** TCC grant (it already does for input). Stream a window.
2. Drag the client pane to a clearly different size. Expect: after ~200ms quiet, **exactly one** `resizeRequest` logged (debounce; NOT one per drag frame — if it never fires on a clean drag-end, the settle-timer regressed).
3. Host log: `resizeCapture WxH epoch=N` → the **real host window physically resizes** (AX) → encoder rebuilds at the achieved size → forced IDR → `resizeAck`.
4. Client adopts the new size only when a matching-dimension frame lands; cursor + aspect-fit stay aligned (move mouse, confirm pointer lands on the right pixel).
5. Resize an **AX-refusing** window (fixed-size/sheet) → clean abort (no ack, old encoder kept), NOT a crash. Static-window-after-resize → watch for the VIDEO-HOST-1 freeze (still open).

### TCP mux S1 test (`RWORK_TCP_MUX=1` on both ends; host BEFORE client)
1. Open 2+ terminal/claude panes to the **same** host. `lsof -nP -iTCP -a -c rwork-hostd` → exactly **one CONTROL + one DATA** pair (not 2N). Type→exec→render in each independently.
2. **No HOL**: flood pane A (`yes | head -c 50M`) while typing in pane B — B stays responsive. (NOTE: S1 ships infinite-window + no CLSCTRL priority queue, so this may reveal the S2 need.)
3. **Pane close = channel close**: close one pane; the shared TCP stays up, other panes keep working.
4. **Reconnect doesn't drop shared**: drop/restart one pane — the shared transport other panes ride must survive.

### UDP mux S3 test (`RWORK_VIDEO_MUX=1` on both ends)
1. Open 2+ video panes (DIFFERENT windows) to the same host. `lsof -nP -iUDP -c rwork-videohostd` → **one media + one cursor** socket-pair (not 2N). Each pane renders its own window.
2. **bye retires only one lane**: close one video pane; the shared flow stays up, the other pane keeps streaming with no glitch.
3. **Per-channel loss isolation**: induce loss on one lane — only it shows decode gaps; the sibling NEVER tears down.
4. **OFF parity**: re-run the proven device-real iOS video cell with the flag OFF — unchanged (15-byte header).

### New residuals from this session's adversarial reviews (documented, not shipped blind)
- **Recurring bug class (fixed both mux stages):** unstructured-Task-per-frame loses FIFO ordering → scrambled terminal bytes / mouseUp-before-mouseDown. Fixed by inline delivery on the serial receive path; guarded by `testSingleChannelFloodPreservesOrder`.
- **Deferred:** per-channel flow control S2; **crash-without-bye idle reaper under mux** (analogue of CONCURRENCY-HOST-1; capture keeps running — needs UDP-liveness timing, noted at `NWVideoMuxDatagramTransport.installResetHandler`); resize AX-rollback on rare encoder/capturer failure; rapid-double-resize adoption edge; channelID UInt32 wrap.
- **Still open:** VIDEO-HOST-1 (static-window IDR freeze) — the one untouched audit item.
