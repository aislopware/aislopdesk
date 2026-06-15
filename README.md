# Aislopdesk

**Aislopdesk** is a terminal-first, low-latency remote-coding tool for Apple platforms — a
macOS **host** paired with macOS / iOS **clients**. The everyday use case: run a shell and
**Claude Code** on a remote machine and drive it from another device with feels-local
responsiveness. The performance-critical core is Rust behind a C-ABI; the Swift/SwiftUI apps
are the platform shell. The client terminal renderer is **libghostty**. Build floor:
**macOS 26 / iOS 26** (`Package.swift` uses `.v26`).

Aislopdesk adds **no app-layer encryption or auth**. It assumes deployment on a trusted
private network — typically a WireGuard mesh (e.g. [NetBird](https://netbird.io) or
Tailscale) that provides end-to-end encryption, node auth, and per-port ACLs — so the
security boundary is the network, not the app.

## Architecture

The performance-critical **core is Rust** — crate `rust/aislopdesk-core` (safe Rust, zero
runtime deps, `#![forbid(unsafe_code)]`): the wire codecs (terminal + video), FEC + frame
reassembly, the realtime controllers (congestion/ABR, FPS governor, LTR, decode
gate/sequencer, jitter pacer, delay-gradient trendline, recovery admission), coordinate
mapping, and the terminal/PTY protocol incl. the SSH-style channel mux + per-channel flow
control. It is exposed over a C-ABI — crate `rust/aislopdesk-ffi` (the only crate allowed
`unsafe`; hand-written header `aislopdesk_ffi.h`) — and linked into SwiftPM via the
`CAislopdeskFFI` C target. The **Swift/SwiftUI apps are the platform shell**: capture
(ScreenCaptureKit), HW codec (VideoToolbox), Metal render, input injection, PTY spawn, UI,
OS integration. The same core is the basis for a future Android client over C-ABI/JNI.

### Three data paths

```
┌─────────────────── HOST (macOS, non-sandboxed) ───────────────────┐
│ (1) Terminal   openpty + posix_spawn -> shell / claude (raw VT)   │
│ (2) GUI video  ScreenCaptureKit -> VideoToolbox HEVC              │
│ (3) Inspector  Claude Code JSONL transcript + hooks -> events     │
└──────┬──────────────────────┬─────────────────────┬───────────────┘
       │ (1) TCP              │ (2) UDP             │ (3) TCP #2
┌──────▼──────────────────────▼─────────────────────▼───────────────┐
│                   CLIENT (macOS / iOS / iPadOS)                   │
│ (1) libghostty surface (full TUI render) + keystrokes             │
│ (2) VTDecompression -> Metal (GUI window video)                   │
│ (3) SwiftUI read-only views (tool cards / subagents / todos)      │
└───────────────────────────────────────────────────────────────────┘
```

1. **Terminal path (primary).** Host opens a PTY and streams raw VT bytes over plain TCP
   (`TCP_NODELAY`) to the client, which renders them with libghostty. A dual data/control
   channel plus an Eternal-Terminal-style replay buffer give byte-exact lossless reconnect.
2. **GUI video path (secondary).** ScreenCaptureKit + VideoToolbox HEVC over UDP for the
   occasional GUI window (VS Code, Xcode), with FEC, adaptive bitrate/congestion control,
   and client-side cursor.
3. **Read-only inspector (differentiator).** Tails the Claude Code JSONL transcript + hooks
   to surface tool calls, subagents, and todos on a second channel. Read-only by
   construction — it observes the transcript and never drives the agent.

## Module map (SwiftPM)

| Target | Kind | Role |
|--------|------|------|
| `AislopdeskProtocol`     | lib  | Terminal wire format (framing, seq, hello/ack). Zero platform deps. |
| `AislopdeskTransport`    | lib  | TCP channels + replay buffer + reconnect handshake. |
| `AislopdeskHost`         | lib  | macOS host: PTY spawn/relay, session manager, Claude Code launch env. |
| `AislopdeskClient`       | lib  | Shared client: connection/reconnect, input, gap-free output stream. |
| `AislopdeskTerminal`     | lib  | `TerminalSurface` seam (libghostty-backed in the GUI apps). |
| `AislopdeskTTY`          | lib  | Local raw-mode termios + winsize for the CLI. |
| `AislopdeskInspector`    | lib  | JSONL transcript tailer + typed events + views (read-only inspector). |
| `AislopdeskClaudeCode`   | lib  | Claude Code integration: terminal-mode sniffer, input dedup/state. |
| `AislopdeskClientUI`     | lib  | SwiftUI client views/view-models + iOS native-feel input host. |
| `AislopdeskVideoProtocol`| lib  | Video wire format: packetizer, FEC, cursor/geometry/input codec. |
| `AislopdeskVideoHost`    | lib  | macOS capture + encode + input injection + UDP host session. |
| `AislopdeskVideoClient`  | lib  | macOS/iOS decode + Metal render + pacing + client session. |
| `aislopdesk-hostd`       | exec | Headless host daemon (terminal path). |
| `aislopdesk-client`      | exec | Interactive remote terminal client. |
| `aislopdesk-videohostd`  | exec | GUI-video host daemon (window capture; needs GUI session + TCC). |
| `aislopdesk-loopback-validate` | exec | Headless video-pipeline validator (real HW encode→decode, FEC, ABR). |
| `aislopdesk-corevectors` | exec | Emits the golden reference corpus the Rust core's parity test consumes. |
| `aislopdesk-framewatch`, `aislopdesk-capture-probe` | exec | Diagnostics: ScreenCaptureKit cadence, window-capture. |

The Rust core's codecs/FEC/controllers/terminal-protocol are reached through the
`CAislopdeskFFI` C target (links `libaislopdesk_ffi.a`).

**12 libraries + 8 executables + 10 test targets + 2 C shims** (the Rust-core FFI bridge
`CAislopdeskFFI` + a virtual-display shim `CAislopdeskVirtualDisplay`).

## Quickstart

The core libraries, CLIs, and tests are headless — no GUI, no libghostty, no signing. They
do link the Rust core staticlib through `CAislopdeskFFI`, so build it once first.

```sh
bash rust/build-apple.sh  # builds libaislopdesk_ffi.a (macOS arm64) for CAislopdeskFFI
swift build               # builds every target (12 libs + 8 executables)
swift test                # full suite (~2188 tests), headless
scripts/check-ios.sh      # iOS-simulator typecheck of the #if os(iOS) sources (needs Xcode)
```

### Host daemon

```sh
swift build -c release
.build/release/aislopdesk-hostd --port 7420            # plain login shell
.build/release/aislopdesk-hostd --port 7420 --claude   # launch Claude Code
```

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port to bind (omit → OS-chosen, logged to stderr). |
| `--shell`      | Login shell to spawn (default: the user's). |
| `--claude`     | Launch `claude` under the curated env instead of a plain shell. |
| `--xterm256`   | With `--claude`, advertise `TERM=xterm-256color` instead of `xterm-ghostty`. |

Sessions **survive client disconnects** — a returning client resumes byte-exact from the
replay buffer; long-offline sessions are reaped by an idle TTL. The host defaults to
`TERM=xterm-ghostty` but probes terminfo at spawn and auto-falls back to `xterm-256color`
when the ghostty entry is missing.

### Interactive client

```sh
.build/release/aislopdesk-client --host <host> --port 7420
```

In interactive mode every keystroke — including `Ctrl-C` — is forwarded raw to the remote
shell. The only local escape is **`Ctrl-]`** (clean disconnect). The local terminal is
always restored on exit, including on signals. For scripting, `--no-raw` pipe mode waits
for the remote session to exit:

```sh
printf 'echo hello\nexit\n' | .build/release/aislopdesk-client --host <host> --port 7420 --no-raw
```

## GUI apps (libghostty renderer + video path)

The libghostty renderer builds and renders on macOS **and** iOS (verified on the iOS 26.5
Simulator). It is gated behind `#if canImport(CGhostty)` and lives outside `Package.swift`,
so headless builds never see it; the xcframework is gitignored and must be built once:

```sh
# 1. Universal xcframework (macos-arm64 + ios-arm64 + ios-arm64-simulator)
XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh

# 2a. macOS app
bash scripts/enable-macos-renderer.sh
xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj -scheme ClientApp-macOS \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build

# 2b. iOS app (project.yml is committed renderer-enabled)
xcodegen generate --spec Apps/ClientApp-iOS/project.yml
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj -scheme ClientApp-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

**GUI video path:** run `.build/release/aislopdesk-videohostd --list` to enumerate windows,
then `--window-id <N>` (grant Screen Recording + Accessibility; run from a real GUI session,
not SSH). In the client app, open the **Remote window** sheet and enter the host, ports, and
window id.

Full recipe + caveats: [`ThirdParty/ghostty/build-libghostty.sh`](ThirdParty/ghostty/build-libghostty.sh)
header and [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Status

| Layer | State |
|-------|-------|
| Rust core + C-ABI (codecs, FEC, controllers, terminal protocol) | ✅ integrated into the apps; verified by cross-language golden parity + per-subsystem fuzz + HW loopback |
| Terminal path end to end (protocol, transport, host PTY, client, reconnect) | ✅ done, tested headlessly + on real hardware |
| Inspector (JSONL tailer, event model, second channel) | ✅ done, fixture-tested |
| Claude Code integration logic (env / sniffer / dedup) | ✅ done, byte-sequence tested |
| Client UI (SwiftUI + iOS native-feel input) | ✅ macOS-tested; iOS compiles, on-device interaction unverified |
| GUI video path (codec/FEC/ABR tested; capture→render pipeline) | ✅ running on real hardware (host daemon + client Remote-window panel) |
| libghostty renderer (macOS + iOS) | ✅ builds, links, renders (iOS Simulator verified) |

Per-layer detail, test counts, and the hardware-verification checklist:
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Documentation

- [`docs/README.md`](docs/README.md) — index of all design docs.
- [`docs/00-overview.md`](docs/00-overview.md) — architecture overview + every binding decision (read first).
- [`docs/19-implementation-plan.md`](docs/19-implementation-plan.md) — build log + phase status (source of truth).
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — the terminal-path wire protocol.
- [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md) — end-of-build status + how to verify on hardware.

## License

[MIT](LICENSE)
