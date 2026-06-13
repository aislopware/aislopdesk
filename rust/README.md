# aislopdesk-core (Rust)

The portable, side-effect-free **core** of Aislopdesk, reimplemented in safe Rust as a
byte- and behaviour-identical port of the Swift pure-algorithm targets. Its purpose is
to let a future **Android client** link the exact same wire codecs, FEC, reassembly, and
recovery logic that the macOS/iOS app runs — over a C ABI / JNI boundary (the ALVR
pattern: Rust owns reassembly/FEC/jitter/ABR/recovery; the platform shell owns capture,
the socket, and the hardware codec).

This crate is a **parallel source of truth**, not a replacement. The Swift app keeps
running its native implementations untouched, so the existing hot path takes **zero
performance risk**. Equivalence with Swift is *proven*, not assumed (see Parity below).

## Why this approach

Per the 2026-06-11 research verdict (`memory/rust-restart-research-verdict.md`): a full
Rust rewrite was rejected 3/3 — the Swift hot path is ~1.5 ms/frame and all the latency
is policy/architecture, so a language swap buys nothing. What *is* worth sharing for
Android is the ~5.5k LOC of pure, side-effect-free algorithm code. That is what lives
here. C ABI (cbindgen) was chosen over uniffi (callback ifaces soft-deprecated, its
serialization unfit for 60 fps); libsignal and ALVR both use the same C-ABI boundary.

## Layout

```
rust/
  Cargo.toml              workspace (lints: forbid unsafe, pedantic clippy, no warnings)
  aislopdesk-core/        the pure port (rlib, zero runtime dependencies)
    src/
      bytes.rs            big-endian wire reader/writer (zero-copy reads)
      error.rs            VideoProtocolError { Truncated, Malformed }
      seq.rs              wrap-aware u32 sequence distance
      nal_unit.rs         AVCC NAL-unit split/join
      geometry.rs         VideoPoint/Size/Rect + aspect-fit (fit/fill, zoom/pan)
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
      --- realtime controllers (pure value types, ported from Host/Client) ---
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
      --- terminal (PTY) path: a port of `Sources/AislopdeskProtocol` ---
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
      vectors/golden_vectors.json   corpus emitted by the Swift dumper
  aislopdesk-ffi/         the C-ABI boundary (rlib + staticlib + cdylib)
    src/lib.rs            extern "C" surface over the core; the ONLY crate that may use `unsafe`
    include/aislopdesk_ffi.h   hand-maintained C header (mirrors the #[repr(C)] surface)
    tests/
      ffi_boundary.rs     Rust tests driving the extern "C" surface as a C caller would
      smoke.c             a real C consumer (proves cross-language linkage + ABI agreement)
      run_c_smoke.sh      build + link + run smoke.c against the static library
```

## Invariants

- **No `unsafe`** — enforced crate-wide by `#![forbid(unsafe_code)]`. Any FFI will live
  in a separate boundary crate.
- **No dependencies** in the shipped library (dev-only `serde_json` for the parity test).
- **Never panics on untrusted input** — every decoder of network bytes returns
  `Result`; a corrupt datagram is dropped, never a crash. (The one documented panic is
  host-side `packetize` on a >77 MB frame, mirroring the Swift trap — unreachable from
  the wire.)

## Parity — the "no mistakes" guarantee

`Sources/aislopdesk-corevectors` (a Swift executable) emits a deterministic JSON corpus
from the **real** `AislopdeskVideoProtocol` codecs using only their public API. The Rust
`golden_parity` integration test replays it and asserts **byte-identical** encoder output
and **bit-identical** numeric output (coordinate math, YCbCr coefficients, and the
controllers' EWMA / OLS-regression / median / threshold float state, all via IEEE bit
patterns) across every codec/decision family. Regenerate after any wire/controller change:

```sh
swift run aislopdesk-corevectors > rust/aislopdesk-core/tests/vectors/golden_vectors.json
```

In addition, every Swift unit test has a mirrored Rust unit test (round-trips, edge
cases, FEC recovery, reassembly scenarios, ABR/FEC decision tables, hostile-input drops).

## Develop

```sh
cd rust
cargo test                  # unit + golden-parity
cargo clippy --all-targets  # pedantic, zero warnings expected
cargo fmt --check
```

## Roadmap

Ported so far:

- the complete `AislopdeskVideoProtocol` wire surface (the ALVR boundary spine);
- all 14 pure realtime controllers from `AislopdeskVideoHost`/`Client` (ABR/congestion,
  fps governor, LTR, decode gate/sequencer, jitter-depth pacer policy, delay-gradient
  trendline, recovery admission);
- the complete `AislopdeskProtocol` terminal/PTY path (PATH 1): the `WireMessage` framing,
  the SSH-style channel mux (`MuxEnvelope`/`MuxFrameDecoder`/`ChannelTable`), and the
  per-channel credit flow control (`FlowCreditPolicy`/`ReceiveWindowAccountant`/
  `BoundedQueuePolicy`) — see [`terminal`](aislopdesk-core/src/terminal).

Every one is a side-effect-free value type with its Swift unit suite mirrored 1:1, and for
the wire/float-heavy ones a byte/bit-exact golden vector. The terminal namespace is kept
separate from the video path (its own error type + big-endian reader) to mirror the Swift
module boundary exactly.

- the **C-ABI boundary** (`aislopdesk-ffi`): the `extern "C"` surface — `staticlib` for
  Apple, `cdylib` for a dynamic/Android consumer — with a hand-maintained C header and a
  real C smoke test proving cross-language linkage + ABI agreement. This is the *one* crate
  allowed to use `unsafe`; the core stays 100% safe. The surface today covers the terminal
  path's streaming `FrameDecoder` (opaque handle), the `WireMessage` codec (a flat
  `#[repr(C)]` struct + `encode`), and wrap-aware `seq` arithmetic — enough to prove every
  hard boundary pattern (opaque handles, Rust-owned buffers, status codes, null-safety).

Future tranches, in the verdict's port order:

1. **Widen the FFI surface**: extend the boundary over the video pipeline — `Reassembler`/
   FEC and the realtime controllers — as the coarse "Rust owns the pipeline" boundary (the
   shell pumps datagrams in and gets assembled NAL units + encoder decisions out via a
   zero-copy callback), then the remaining terminal mux/flow-control. The header can move
   to `cbindgen` generation (with a CI check that it matches the curated header) once the
   surface is large enough to warrant it. *(partially landed)*
2. **Android build**: `cargo-ndk` producing `.so`s for `aarch64/armv7/x86_64-linux-android`
   plus a JNI shim, behind a foreground service for Doze. *(deferred)*

> **On replacing Swift with this port.** The FFI boundary is the mechanism by which the
> macOS/iOS app *could* call these Rust codecs instead of its native Swift ones. That swap
> is a deliberate, per-call-site, benchmarked step — not a blanket rewrite: the 2026-06-11
> verdict rejected a wholesale Swift→Rust hot-path replacement on performance grounds (the
> Swift path is ~1.5 ms/frame and all latency is policy/architecture). The Rust port's
> primary consumer remains the Android client, which has no Swift to replace.

Each tranche keeps the same discipline: golden differential tests against the Swift suite,
no shipped dependencies, no `unsafe` in the pure core (only in `aislopdesk-ffi`).
