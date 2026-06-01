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

        // MARK: Executables

        // Headless host daemon (PTY + transport). Sources under Sources/rwork-hostd.
        .executableTarget(name: "rwork-hostd", dependencies: ["RworkHost"]),

        // Headless CLI test client. Sources under Sources/rwork-client.
        .executableTarget(name: "rwork-client", dependencies: ["RworkClient", "RworkTerminal"]),

        // MARK: Tests
        .testTarget(name: "RworkProtocolTests", dependencies: ["RworkProtocol"]),
        .testTarget(name: "RworkTransportTests", dependencies: ["RworkTransport"]),
        .testTarget(name: "RworkHostTests", dependencies: ["RworkHost"]),
        .testTarget(name: "RworkClientTests", dependencies: ["RworkClient"]),
    ]
)
