// swift-tools-version:6.0
import PackageDescription

// Rwork — terminal-first remote-coding for Apple platforms.
//
// Headless-first layout (see docs/19-implementation-plan.md): the PATH 1 byte
// pipeline (host PTY <-> TCP/TCP_NODELAY <-> client, with replay-buffer reconnect)
// is the de-risked core and builds + tests with NO GUI and NO libghostty.
//
// Swift 6 tools default to the Swift 6 language mode (strict concurrency).
let package = Package(
    name: "Rwork",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RworkProtocol", targets: ["RworkProtocol"]),
        .library(name: "RworkTransport", targets: ["RworkTransport"]),
        .library(name: "RworkHost", targets: ["RworkHost"]),
        .library(name: "RworkClient", targets: ["RworkClient"]),
        .library(name: "RworkTerminal", targets: ["RworkTerminal"]),
        .library(name: "RworkTTY", targets: ["RworkTTY"]),
        .library(name: "RworkInspector", targets: ["RworkInspector"]),
        .library(name: "RworkClaudeCode", targets: ["RworkClaudeCode"]),
    ],
    targets: [
        // MARK: Libraries

        // Pure-Swift wire format: framing, MessageType, seq(Int64), Hello/Ack.
        // ZERO platform dependency (no Network/Darwin) so it builds for macOS + iOS
        // and is unit-testable in isolation.
        .target(name: "RworkProtocol"),

        // NWConnection + TCP_NODELAY, dual data/control channel, ET-style replay
        // buffer, reconnect handshake. (Implemented in WF-2.)
        .target(name: "RworkTransport", dependencies: ["RworkProtocol"]),

        // macOS host: PTY (openpty + posix_spawn createSession), session mgr,
        // no-buffer PTY<->transport relay, TIOCSWINSZ resize. (Implemented in WF-3.)
        .target(name: "RworkHost", dependencies: ["RworkTransport", "RworkProtocol"]),

        // Shared client: connection mgr, reconnect, input encoding. (WF-4.)
        .target(name: "RworkClient", dependencies: ["RworkTransport", "RworkProtocol"]),

        // TerminalSurface protocol + HeadlessTerminalSurface. The libghostty-backed
        // GhosttySurface lives in the GUI app target (WF-5) and conforms to the same
        // protocol.
        .target(name: "RworkTerminal", dependencies: ["RworkProtocol"]),

        // Local-terminal raw-mode + termios save/restore + TIOCGWINSZ/TIOCSWINSZ helpers
        // for the interactive CLI. Split into a library so the save/restore + SIGWINCH
        // mapping logic is unit-testable (the executable target itself is not importable).
        .target(name: "RworkTTY"),

        // Read-only structured inspector (WF-6). Tails Claude Code's JSONL transcript
        // (+ subagent files + hooks) on the host, models typed `InspectorEvent`s, and
        // streams them over a SECOND length-prefixed channel (NWConnection #2) to a
        // SwiftUI read-only client. INDEPENDENT of the terminal byte pipeline — it
        // reuses only RworkProtocol's framing *style*, never the terminal WireMessage.
        // Read-only: it observes the transcript, it never drives the agent.
        .target(name: "RworkInspector", dependencies: ["RworkProtocol"]),

        // Cross-platform Claude Code integration LOGIC (WF-7): the terminal-mode sniffer
        // (DECSET/DECRST 1049 + OSC 133, robust to sequences split across chunk
        // boundaries), the input dedup ring (input-box B1 echo suppression), and the
        // input-box state machine (A shell / B1 TUI-compose). Pure Swift, no platform
        // dependency beyond Foundation — builds for macOS + iOS, fixture-tested. The host
        // launch env + auth resolution live in RworkHost (macOS, the WF-7 seam).
        .target(name: "RworkClaudeCode", dependencies: ["RworkProtocol"]),

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/rwork-hostd.
        .executableTarget(name: "rwork-hostd", dependencies: ["RworkHost"]),

        // Interactive remote terminal client. Sources under Sources/rwork-client.
        .executableTarget(name: "rwork-client", dependencies: ["RworkClient", "RworkTerminal", "RworkTTY"]),

        // MARK: Tests
        .testTarget(name: "RworkProtocolTests", dependencies: ["RworkProtocol"]),
        .testTarget(name: "RworkTransportTests", dependencies: ["RworkTransport"]),
        .testTarget(name: "RworkHostTests", dependencies: ["RworkHost"]),
        // RworkClientTests exercises the REAL PATH 1 e2e: a HostServer (RworkHost) +
        // RworkClient over loopback, so it depends on RworkHost + RworkTTY too.
        .testTarget(name: "RworkClientTests", dependencies: ["RworkClient", "RworkHost", "RworkTransport", "RworkTerminal", "RworkTTY"]),
        // Fixture-based tests for the inspector: JSONL parsing, tool-card pairing,
        // subagent tree, the append-follow tailer, transport round-trip, hook ingest.
        // The `Fixtures/` tree is read off disk via `#filePath` (see Fixtures.swift),
        // so it is excluded from the build rather than bundled as a resource.
        .testTarget(
            name: "RworkInspectorTests",
            dependencies: ["RworkInspector", "RworkProtocol"],
            exclude: ["Fixtures"]
        ),
        // WF-7 logic: env/auth (RworkHost) + mode sniffer / dedup ring / input-box model
        // (RworkClaudeCode). Byte-sequence + fixture based; the sniffer tests feed the
        // SAME stream at adversarial split boundaries and assert identical results.
        .testTarget(
            name: "RworkClaudeCodeTests",
            dependencies: ["RworkClaudeCode", "RworkHost", "RworkProtocol"]
        ),
    ]
)
