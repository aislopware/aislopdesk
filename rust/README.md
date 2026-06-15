# aislopdesk-core (Rust)

The portable, side-effect-free **core** of Aislopdesk and the **single source of truth**
for its logic: the wire codecs (terminal `WireMessage` + the video protocol), FEC + frame
reassembly, the realtime controllers (congestion/ABR, FPS governor, LTR, decode
gate/sequencer, jitter-depth pacer, delay-gradient trendline, recovery admission),
coordinate mapping, the pure host server-logic (session state machine, the N-session
UDP-mux router, input/recovery routing, motion coalescing, virtual-display / window /
capture-region / system-dialog math, the PTY-output sniffer), and
the terminal/PTY protocol incl. the SSH-style channel mux + per-channel flow control. Safe
Rust, zero runtime dependencies.

The Swift/SwiftUI apps are the platform shell (ScreenCaptureKit capture, VideoToolbox
codec, Metal, input injection, PTY spawn, AX, UI). They either call this core over a C-ABI
boundary — `aislopdesk-ffi` → the `CAislopdeskFFI` SwiftPM target → `libaislopdesk_ffi.a`
(built by `rust/build-apple.sh`, macOS arm64 slice; iOS slices are a follow-up) — or, for
the surfaces still implemented natively in Swift for performance, keep a copy that **tracks
this core** (held in agreement, verified by golden parity; never the reverse). The same
core is the basis for an **Android client** over C-ABI / JNI — the ALVR split: Rust owns
reassembly/FEC/jitter/ABR/recovery and the server brain; the platform shell owns capture,
the socket, and the hardware codec.

## Why a C-ABI boundary

The boundary is a **hand-written, zero-dependency C header** (`aislopdesk_ffi.h`),
mirroring the `#[repr(C)]` surface by hand. cbindgen was considered but the header is
hand-maintained to keep the crate dependency-free. C ABI over uniffi (its callback
interfaces are soft-deprecated and its serialization is unfit for 60 fps); libsignal and
ALVR use the same C-ABI boundary.

## Layout

