import Foundation
import RworkClient
import RworkTerminal

/// The terminal screen's view-model: it consumes a ``RworkClient``'s `output` byte stream +
/// `events` and projects connection / title / exit / byte-count state for the SwiftUI views.
///
/// It is the bridge between the actor world (`RworkClient`) and the UI: a `.task` calls
/// ``observe(client:)`` which drains both streams and folds them into `@Observable`
/// properties SwiftUI tracks. The terminal **pixels** are produced by the
/// ``RworkTerminal/TerminalSurface`` the view-model feeds (the libghostty `GhosttySurface` in
/// the app target, or `nil` in the headless/placeholder case) — the view-model never parses
/// VT itself (libghostty-only).
///
/// `@MainActor` so it is safe to mutate from SwiftUI and to drive a `@MainActor`
/// `GhosttySurface`; `@Observable` so the views update automatically.
@MainActor
@Observable
public final class TerminalViewModel {
    /// High-level connection lifecycle the UI surfaces (terminal screen + status chrome).
    public enum ConnectionStatus: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case disconnected(reason: String)
        case exited(code: Int32)

        public var label: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .reconnecting: return "reconnecting"
            case .disconnected: return "disconnected"
            case .exited(let code): return "exited(\(code))"
            }
        }

        /// True while we believe the byte pipeline is live.
        public var isLive: Bool { self == .connected }
    }

    // MARK: Observable state

    /// The connection lifecycle (drives the status chrome + placeholder telemetry).
    public private(set) var connectionStatus: ConnectionStatus = .idle
    /// The window/terminal title (OSC 0/2), if the host sent one.
    public private(set) var title: String?
    /// Authoritative session id, learned on first connect / preserved across reconnects.
    public private(set) var sessionID: UUID?
    /// Total bytes of `output` delivered (build-status telemetry; not a render).
    public private(set) var bytesReceived: Int = 0
    /// Most recent resume point surfaced by a `.reconnected` event (diagnostics).
    public private(set) var lastResumeSeq: Int64 = 0
    /// Set when the remote rang the bell since the last clear (the view can flash).
    public private(set) var bellPending: Bool = false

    // MARK: Wiring

    /// The terminal renderer the model feeds inbound bytes to. `nil` in the headless /
    /// placeholder case; the app target sets it to a libghostty ``GhosttySurface``.
    public weak var surface: (any TerminalSurface)?

    /// OUT path sink: the encoded keystroke/escape bytes libghostty emits from the
    /// renderer's `key`/`text` events (`GhosttySurface.onWrite`). The ``ConnectionViewModel``
    /// sets this on connect to forward to the live ``RworkClient/sendInput(_:)`` and clears
    /// it on teardown; while `nil` (disconnected) keystrokes are dropped — there is no host
    /// to receive them. The renderer routes `onWrite` here via ``sendInput(_:)``, so the
    /// view-attach timing and the connect timing are decoupled (whichever happens first, the
    /// closure reads the latest sink at call time). `@ObservationIgnored`: wiring, not view
    /// state — mutating it must not invalidate the SwiftUI views.
    @ObservationIgnored public var inputSink: ((Data) -> Void)?

    /// OUT path sink for grid resizes (cols/rows) the renderer derives from layout
    /// (`GhosttySurface.onResize`). Same lifecycle as ``inputSink``: set on connect to
    /// forward to ``RworkClient/sendResize(cols:rows:pxWidth:pxHeight:)`` (→ host
    /// `TIOCSWINSZ`), cleared on teardown.
    @ObservationIgnored public var resizeSink: ((UInt16, UInt16) -> Void)?

    /// Last grid size forwarded, so a duplicate resize (libghostty emits `onResize` both from
    /// `setSize` directly AND from its own `resize_callback` for the same layout pass) is
    /// coalesced and not sent twice.
    @ObservationIgnored private var lastSentSize: (cols: UInt16, rows: UInt16)?

    public init(surface: (any TerminalSurface)? = nil) {
        self.surface = surface
    }

    // MARK: OUT path (renderer → host)

    /// Routes terminal OUT bytes (keystrokes libghostty encoded) to the live client.
    /// A no-op while disconnected (``inputSink`` is `nil`). Called on the main actor by
    /// the renderer's `GhosttySurface.onWrite` bridge.
    public func sendInput(_ data: Data) {
        inputSink?(data)
    }

    /// Mirrors a grid resize to the host (`TIOCSWINSZ`). A no-op while disconnected.
    /// Called on the main actor by the renderer's `GhosttySurface.onResize` bridge.
    /// Coalesces consecutive duplicates (same cols/rows) so libghostty's double-emit per
    /// layout pass forwards at most one resize.
    public func sendResize(cols: UInt16, rows: UInt16) {
        if let last = lastSentSize, last.cols == cols, last.rows == rows { return }
        lastSentSize = (cols, rows)
        resizeSink?(cols, rows)
    }

    // MARK: Stream observation

    /// Drains the client's `output` byte stream ONLY, folding each chunk into observable
    /// state. Call from a SwiftUI `.task { await model.observe(client: client) }`; it returns
    /// when the output stream finishes (client closed / child exited).
    ///
    /// ### Single events consumer (the race this avoids)
    /// The view-model does **not** open its own `for await client.events` loop. Events are
    /// owned by the ``ConnectionViewModel`` (the single UI-layer events consumer), which folds
    /// the connect/drop signal into the chrome status AND forwards each event here via
    /// ``handle(_:)``. Two independent loops over the *same* event source would split the
    /// stream nondeterministically (output is safe because the model is its sole consumer).
    public func observe(client: RworkClient) async {
        connectionStatus = .connecting
        await pumpOutput(client.output)
    }

    private func pumpOutput(_ output: AsyncStream<Data>) async {
        for await chunk in output {
            ingestOutput(chunk)
        }
    }

    /// Folds one `output` chunk: feed the renderer + bump telemetry. The first byte flips
    /// `.connecting`/`.reconnecting` → `.connected` (we are receiving from the host).
    public func ingestOutput(_ chunk: Data) {
        if connectionStatus == .connecting || connectionStatus == .reconnecting {
            connectionStatus = .connected
        }
        bytesReceived += chunk.count
        surface?.feed(chunk)
    }

    /// Folds one `RworkClient.Event` into observable state.
    public func handle(_ event: RworkClient.Event) {
        switch event {
        case let .title(text):
            title = text
        case .bell:
            bellPending = true
        case let .exit(code):
            connectionStatus = .exited(code: code)
        case let .disconnected(reason):
            // A drop while we still want to be connected reads as "reconnecting" (the
            // ReconnectManager is retrying); the ConnectionViewModel owns the authoritative
            // "user asked to disconnect" distinction.
            connectionStatus = .disconnected(reason: reason)
        case let .reconnected(sessionID, resumeFromSeq):
            self.sessionID = sessionID
            self.lastResumeSeq = resumeFromSeq
            connectionStatus = .connected
        }
    }

    /// Marks that the reconnect campaign has begun (the chrome shows "reconnecting" rather
    /// than a bare "disconnected"). Called by the ConnectionViewModel on a non-deliberate drop.
    public func markReconnecting() {
        connectionStatus = .reconnecting
    }

    /// Clears the pending-bell flag once the view has flashed.
    public func clearBell() {
        bellPending = false
    }

    /// Resets to idle (a fresh connect target). Keeps no stale title / byte count.
    public func reset() {
        connectionStatus = .idle
        title = nil
        bytesReceived = 0
        bellPending = false
        lastResumeSeq = 0
        lastSentSize = nil   // a fresh session must re-assert its grid size
    }
}
