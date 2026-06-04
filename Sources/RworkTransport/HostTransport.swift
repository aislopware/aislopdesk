import Foundation
import Network
import RworkProtocol

/// Host side of the Rwork transport: an `NWListener` that accepts the shared-mux (CONTROL + DATA)
/// TCP socket pairs, pairs the two physical connections by their preamble `connectionID` into one
/// ``MuxNWConnection``, and surfaces them on ``muxConnections_`` for the mux relay owner.
///
/// ## Handshake (shared-mux pairing)
/// 1. A new connection arrives; the listener reads the 1-byte association preamble.
/// 2. **MUX CONTROL** (`0x03`) / **MUX DATA** (`0x04`): each carries a 16-byte `connectionID`. The
///    first socket to arrive parks in `pendingMux`; the second with the same id completes the pair.
///    Once both are present they are wrapped into one ``MuxNWConnection`` (role `.host`), the
///    receive loops are started, and it is yielded on ``muxConnections_``.
///
/// Each pane on a shared connection is a logical channel (SSH-style), opened via `channelOpen`; the
/// per-channel PTY relay (``RworkHost/MuxChannelSession``) is owned by the relay owner, not here.
///
/// All mutable state (the pending half-pair map) lives inside this `actor`. No `@unchecked Sendable`.
public actor HostTransport {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rwork.host.listener")

    /// Bounded wait for the whole accept→handshake sequence on a single connection,
    /// symmetric with the client's `handshakeTimeout`. Without it, a connection that
    /// stalls mid-handshake (never sends its preamble) parks a detached `handshake()`
    /// Task and its `NWConnection` forever.
    let handshakeTimeout: Duration

    /// How long a half-paired mux link (one of the CONTROL/DATA pair arrived, the other never did)
    /// may linger before the reaper closes it and drops the pending entry. Guards the
    /// iOS-background / NetBird-flap case where the partner socket never arrives. Injectable (tiny
    /// values) so tests drive it without wall-clock sleeps; default 15s.
    let pendingDataTimeout: Duration

    /// Clock used for pending-entry expiry. Injectable so a test can stamp + drive the
    /// reaper deterministically; production uses the real ``ContinuousClock``.
    private let clock: ContinuousClock

    // Accepted SHARED mux connections (CONTROL+DATA paired) published here for the mux relay owner.
    private let muxConnectionStream: AsyncStream<MuxNWConnection>
    private let muxConnectionContinuation: AsyncStream<MuxNWConnection>.Continuation

    /// Half-paired mux connections: a mux CONTROL (or DATA) socket arrived and is awaiting its
    /// partner with the same connectionID. Keyed by the preamble connectionID.
    private struct PendingMuxLink {
        let control: (any MuxByteLink)?
        let data: (any MuxByteLink)?
        /// When the FIRST of the pair arrived — the reaper expires a half-pair past
        /// ``pendingDataTimeout`` so a partner that never shows (crash / NAT drop / hostile
        /// CONTROL-only flood) cannot leak NWConnections unbounded.
        let createdAt: ContinuousClock.Instant
    }
    private var pendingMux: [UUID: PendingMuxLink] = [:]

    /// Background task that periodically expires stale pending half-pairs (started by
    /// ``start(port:)``, cancelled by ``stop()``). The deterministic test path calls
    /// ``reapExpiredPending(now:)`` directly instead of relying on this timer.
    private var reaperTask: Task<Void, Never>?

    /// - Parameters:
    ///   - handshakeTimeout: bound on the per-connection accept→handshake sequence
    ///     (default 10s, matching the client).
    ///   - pendingDataTimeout: bound on a half-paired mux link waiting for its partner (default 15s).
    public init(
        handshakeTimeout: Duration = .seconds(10),
        pendingDataTimeout: Duration = .seconds(15)
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.pendingDataTimeout = pendingDataTimeout
        self.clock = ContinuousClock()
        var muxC: AsyncStream<MuxNWConnection>.Continuation!
        self.muxConnectionStream = AsyncStream { muxC = $0 }
        self.muxConnectionContinuation = muxC
    }

    /// Newly-accepted SHARED mux connections (CONTROL+DATA paired into one ``MuxNWConnection``,
    /// role `.host`, receive loops started). The mux relay owner (the host daemon) consumes these,
    /// installs a per-channel-open handler, and spawns a PTY per channel.
    public nonisolated var muxConnections_: AsyncStream<MuxNWConnection> { muxConnectionStream }

    /// The port the listener actually bound to. `nil` until ``start(port:)`` resolves.
    public private(set) var boundPort: UInt16?

    /// Starts listening on `port` (use `0` for an OS-assigned ephemeral port; read the
    /// result from ``boundPort``). Suspends until the listener is `.ready`.
    public func start(port: UInt16) async throws {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: TransportParameters.makeTCP(), on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptConnection(connection) }
        }

        // Resolve the OS-assigned port through the continuation so it is set on the
        // actor synchronously *before* start() returns — no separate Task race.
        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let portValue = listener.port?.rawValue ?? port
                    box.tryResume { continuation.resume(returning: portValue) }
                case let .failed(error):
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.listenerFailed(String(describing: error)))
                    }
                case .cancelled:
                    // A cancel during startup (e.g. stop() raced start()) is terminal —
                    // resume the continuation so start() does not hang on a dead listener.
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.listenerFailed("cancelled during start"))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        boundPort = resolvedPort

        // Start the background reaper that periodically expires stale half-paired mux links. It
        // ticks at a fraction of the timeout so an abandoned pending entry never lingers much past
        // the bound. Tests inject a tiny `pendingDataTimeout` and/or drive `reapExpiredPending(now:)`
        // directly, so they never wait on this wall-clock timer.
        startReaper()
    }

    /// Stops the listener and the reaper. Existing connections keep their channels until closed.
    public func stop() {
        reaperTask?.cancel()
        reaperTask = nil
        listener?.cancel()
        listener = nil
        muxConnectionContinuation.finish()
    }

    /// Launches the periodic reaper loop. Idempotent (a prior task is cancelled first).
    private func startReaper() {
        reaperTask?.cancel()
        // Tick at a quarter of the timeout (clamped to a small floor) so expiry latency
        // is bounded without busy-spinning.
        let tick = max(pendingDataTimeout / 4, .milliseconds(50))
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tick)
                } catch {
                    return // cancelled
                }
                guard let self else { return }
                await self.reapExpiredPending(now: self.clockNow())
            }
        }
    }

    /// The current monotonic instant from the (production) clock. Isolated read so the
    /// reaper task can stamp `now` for ``reapExpiredPending(now:)``.
    private func clockNow() -> ContinuousClock.Instant { clock.now }

    // MARK: Half-paired mux reaper

    /// Expires every half-paired mux link whose partner has not arrived within ``pendingDataTimeout``
    /// as measured from its `createdAt`, closing whichever side is parked so the leaked NWConnection
    /// is released. A hostile peer could open many CONTROL-only mux sockets with distinct
    /// connectionIDs as a DoS; this bounds the leak.
    ///
    /// Driven by the background reaper task in production; called directly by tests with
    /// a synthesized `now` so the behaviour is verified WITHOUT any wall-clock sleep.
    /// `internal` (not `public`) — it is a test/seam hook, not part of the daemon API.
    func reapExpiredPending(now: ContinuousClock.Instant) {
        for (id, entry) in pendingMux.filter({ now - $0.value.createdAt > pendingDataTimeout }) {
            pendingMux[id] = nil
            if let control = entry.control { Task { await control.close() } }
            if let data = entry.data { Task { await data.close() } }
        }
    }

    /// Test seam: the number of half-paired mux links currently awaiting their partner.
    func pendingCount() -> Int { pendingMux.count }

    /// Test seam: whether a specific connectionID is still half-paired (partner not yet arrived).
    func isPending(_ id: UUID) -> Bool { pendingMux[id] != nil }

    /// Test seam: a monotonic instant guaranteed to be past every current pending entry's expiry
    /// deadline. A test passes this to ``reapExpiredPending(now:)`` to force expiry deterministically.
    func instantPastAllPendingDeadlines() -> ContinuousClock.Instant {
        clock.now.advanced(by: pendingDataTimeout + pendingDataTimeout)
    }

    /// Test seam: the current monotonic instant from the actor's clock — at-or-after every current
    /// pending entry's `createdAt`. A test passes this to assert a young entry is NOT reaped early.
    func instantNowForTest() -> ContinuousClock.Instant { clock.now }

    // MARK: Accept + handshake

    private func acceptConnection(_ connection: NWConnection) {
        // Each new connection is handshaked independently; failures are isolated. The
        // whole sequence is bounded by `handshakeTimeout` (symmetric with the client):
        // a connection that opens but stalls before/within the handshake (never sends a
        // preamble) must not park this Task + its NWConnection forever. We race the
        // handshake against a single sleep; whichever finishes first wins, and on a
        // timeout (or any error) we cancel the connection so nothing leaks.
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.handshake(connection)
                    }
                    group.addTask {
                        try await Task.sleep(for: self.handshakeTimeout)
                        throw RworkTransportError.timedOut("host handshake")
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private func handshake(_ connection: NWConnection) async throws {
        let connQueue = DispatchQueue(label: "rwork.host.conn")
        try await connection.startAndWaitReady(on: connQueue)

        // Read the 1-byte discriminator.
        let tagByte = try await connection.receiveExactly(1)
        let tag = tagByte.first

        switch tag {
        case ChannelAssociation.muxControlTag:
            // Shared-mux CONTROL socket: read the pairing connectionID, then pair with its DATA peer.
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw RworkTransportError.handshakeFailed("mux control preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: true)
        case ChannelAssociation.muxDataTag:
            let idBytes = try await connection.receiveExactly(ChannelAssociation.sessionIDByteCount)
            guard let connectionID = UUID(dataBytesForAssociation: idBytes) else {
                throw RworkTransportError.handshakeFailed("mux data preamble: bad connectionID")
            }
            associateMux(connection, connectionID: connectionID, isControl: false)
        default:
            throw RworkTransportError.handshakeFailed("unknown association tag \(String(describing: tag))")
        }
    }

    /// Pairs the two physical mux sockets (CONTROL + DATA) that share `connectionID` into ONE
    /// shared ``MuxNWConnection`` (role `.host`), starts its receive loops, and yields it on
    /// ``muxConnections_`` for the mux relay owner. The first socket to arrive parks in `pendingMux`;
    /// the second completes the pair.
    private func associateMux(_ connection: NWConnection, connectionID: UUID, isControl: Bool) {
        let link = NWMuxByteLink(connection: connection, label: isControl ? "host.control" : "host.data")
        let existing = pendingMux[connectionID]
        let control = isControl ? link : existing?.control
        let data = isControl ? existing?.data : link
        if let control, let data {
            pendingMux[connectionID] = nil
            // Carry the wire `connectionID` onto the shared connection so the mux relay owner can
            // namespace its per-channel sessions by (connectionID, channelID) — see
            // `HostServer.muxSessions` / `MuxSessionKey`. Two distinct clients each allocate
            // channelID 1 for their first pane, so a channelID-only key cross-resolved sessions.
            let mux = MuxNWConnection(
                role: .host,
                controlLink: control,
                dataLink: data,
                connectionID: connectionID
            )
            Task {
                await mux.start()
                muxConnectionContinuation.yield(mux)
            }
        } else {
            pendingMux[connectionID] = PendingMuxLink(control: control, data: data, createdAt: clock.now)
        }
    }
}

/// A tiny thread-safe latch so a listener/connection state handler resumes a
/// continuation exactly once.
final class ReadyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

extension UUID {
    /// Builds a UUID from exactly 16 raw association bytes (canonical order).
    init?(dataBytesForAssociation data: Data) {
        guard data.count == 16 else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dest in
            _ = data.copyBytes(to: dest)
        }
        self.init(uuid: raw)
    }
}