```
rust/
  Cargo.toml              workspace (lints: forbid unsafe, pedantic clippy, no warnings)
  aislopdesk-core/        the core (rlib, zero runtime dependencies)
    src/
      bytes.rs            big-endian wire reader/writer (zero-copy reads)
      error.rs            VideoProtocolError { Truncated, Malformed }
      seq.rs              wrap-aware u32 sequence distance
      nal_unit.rs         AVCC NAL-unit split/join
      geometry.rs         VideoPoint/Size/Rect + aspect-fit (fit/fill, zoom/pan) + CGRect union/intersection/standardize
      fec.rs              FecScheme trait + XOR parity (single-loss recovery)
      adaptive_fec.rs     wire tier↔group-size + loss→tier decision (hysteresis/dwell)
      fragment.rs         19-byte fragment header/flags + host packetizer
      interleaver.rs      burst-resilient transmission reorder
      reassembler.rs      frame reassembly, loss detection, FEC, recovery queue
      cursor.rs           cursor position + shape side-channel codecs
      window_geometry.rs  move/resize/bounds/title codec
      input_event.rs      mouse/key/scroll/text client→host codec
      video_control.rs    session bring-up (hello/ack/resize/lists/cadence …)
      recovery.rs         ack / LTR-refresh / IDR / cursor-shape / network-stats codec
      recovery_policy.rs  escalation clock, request redundancy, loss-observation window
      coordinate_mapping.rs  normalised→host-window-point + multi-monitor scale pick
      ycbcr.rs            BT.709 YCbCr→RGB coefficients (f32, GPU-exact)
      keepalive.rs        keepalive / idle-timeout timing contract
      mux_header.rs       UDP channel-mux header (additive)
      --- realtime controllers (pure value types) ---
      network_estimate.rs        folded RTT/loss/OWD-trend estimate (EWMA, min-RTT baseline)
      live_congestion_controller.rs  AIMD ABR (proportional RTT cut, knee, cut-cascade guard)
      live_bitrate_policy.rs     resolution-aware live bitrate ceiling
      fps_governor.rs            content/congestion fps ladder + EncodeCadenceGate + SelfHealCadence
      ltr_controller.rs          WF-8 long-term-reference acked-only recovery gate
      recovery_idr_policy.rs     delivery-keyed recovery-IDR admission (casualty bypass)
      recovery_request_deduper.rs  host-side recovery-request dedup ring
      idle_reap_decider.rs       never-reap-without-keepalive idle reaper (generic FlowID)
      decode_frontier.rs         client wrap-aware highest-decoded frontier
      decode_gate.rs             drop-until-anchor decode admission
      decode_sequencer.rs        in-order decode release (frontier=N−2 fix)
      owd_late_detector.rs       per-frame one-way-delay spike detector (depth v3)
      trendline_estimator.rs     libwebrtc OLS delay-gradient detector + TrendSampler
      pacer_depth_policy.rs      adaptive 1↔2 jitter-depth (network-late driven)
      --- host server logic (pure value types) ---
      video_session.rs           host session state machine (hello/ack/bye/resize) + SizeNegotiation
      video_mux_router.rs        N-session UDP-mux admit/retire/drain routing + bootstrap gate
      input_router.rs            input-datagram route + activate-then-control raise policy
      input_button_balance.rs    stuck-button pre-release / duplicate-up suppression
      input_motion_coalescer.rs  order-preserving pointer-motion run coalescing
      recovery_router.rs         recovery-channel route (IDR / LTR-refresh / ack / cursor / stats)
      static_idr_decider.rs      static-window forced-IDR heartbeat cadence
      udp_receive_loop_policy.rs UDP receive-loop re-arm + exponential backoff
      capture_region.rs          dialog-expand capture-region union + retarget hysteresis
      window_placement.rs        window→display placement clamp + fit check
      window_parking_ledger.rs   VD window-park refcount + channel→window bookkeeping
      virtual_display_geometry.rs HiDPI point/pixel/mm math + display placement / chip limit / refresh
      system_dialog_detector.rs  system auth-dialog (SecurityAgent/coreauthd) classifier
      host_output_sniffer.rs     PTY-output OSC/title/bell/OSC-133/notification byte state machine
      --- terminal (PTY) path ---
      terminal/
        error.rs           TerminalProtocolError { FrameTooLarge, Truncated, UnknownMessageType, MalformedBody }
        reader.rs          terminal-local big-endian forward reader
        session.rs         16-byte SessionId (the wire UUID) + NEW_SESSION
        wire_message.rs    WireMessage codec (output/input/resize/hello/title/bell/cmd-status/notify/ping/pong)
        frame_decoder.rs   streaming length-prefixed frame decoder (cursor + lazy compaction)
        mux/
          envelope.rs               MuxFrame + MuxEnvelopeCodec (SSH-style channel framing)
          frame_decoder.rs          streaming mux-envelope splitter
          channel_table.rs          odd-id allocator + SSH close state machine + terminal-ring bound
          flow_credit_policy.rs     sender-side per-channel credit window
          receive_window_accountant.rs  receiver-side half-window replenish decision
          bounded_queue_policy.rs   host PTY-read backpressure decider
          flow_control.rs           shared window/queue sizing constants + env resolvers
    tests/
      golden_parity.rs    cross-language byte/bit parity test
      vectors/golden_vectors.json   corpus emitted by the corevectors dumper
  aislopdesk-ffi/         the C-ABI boundary (rlib + staticlib + cdylib)
    src/lib.rs            extern "C" surface over the core; the ONLY crate that may use `unsafe`
    include/aislopdesk_ffi.h   hand-maintained C header (mirrors the #[repr(C)] surface)
    tests/
      ffi_boundary.rs     Rust tests driving the extern "C" surface as a C caller would
      smoke.c             a real C consumer (proves cross-language linkage + ABI agreement)
      run_c_smoke.sh      build + link + run smoke.c against the static library
```

## Invariants

- **No `unsafe`** in the core — enforced crate-wide by `#![forbid(unsafe_code)]`. The only
  crate permitted `unsafe` is the `aislopdesk-ffi` boundary.
- **No dependencies** in the shipped library (dev-only `serde_json` for the parity test).
- **Never panics on untrusted input** — every decoder of network bytes returns `Result`; a
  corrupt datagram is dropped, never a crash. (The one documented panic is host-side
  `packetize` on a >77 MB frame — unreachable from the wire.)

