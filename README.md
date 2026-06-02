# Rwork

**Rwork** is a terminal-first, low-latency remote-coding tool for Apple platforms — a
macOS **host** paired with macOS / iOS **clients**. The everyday use case is running a
shell and **Claude Code** on a remote machine and driving it from another device with
native, feels-local responsiveness. Rwork is **native Swift end to end** and runs over a
[NetBird](https://netbird.io) (WireGuard) mesh, assuming direct peer-to-peer connectivity.
Because WireGuard already provides end-to-end encryption and NetBird ACLs gate membership,
Rwork adds **no app-layer encryption or auth** — the security boundary is the mesh. The
client terminal renderer is **libghostty exclusively** — there is **no SwiftTerm fallback**
and no second rendering path (a deliberate "build the best thing, keep no plan B" commitment).

## Architecture — three data paths

```
┌──────────── HOST (macOS, non-sandboxed) ────────────┐
│  ① TERMINAL PATH (primary)                          │
│     openpty + posix_spawn → shell / claude (PTY)    │
│        │ raw VT byte stream                         │
│  ③ INSPECTOR (read-only companion)                  │
│     tail JSONL transcript + hooks → typed events    │
│  ② GUI VIDEO PATH (Phase 4)                         │
│     ScreenCaptureKit → VideoToolbox HEVC 4:2:0      │
└──────│───────────────│──────────────────│───────────┘
       │ TCP           │ NWConnection #2   │ UDP   (all over NetBird WireGuard P2P)
┌──────▼───────────────▼──────────────────▼───────────┐
│  CLIENT (macOS / iOS / iPadOS)                       │
│  ① libghostty surface (full TUI render) + keys       │
│  ③ SwiftUI read-only views (tool cards / subagents / │
│     todos / CoT-placeholder)                         │
│  ② VTDecompression → Metal (GUI window video)        │
└──────────────────────────────────────────────────────┘
```

- **① Terminal path (primary).** Host opens a PTY (`openpty` + `posix_spawn` with
  `POSIX_SPAWN_SETSID`), streams raw VT bytes over **plain TCP** (with `TCP_NODELAY`) to the
  client, which renders them with **libghostty**. A dual data/control channel plus an
  Eternal-Terminal-style replay buffer give byte-exact lossless reconnect. This is the
  de-risked core and the everyday path.
- **③ Read-only inspector (differentiator).** A companion view that tails the Claude Code
  JSONL transcript + hooks to surface tool calls, subagents, and todos over a second
  NWConnection. Read-only by construction — it observes the transcript and never drives the
  agent, so it never pays the cost of doing so.
- **② GUI video path (Phase 4, secondary).** ScreenCaptureKit + VideoToolbox HEVC over UDP
  for the occasional GUI window (VS Code, Xcode). Built and reviewed, not part of the
  everyday terminal flow; see the status table.

## Module map (SwiftPM)

| Target | Kind | Role |
|--------|------|------|
| `RworkProtocol`     | lib  | Wire format: framing, `MessageType`, `Int64` seq, hello/ack. Pure Swift, **zero platform dep** (no `Network`/`Darwin`) → builds macOS + iOS. |
| `RworkTransport`    | lib  | `NWConnection` + `TCP_NODELAY`, dual data/control channels, ET-style `ReplayBuffer` (4 MiB offline gate / 64 MiB cap), reconnect handshake. |
| `RworkHost`         | lib  | macOS host: PTY (`openpty` + `posix_spawn` createSession), session manager, no-buffer PTY↔transport relay, `TIOCSWINSZ` resize, Claude Code launch env + stat-only auth resolve. |
| `RworkClient`       | lib  | Shared client: connection manager, reconnect (capped backoff), input encoding, gap-free/dup-free output stream, iOS pause/resume seam. |
| `RworkTerminal`     | lib  | `TerminalSurface` protocol + `HeadlessTerminalSurface`. The libghostty-backed `GhosttySurface` lives in the GUI app target and conforms to the same seam. |
| `RworkTTY`          | lib  | Local raw-mode termios save/restore + `TIOCGWINSZ`/`TIOCSWINSZ` for the interactive CLI (split out so it is unit-testable). |
| `RworkInspector`    | lib  | Read-only structured inspector: tolerant JSONL transcript tailer + hooks, typed `InspectorEvent` model (tool cards / subagent tree / todos / thinking-placeholder), second-channel transport + SwiftUI views. |
| `RworkClaudeCode`   | lib  | Cross-platform Claude Code integration logic: terminal-mode sniffer (DECSET/DECRST 1049 + OSC 133, split-robust), input dedup ring, input-box A/B1 state machine. |
| `RworkClientUI`     | lib  | Cross-platform SwiftUI client: views + `@Observable` view-models binding Client/Inspector/ClaudeCode/Terminal; iOS UIKit native-feel table-stakes (key-repeat, floating cursor, accessory bar, IME routing). |
| `RworkVideoProtocol`| lib  | PATH 2 pure wire format: UDP packetizer/reassembler + loss detect, FEC (XOR parity), cursor side-channel, window geometry, coordinate mapping, input-event codec. Zero platform dep → macOS + iOS. |
| `RworkVideoHost`    | lib  | PATH 2 macOS-only capture + encode + input injection (ScreenCaptureKit / VideoToolbox 2-session / CGEvent). Compiled + reviewed. |
| `RworkVideoClient`  | lib  | PATH 2 macOS + iOS decode + Metal render + client-side cursor (VTDecompression / Metal / CADisplayLink). Compiled + reviewed. |
| `rwork-hostd`       | exec | Headless host daemon (PTY + transport). |
| `rwork-client`      | exec | Interactive remote terminal client. |

12 libraries + 2 executables + 8 test targets = **22 SwiftPM targets**, ~17.6k Swift LOC.

## Quickstart

Everything below the GUI is **headless** — no GUI, no libghostty, no signing required for
the core libraries, CLIs, and tests. These commands are real and work today over TCP
(loopback or NetBird).

### Build & test

```sh
swift build          # builds every target incl. both executables
swift test           # 381 tests, 0 failures (~18s), warning-clean
```

### iOS typecheck

`swift build` on macOS compiles the **macOS slice only** — it never type-checks the
`#if os(iOS)` sources (the UIKit input host + the four native-feel table-stakes in
`Sources/RworkClientUI/iOS/`), so they can rot silently. Build them with an explicit
iOS-Simulator (unsigned) build:

```sh
scripts/check-ios.sh   # iOS-triple build of ClientApp-iOS (+ RworkClientUI); fails non-zero on error
```

This requires Xcode and runs `xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj
-scheme ClientApp-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
build`. Run it whenever you touch `#if os(iOS)` code.

### Run the host daemon (`rwork-hostd`)

```sh
swift build -c release
.build/release/rwork-hostd --port 7420            # or .build/debug/rwork-hostd after `swift build`
```

`rwork-hostd` binds `0.0.0.0` (the port you pass, or an OS-chosen one), spawns a login shell
per new session, logs to stderr, and runs until `SIGINT`. The session **survives a client
disconnect** — the daemon never kills the shell on channel failure; a returning client
resumes byte-exact from the replay buffer.

### Run the interactive client (`rwork-client`)

```sh
.build/release/rwork-client --host <host> --port 7420
```

| Flag | Meaning |
|------|---------|
| `--host`, `-h` | Host running `rwork-hostd`. |
| `--port`, `-p` | TCP port `rwork-hostd` listens on. |
| `--no-raw`     | Do not put the local terminal in raw mode (use for pipes / scripting). |

In interactive mode (stdin is a TTY, `--no-raw` not set) the local terminal is put into raw
mode and every keystroke — **including `Ctrl-C`** — is forwarded as a raw byte to the remote
shell (the remote line discipline raises `SIGINT` there, not locally). Because `Ctrl-C` is
passed through, the only **local** escape is:

> **`Ctrl-]`** — cleanly disconnect, restore the terminal, exit `0`.

The terminal is always restored on exit (normal exit, `Ctrl-]`, and
`SIGINT`/`SIGTERM`/`SIGQUIT`/`SIGHUP`), so a wedged session never leaves it in raw mode.

### Non-interactive / pipe form

```sh
printf 'echo hello\nexit\n' | .build/release/rwork-client --host <host> --port 7420 --no-raw
```

`--no-raw` pipe mode waits for the remote session to exit before returning, so a piped
script is never truncated.

## libghostty renderer status

The libghostty integration is **ready** — the `GhosttySurface` Swift binding (conforming to
`RworkTerminal.TerminalSurface`), the SwiftUI host **`GhosttyTerminalView`** (the Metal-backed
`NSViewRepresentable`/`UIViewRepresentable` that owns the surface, both in
`ThirdParty/ghostty/integration/GhosttySurface/`), the `TerminalRendererFactory.shared`
registration in `Apps/Shared/AppMain.swift` (gated `#if canImport(CGhostty)`), the C module map
/ vendored header, and an idempotent build script (`ThirdParty/ghostty/build-libghostty.sh`) are
all committed. The renderer code is **gated `#if canImport(CGhostty)`** so it is inert (compiles
to nothing) in every build on this host — it is verified by **review** against the binding, not
by compilation. What is **not done** is the xcframework compile, which is blocked **on this
macOS-26.5 host** by a Zig ↔ SDK pincer:

- pinned **Zig 0.15.2** (the fork's required version) **cannot link the macOS 26.5 SDK**
  (undefined `__availability_version_check` / `_abort` / `_bzero` — 0.15.2 predates the
  26.x libSystem layout);
- **Zig 0.16.0** (the only Zig that links the 26.5 SDK here) is **rejected by the fork's
  `build.zig`** (hard version gate + a removed `std.process.EnvMap`).

To finish, run `ThirdParty/ghostty/build-libghostty.sh` on a host with a **≤ 15.x SDK**
(Xcode 16 Command Line Tools, or a CI runner), **or** bump the fork pin to a SHA whose
`build.zig` accepts a macOS-26-capable Zig (then re-verify the external-IO symbols). Until
then the GUI client shows a clearly-labelled **build-status placeholder** — it is **not** a
substitute VT renderer (libghostty-only policy). Full story:
[`ThirdParty/ghostty/README.md`](ThirdParty/ghostty/README.md).

Once the xcframework exists, the **exact** files to add to each `Apps/*/project.yml`
(the xcframework, the `CGhostty` module map, `GhosttySurface.swift` + `GhosttyTerminalView.swift`),
the `xcodegen generate` step, and how `#if canImport(CGhostty)` flips true are documented in
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md) → **"Activating the libghostty renderer"**.

## Status

| Layer | State |
|-------|-------|
| `RworkProtocol` / `RworkTransport` (incl. byte-exact reconnect) | ✅ done, unit + integration tested headlessly |
| `RworkHost` PTY + session survival | ✅ done, tested headlessly |
| `RworkClient` + interactive `rwork-client` (full PATH 1 e2e) | ✅ done, real loopback + subprocess e2e |
| `RworkInspector` (JSONL tailer + event model + 2nd channel) | ✅ done, fixture-tested |
| `RworkClaudeCode` integration logic (env / sniffer / dedup) | ✅ done, byte-sequence tested |
| `RworkClientUI` (SwiftUI + iOS table-stakes logic) | ✅ macOS-tested; iOS UIKit glue ⚠️ needs a device |
| `RworkVideoProtocol` (PATH 2 pure codec/FEC/mapping) | ✅ done, unit tested |
| `RworkVideoHost` / `RworkVideoClient` (capture/encode/decode/render) | ⚠️ compiled + reviewed; **not run** (SCKit/VideoToolbox hang without a window-server + TCC session) |
| `GhosttySurface` / libghostty renderer | ⛔ blocked on the xcframework build (see above) |

For the full per-layer status with test counts, commit hashes, the verify-on-hardware
checklist, and known caveats, see [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Documentation

- [`docs/00-overview.md`](docs/00-overview.md) — architecture overview + every binding decision (read first).
- [`docs/19-implementation-plan.md`](docs/19-implementation-plan.md) — the full build log + phase→workflow table + status (source of truth).
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — the PATH 1 terminal wire protocol.
- [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md) — honest end-of-autonomous-build status + how to verify on hardware.

## License

[MIT](LICENSE)
