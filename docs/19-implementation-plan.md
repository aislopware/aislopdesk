# 19 — Implementation plan & build log (autonomous build)

> **STATUS: CURRENT — orchestration anchor.** Spec/de-risk done ([18 §0]: Phase 0 PASS trên 2 máy thật). Đây là bản đồ **build → workflow** + trạng thái, cập nhật sau mỗi workflow. Triết lý: **codebase đẹp nhất, kiến trúc tốt nhất, không fallback** (libghostty-only, no SwiftTerm).

## Tên sản phẩm & module

Product/codename: **Rwork** (remote workspace — khớp repo `rworkspace`). Module prefix `Rwork`.

```
rworkspace/
├── Package.swift                 # SPM: libs + CLI execs + tests (HEADLESS-buildable & testable)
├── Sources/
│   ├── RworkProtocol/            # wire format: framing, MessageType, seq(int64), Hello/Ack — pure Swift, 0 platform dep
│   ├── RworkTransport/           # NWConnection + TCP_NODELAY, dual data/control channel,
│   │                             #   BackedWriter/BackedReader (ET replay 64MB/4MB gate), reconnect handshake
│   ├── RworkHost/                # macOS: PTY (openpty + posix_spawn createSession), session mgr,
│   │                             #   no-buffer PTY↔transport relay (QoS user-interactive), TIOCSWINSZ
│   ├── RworkClient/              # shared client: connection mgr, reconnect, input encoding
│   └── RworkTerminal/            # TerminalSurface protocol + HeadlessSurface (libghostty impl = GUI app target)
│   ├── rwork-hostd/              # exec: headless host daemon (PTY + transport)  ← buildable tonight
│   └── rwork-client/             # exec: headless CLI test client                ← buildable tonight
├── Tests/{RworkProtocol,RworkTransport,RworkHost,RworkClient}Tests/
├── Apps/                         # Xcode projects (GUI; depend on SPM + libghostty XCFramework) — scaffold
│   ├── HostApp-macOS/  ClientApp-macOS/  ClientApp-iOS/
├── ThirdParty/ghostty/           # build script + External.zig patch → libghostty.xcframework
└── docs/
```

**Why headless-first:** the whole PATH 1 byte pipeline (host PTY ↔ TCP/`TCP_NODELAY` ↔ client, with replay-buffer reconnect) is the de-risked core and is fully buildable + unit/integration-testable with **no GUI, no libghostty**. The renderer (libghostty surface in a Metal view) is intrinsically part of the GUI app target and sits behind `TerminalSurface`; its XCFramework build is the only fragile step (needs Zig) and must never block the core.

## Phase → workflow map

| WF | Layer | Deliverable | Verify | Status |
|----|-------|-------------|--------|--------|
| **WF-1** | Foundation | git init, Package.swift (all targets), `RworkProtocol` fully impl + tests, `docs/20-wire-protocol.md` | `swift build` + `swift test` green | ⏳ |
| **WF-2** | Transport | `RworkTransport`: `TCP_NODELAY` conn, dual data/control, BackedWriter/Reader replay, reconnect handshake | loopback unit tests (framing, replay-after-drop, reconnect resume) | ⛔ blocked by WF-1 |
| **WF-3** | Host PTY | `RworkHost`: openpty+posix_spawn, relay, resize, session mgr; `rwork-hostd` | spawn `cat`/`echo` in PTY, byte round-trip test | ⛔ WF-2 |
| **WF-4** | E2E byte pipeline | `RworkClient` + `rwork-client`; host↔client loopback over TCP | e2e: client sends `echo hi`, receives `hi`; kill+reconnect resumes | ⛔ WF-3 |
| **WF-5** | libghostty seam | `TerminalSurface`, `GhosttySurface` (GUI), Zig install + ghostty fork + External.zig patch + XCFramework script | `swift build` still green w/o framework; build script runs (best-effort) | ⛔ WF-1 (parallel w/ WF-2..4 ok) |
| **WF-6** | Inspector | `RworkInspector`: tail JSONL transcript + hooks, NWConnection #2, tool-card/subagent/todo model + SwiftUI views | unit tests on JSONL parse + event model | ⛔ WF-1 (independent of terminal) |
| **WF-7** | Claude Code integ | host env (TERM=xterm-ghostty, NO_FLICKER, setup-token reuse), input box A+B1 model | unit tests on env + dedup ring | ⛔ WF-3 |
| **WF-8** | iOS client | UIKit table-stakes (key-repeat/IME/floating-cursor/accessory), reuse Client+Terminal | builds for iOS target | ⛔ WF-4, WF-5 |
| **WF-9** | GUI video path | capture/encode/decode/render/cursor/input (Phase 4) | harness-validated pieces → integrated | ⛔ WF-4 |

Legend: ⏳ running · ✅ done · ⛔ blocked · 🔁 needs-fix

## Sequencing tonight
PATH 1 core is the priority: **WF-1 → WF-2 → WF-3 → WF-4** (sequential; each depends on prior). WF-5 (libghostty) and WF-6 (inspector) are independent of the byte pipeline and can run alongside. WF-7/8/9 follow. Each green layer → atomic git commit. No push (no remote). GUI apps need libghostty + signing → scaffold only.

## Toolchain notes
- Swift 6.3.2 · Xcode 26.5 · arm64 · macOS 26.5. git + gh present.
- `brew install zig pandoc` done → **zig 0.16.0** at `/opt/homebrew/bin/zig`, pandoc 3.9.0.2.
- ⚠️ **WF-5 must pin Zig precisely:** zig 0.16.0 is too new for the ghostty fork (Zig breaks between minors; `daiimus/ghostty:ios-external-backend` was cut from an older SHA needing ~0.13/0.14). WF-5: read the fork's `build.zig.zon` / `.zigversion` / `minimum_zig_version`, fetch that EXACT toolchain into a local dir (ziglang.org/download or mach nominated), and use it via a build-local PATH — do NOT rely on brew's 0.16.0.

## Build log
- (append one line per workflow completion: WF-id · result · commit · notes)
- **WF-1** · ✅ green · SPM foundation (5 libs + 2 execs + 4 test targets, swift-tools 6.0, macOS 14 / iOS 17), `RworkProtocol` fully implemented (framing + dual-channel `WireMessage` + streaming `FrameDecoder`, big-endian, Int64 seq), `docs/20-wire-protocol.md`. `swift build` + `swift test` green (28 tests, 0 failures), warning-free. Skeleton seams for Transport/Host/Client/Terminal + `HeadlessTerminalSurface` real impl. Renderer = libghostty-only behind `TerminalSurface`, no fallback.