## Verification

The Rust core is the canonical implementation; cross-language agreement is proven by a
golden corpus. `aislopdesk-corevectors` (a Swift executable) regenerates the deterministic
JSON corpus by driving the Swift shell's copies through their public API; the Rust
`golden_parity` integration test asserts this core reproduces that corpus **byte-identically**
(encoder output) and **bit-identically** (coordinate math, YCbCr coefficients, and the
controllers' EWMA / OLS-regression / median / threshold float state, all via IEEE bit
patterns) — i.e. the Swift copies still track the core. Regenerate after any
wire/controller change:

```sh
swift run aislopdesk-corevectors > rust/aislopdesk-core/tests/vectors/golden_vectors.json
```

On top of the golden corpus:

- **Per-subsystem differential + fuzz tests** across the codec and controller families
  (round-trips, edge cases, FEC recovery, reassembly scenarios, ABR/FEC decision tables,
  hostile-input drops).
- **`aislopdesk-ffi`**: 27 tests, `clippy --all-targets` clean, `fmt` clean, and a real C
  smoke test (`-Werror` against the `.a`) proving ABI agreement.
- **Full app suite** green (~2188 tests, 0 failures).
- **HW loopback E2E** (`aislopdesk-loopback-validate --smoke`, unsandboxed): real HEVC
  encode → packetize → reassemble → decode (10/10) plus the controller drive, 0 failures.

## Develop

```sh
cd rust
cargo test                  # unit + golden-parity
cargo clippy --all-targets  # pedantic, zero warnings expected
cargo fmt --check
./build-apple.sh            # libaislopdesk_ffi.a (macOS arm64) for CAislopdeskFFI
```

## Roadmap

Implemented:

- the complete video-protocol wire surface (the ALVR boundary spine);
- all 14 pure realtime controllers (ABR/congestion, fps governor, LTR, decode
  gate/sequencer, jitter-depth pacer policy, delay-gradient trendline, recovery admission);
- the pure **host server logic** (PATH 2 server brain): the session state machine
  (`video_session`), the N-session UDP-mux router (`video_mux_router`), the input/recovery
  datagram routers + motion-coalescing + button-balance, the static-IDR + UDP-backoff
  policies, and the virtual-display / window-parking / capture-region / system-dialog math —
  everything a headless multi-session host runs that is NOT capture/encode/inject/AX;
- the complete terminal/PTY path (PATH 1): the `WireMessage` framing, the SSH-style channel
  mux (`MuxEnvelope`/`MuxFrameDecoder`/`ChannelTable`), and the per-channel credit flow
  control (`FlowCreditPolicy`/`ReceiveWindowAccountant`/`BoundedQueuePolicy`) — see
  [`terminal`](aislopdesk-core/src/terminal). Kept in its own namespace (own error type +
  big-endian reader) to keep the module boundary explicit;
- the **C-ABI boundary** (`aislopdesk-ffi`): the `extern "C"` surface — `staticlib` for
  Apple, `cdylib` for a dynamic/Android consumer — with a hand-maintained C header and a
  real C smoke test. It covers the terminal path's streaming `FrameDecoder` (opaque
  handle), the `WireMessage` codec (a flat `#[repr(C)]` struct + `encode`), and wrap-aware
  `seq` arithmetic — enough to exercise every hard boundary pattern (opaque handles,
  Rust-owned buffers, status codes, null-safety).

Next:

1. **Widen the FFI surface**: extend the boundary over the video pipeline — `Reassembler` /
   FEC and the realtime controllers — as a coarse "Rust owns the pipeline" seam (the shell
   pumps datagrams in and gets assembled NAL units + encoder decisions out via a zero-copy
   callback), then the remaining terminal mux/flow-control. The header can move to `cbindgen`
   generation (with a CI check that it matches the curated header) once the surface is large
   enough to warrant it.
2. **Android build**: `cargo-ndk` producing `.so`s for `aarch64/armv7/x86_64-linux-android`
   plus a JNI shim, behind a foreground service for Doze.

Each tranche keeps the same discipline: golden + differential tests, no shipped
dependencies, no `unsafe` in the core (only in `aislopdesk-ffi`).
