# Swift → Rust swap — status (branch `rust-swap`)

What was actually executed against the plan in `SWAP_PLAN.md`. Every commit is green; the
branch is **not** pushed/merged — review it, then merge when satisfied.

## Mechanism (keystone)

`CAislopdeskFFI` SwiftPM C target wraps the hand-written `aislopdesk_ffi.h` and links the
prebuilt `libaislopdesk_ffi.a` (built by `rust/build-apple.sh`, macOS arm64 slice). Swift
modules that swap call into it through a contained bridge (`RustFFI` in AislopdeskProtocol,
`RustVideoFFI` in AislopdeskVideoProtocol, `RustVideoHostFFI` in AislopdeskVideoHost) — the
one file per module that holds `import CAislopdeskFFI`. Each swap replaces only the
**implementation body** behind the **unchanged Swift public API** (strangler pattern); the
native body is retained as `*Native` for differential tests + fallback.

## Swapped (live path now runs Rust)

| Subsystem | Module | Shape | Perf | Parity proof |
|---|---|---|---|---|
| Terminal wire codec (`WireMessage` encode/decode) | AislopdeskProtocol | buffer, **size-gated** | bulk >8 KiB stays native (bench-driven) | `RustWireParityTests` (byte-id + 5k fuzz) + full PATH-1 e2e |
| `LiveBitratePolicy` (target/minimum bitrate) | AislopdeskVideoHost | pure scalar | Rust ≥ native | `LiveBitratePolicyTests` |
| Cursor codec (`CursorUpdate` encode/decode) | AislopdeskVideoProtocol | small fixed (36 B) | Rust faster | `CursorRustParityTests` (3k fuzz) + `CodecTests` |
| `AdaptiveFECPolicy` (tier / group_size / next_tier_state) | AislopdeskVideoProtocol | pure scalar (+ value-state) | none | `RustAdaptiveFECParityTests` (20k fuzz) + `AdaptiveFECPolicyTests` |
| `CoordinateMapping` (window point / CG↔Cocoa / backing scale) | AislopdeskVideoProtocol | pure scalar (screens borrowed) | none | `RustCoordinateMappingParityTests` (8k fuzz) + `CoordinateMappingTests` |
| `RecoveryPolicy.shouldEscalateToIDR` | AislopdeskVideoProtocol | pure scalar | none | `RustRecoveryPolicyParityTests` (8k fuzz) + recovery tests |

Env knobs (`AISLOPDESK_BPP`, `AISLOPDESK_FEC_ALLOW_OFF`, `AISLOPDESK_ESCALATION_FLOOR_MS`)
stay resolved Swift-side and cross as params, so the Rust core stays environment-free.

## KEEP-SWIFT (deliberately NOT swapped)

- **Stateful realtime controllers** — `LiveCongestionController`, `FPSGovernor`,
  `LTRController`, `NetworkEstimate`, `DecodeGate`, `DecodeFrontier`, `RecoveryIDRPolicy`,
  `RecoveryRequestDeduper`, `IdleReapDecider`, `OwdLateDetector`, `TrendlineEstimator`,
  `PacerDepthPolicy`, `DecodeSequencer`. **They are `public struct … Sendable, Equatable`
  value types** (state crosses actors by copy; tests compare by value). Replacing their
  internals with an opaque mutable Rust handle would break value semantics (aliasing on
  copy), break `Equatable`/`Sendable`, and break tests — a correctness *and* code-quality
  regression. This **revises** the research plan, which proposed opaque handles without
  accounting for the value-type contract. (A future option: a state-by-value pure-transition
  variant for the scalar-state ones; large-state ones marshal too much to be worth it.)
- **Bulk-buffer codecs** — terminal `.output`/`.input` > 8 KiB, and the video
  packetizer/reassembler/FEC/mux data path. The terminal benchmark proved the FFI's extra
  buffer copies regress the bulk path 5–7× at 64–128 KiB; the no-perf-regression rule keeps
  them native.
- The FEC scheme, fragment interleaver, NAL splitter, cursor-shape bitmap, the per-frame
  renderer (AspectFit/YCbCr in MSL), flow-control/queue policies under locks, and
  compile-time constants — per the plan's reasons (zero-copy slices, held-lock atomicity,
  per-pixel hot paths, env-must-match-both-processes).

In every keep-swift case the **Rust port still exists and is the source of truth for the
Android client** (which has no Swift value-type contract / native fast path to preserve).

## Drafted, FFI-ready, integration deferred

`geometry` (AspectFit event-rate uses) and `ycbcr` (renderer coefficient selector) were
drafted by the workflow but not integrated this pass: the AspectFit/YCbCr call sites are
intertwined with the **per-frame Metal renderer** (KEEP-SWIFT for the per-frame path), so a
safe swap needs the event-rate vs per-frame split + a coefficient cache — a careful follow-up
on an HW-gated path. The drafts are in the run transcript.

## Verification (all green on this Mac Studio)

- Per-swap **differential + fuzz** tests (native vs Rust, thousands of iterations each).
- **Full Swift suite: 2187 / 0** (was 2166 pre-work).
- **`aislopdesk-ffi`: 27 unit + integration tests**, `clippy --all-targets` 0 warnings,
  `fmt` clean, **C smoke OK** (`-Werror` against the `.a` — ABI agreement proof).
- **`corevectors` byte-exact**: re-running the golden-vector dumper through the *swapped*
  Swift codecs produces output **identical** to the pre-swap golden vectors.
- **HW loopback E2E** (`aislopdesk-loopback-validate --smoke`, unsandboxed): real HEVC
  encode→packetize→reassemble→decode (decodeOK 10/10) + the controller drive (incl. the
  swapped AdaptiveFEC tier ladder, LiveBitrate ceiling, computeRTTMillis) — **0 failures**.

## Benchmark (terminal codec, ns/op, Mac Studio — the rule-setter)

```
encode  ack(13B)  native 1031  rust  317  0.31x      decode  ack       1307 → 257  0.20x
        1 KiB           1246       620  0.50x                 1 KiB     1999 → 496  0.25x
        16 KiB          1631      1573  0.96x                 16 KiB    2277 →1173  0.51x
        64 KiB          2495     13543  5.43x  ← gate          64 KiB   3015 →12124 4.02x
        128 KiB         3749     25925  6.92x                  128 KiB  4406 →22211 5.04x
```

→ scalar / small-buffer → Rust faster; bulk buffers → native. The 8 KiB
`RustFFI.payloadThreshold` sits safely below the ~16 KiB crossover.
