# 31 — Terminal-path smoothness overhaul (2026-06-12 overnight)

**Status: DONE + reviewed + loopback-verified. ⚠️ NOT DEPLOYED — read the deploy section before restarting anything.**

After the video path reached Parsec parity, this round made the TERMINAL path (host PTY → TCP mux → libghostty) as smooth as the architecture allows. 9 commits on `main` (`1021def..58fa8ed`), full suite 1726/0, macOS + iOS apps build, `check-macos.sh --connect` PASS, cua loopback rig verified (flood + instant Ctrl-C + live RTT badge).

## What changed (one line each)

| Commit | Change |
|---|---|
| `1021def` | Client IN batch-drain: `AislopdeskClient` inbox + `bufferingNewest(1)` wake + `takeOutputBatch`; `TerminalViewModel.ingestBatch` 256 KiB budget passes; `GhosttySurface.feedBatch` = N writes + ONE refresh/present per batch |
| `6e3f4fe` | Host drain-merge (≤32 KiB, `.exit` barrier) + fused `HostOutputSniffer` (1 pass, memchr fast path; 60→264 MiB/s worst-case) + control-sender split + queue 256→64 KiB + read chunk 128→32 KiB + `MuxByteLink.sendPipelined` |
| `d81b275` | **Credit-at-consumption**: grants fire from the real consumer (`MuxSubChannel.noteConsumed` → `recordConsumed`), window 256→64 KiB, input split 16 KiB, host PTY writes on a dedicated queue |
| `3be3b01` | OUT drain off-main + `packInputs` (merge tiny / split 16 KiB, resize barrier) + SINGLE input funnel (`InputBarModel.sendSink`; iOS dual-drain + macOS submit-Task deleted — docs/29 fix) |
| `8f0c0f2` | Render: layout same-size guard (macOS+iOS), display-link idle pause, iOS gated tick (simulator keeps free-run) |
| `af868f9` | Ping/pong RTT (wire types 14/24, control channel, 3 s, EWMA α=0.25) → `ConnectionViewModel.latencyMS` |
| `7183aca` | Review-round fixes: **13-byte dead-zone stall** (see below), reconnect inbox clear, cancelled-observe guard, controlOut bound, exit latch 2→10 s |
| `7145114` | Live RTT badge in the pane chrome (amber >100 ms) |
| `58fa8ed` | Cancelled ingest stops mid-batch between budget passes |

## Why it's smoother (the mechanisms)

- **Flood no longer owns the main thread**: one MainActor pass per backlog (budget 256 KiB + yield) instead of one job + one VT parse + one renderer wakeup per wire chunk. VT parse runs ON the calling thread (fork patch `:2284`) — that's why batching matters.
- **Echo head-of-line under flood**: in-host committed backlog ~640 KiB → ~96 KiB; in-flight window 256→64 KiB. At the live ~12 Mbps WAN: ~437 ms → ~87 ms worst.
- **Ctrl-C is instant**: credit-at-consumption bounds client-side un-rendered bytes to ~2 windows (~128 KiB). Verified on the rig: the prompt is back in the same screenshot as the press.
- **Typing under flood**: the OUT drain runs off-main (keystroke sends no longer queue behind ingest/render main-actor work).
- **Idle panes are free**: display link pauses when presentTicks drain; iOS device tick is gated (was 60 Hz × pane forever).

## ⚠️ DEPLOY: both ends TOGETHER, or stall

`MuxFlowControl.initialWindowBytes` (256→64 KiB) is a both-ends constant with NO negotiation, and `ping` (type 14) is channel-fatal to an old decoder. **Old client + new host = permanent channel stall on the first flood** (old grant threshold 128 KiB > new window 64 KiB). The Studio production hostd (`.build/release/aislopdesk-hostd --port 7420`) is still the OLD binary on purpose; the MacBook was offline (ssh timeout) so nothing was deployed. Redeploy host + MacBook client in one go (recipe in the run-server-client memory / docs/21).

## The review round's lesson (worth keeping)

27-agent adversarial review of the night's diff caught a HIGH the 1726-test suite couldn't: frame caps bounded **payload** while the sender debits **wire bytes** (payload + 13-byte `.output` header) → max frame 32 781 > window/2 32 768 → a credit park whose partial-frame prefix landed in that 13-byte dead zone could never re-grant (receiver can only credit COMPLETE decoded frames). Rule of thumb now encoded in `MuxFlowControl.maxOutputFramePayloadBytes = min(mergeCap, window/2 − 16)` + head-chunk splitting: **with credit-at-consumption, always reason in wire bytes, and only complete-frame bytes are creditable.**

## Knobs (env)

`AISLOPDESK_MUX_WINDOW` (⚠️ set identically in BOTH processes), `AISLOPDESK_MUX_HOST_QUEUE` (host-local), `AISLOPDESK_MUX_MERGE_CAP` (cross-clamped — safe at any in-range value).

## Follow-ups (ranked)

1. **HW feel-test + deploy** (both ends; then type-under-flood, drag-resize, multi-pane flood on the real WAN).
2. **iOS real-device check** of the gated tick (type/echo, pan-scrollback, cursor blink) — simulator keeps the free-run deliberately; blink rides the renderer's own present path in theory, unverified on device.
3. **Predictive-echo glitch caret** (docs/12 §B deferred design) — now HAS its RTT gate (`latencyMS` > ~30 ms). The remaining latency masker for WAN typing.
4. **Echo-RTT AUTOTYPE instrumentation** — make `check-macos.sh --connect` emit keystroke→render latency numbers, not pass/fail.
5. **Off-main feed** (per-surface serial queue for `write_output` — the C contract allows it; needs a teardown barrier vs `close()`).
6. `TerminalModeTracker` could take the same memchr ground fast path as `HostOutputSniffer`.
