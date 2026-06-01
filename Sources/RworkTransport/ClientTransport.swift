import Foundation
import Network
import RworkProtocol

/// Client side of the Rwork transport: opens the CONTROL + DATA TCP connections,
/// performs the `hello`/`helloAck` handshake, associates the two physical
/// connections to one logical session, and exposes thin inbound/outbound APIs.
///
/// It is intentionally **thin**: WF-4 (`RworkClient`) wires keystrokes to
/// ``sendInput(_:)`` and renders the ``inbound`` stream; no terminal/PTY logic lives
/// here. Reconnect *policy* (backoff, lifecycle) belongs to WF-4 — this type provides
/// the resume-correct handshake hook (``connect(host:port:resume:lastReceivedSeq:)``)
/// so a reconnect is just another `connect` carrying the prior `sessionID` +
/// `lastReceivedSeq`.
///
/// All mutable state lives inside this `actor`. No `@unchecked Sendable`.
public actor ClientTransport {
    /// Inbound host→client events the client cares about: `output`/`exit`/`title`/`bell`.
    /// (`output` carries the seq the client must track for ack + reconnect.) The
    /// `helloAck` handshake reply is consumed internally and is **not** yielded here.
    public typealias Inbound = AsyncThrowingStream<WireMessage, Error>

    /// The authoritative session id learned from `helloAck`. `nil` until connected.
    public private(set) var sessionID: UUID?
    /// The seq the host replayed from in the most recent `helloAck`.
    public private(set) var resumeFromSeq: Int64 = 0
    /// Whether the host treated the most recent connect as a returning client.
    public private(set) var returningClient = false

    private var connection: RworkConnection?
    private var dataChannel: NWMessageChannel?
    private var controlChannel: NWMessageChannel?

    private let inboundStream: Inbound
    private let inboundContinuation: Inbound.Continuation

    /// Forwarding tasks that pump each channel's inbound stream into the merged
    /// ``inbound``. Held so they can be cancelled on ``close()``.
    private var forwarders: [Task<Void, Never>] = []

    /// One-shot waiter for the `helloAck`, resumed by the control forwarder when the
    /// reply arrives. Cleared once resumed.
    private var helloAckWaiter: CheckedContinuation<WireMessage, Error>?
    /// Set true once the helloAck has been delivered to the waiter (so later control
    /// messages are forwarded, not intercepted).
    private var helloAckDelivered = false

    public init() {
        var continuation: Inbound.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    /// Merged inbound stream of host→client messages (data: `output`/`exit`;
    /// control: `title`/`bell`). The caller tracks `output.seq` and acks.
    public nonisolated var inbound: Inbound { inboundStream }

    // MARK: Connect / handshake

    /// Connects to `host:port` and performs the full handshake.
    ///
    /// - Parameters:
    ///   - resume: an existing session id to resume, or ``WireMessage/newSessionID``
    ///     for a fresh session.
    ///   - lastReceivedSeq: the highest contiguous output seq already received (0 for a
    ///     new session). The host replays `output` with `seq > lastReceivedSeq`.
    ///   - handshakeTimeout: bounded wait for readiness + `helloAck`.
    ///
    /// On success the merged ``inbound`` stream begins yielding; resumed-tail `output`
    /// arrives first (the host replays before resuming live streaming).
    public func connect(
        host: String,
        port: UInt16,
        resume: UUID = WireMessage.newSessionID,
        lastReceivedSeq: Int64 = 0,
        handshakeTimeout: Duration = .seconds(10)
    ) async throws {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let endpointHost = NWEndpoint.Host(host)

        // 1. CONTROL connection: open, send control preamble.
        let controlConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await controlConn.startAndWaitReady(on: DispatchQueue(label: "rwork.client.control"))
        try await controlConn.sendRaw(ChannelAssociation.controlPreamble())

        let control = NWMessageChannel(connection: controlConn, channel: .control)
        await control.start()

        // 2. Arm the SINGLE control forwarder BEFORE sending hello so we cannot miss the
        //    reply. It intercepts the first `helloAck` (resumes `helloAckWaiter`) and
        //    forwards every other control message into the merged inbound. The control
        //    inbound stream is therefore consumed exactly once (no double-iterator).
        helloAckDelivered = false
        startControlForwarding(from: control)

        // 3. Send hello and await helloAck (bounded).
        try await control.send(.hello(
            protocolVersion: Rwork.protocolVersion,
            sessionID: resume,
            lastReceivedSeq: lastReceivedSeq
        ))
        let ack = try await awaitHelloAck(timeout: handshakeTimeout)
        guard case let .helloAck(authoritativeID, resumeSeq, returning) = ack else {
            throw RworkTransportError.handshakeFailed("expected helloAck, got \(ack)")
        }
        self.sessionID = authoritativeID
        self.resumeFromSeq = resumeSeq
        self.returningClient = returning

        // 4. DATA connection: open, send data preamble tagged with the authoritative id.
        let dataConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await dataConn.startAndWaitReady(on: DispatchQueue(label: "rwork.client.data"))
        try await dataConn.sendRaw(ChannelAssociation.dataPreamble(sessionID: authoritativeID))

        let data = NWMessageChannel(connection: dataConn, channel: .data)
        await data.start()
        try await data.waitUntilReady()

        self.controlChannel = control
        self.dataChannel = data
        self.connection = RworkConnection(data: data, control: control)

        // 5. Forward the DATA channel into the merged stream (CONTROL already forwarding).
        startDataForwarding(from: data)
    }

    /// Suspends until the control forwarder delivers `helloAck`, or `timeout` elapses.
    private func awaitHelloAck(timeout: Duration) async throws -> WireMessage {
        try await withThrowingTaskGroup(of: WireMessage.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw RworkTransportError.invalidState("client deinit") }
                return try await self.suspendForHelloAck()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RworkTransportError.timedOut("helloAck")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// The actor-isolated suspension point the helloAck waiter parks on.
    private func suspendForHelloAck() async throws -> WireMessage {
        try await withCheckedThrowingContinuation { continuation in
            helloAckWaiter = continuation
        }
    }

    /// The single consumer of the control channel. Intercepts the first `helloAck`;
    /// forwards everything else.
    private func startControlForwarding(from channel: NWMessageChannel) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await message in channel.inbound {
                    await self.handleControlInbound(message)
                }
                await self.finishInbound(error: nil)
            } catch {
                await self.failHelloAckIfWaiting(error)
                await self.finishInbound(error: error)
            }
        }
        forwarders.append(task)
    }

    private func handleControlInbound(_ message: WireMessage) {
        if !helloAckDelivered, case .helloAck = message {
            helloAckDelivered = true
            let waiter = helloAckWaiter
            helloAckWaiter = nil
            waiter?.resume(returning: message)
            return // do not forward the handshake reply itself
        }
        inboundContinuation.yield(message)
    }

    private func failHelloAckIfWaiting(_ error: Error) {
        guard let waiter = helloAckWaiter else { return }
        helloAckWaiter = nil
        waiter.resume(throwing: error)
    }

    private func finishInbound(error: Error?) {
        if let error {
            inboundContinuation.finish(throwing: error)
        } else {
            inboundContinuation.finish()
        }
    }

    private func startDataForwarding(from channel: NWMessageChannel) {
        let continuation = inboundContinuation
        let task = Task {
            do {
                for try await message in channel.inbound {
                    continuation.yield(message)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        forwarders.append(task)
    }

    // MARK: Outbound (client → host)

    /// Sends raw keystroke/paste bytes as `input` on the **data** channel.
    public func sendInput(_ bytes: Data) async throws {
        try await requireData().send(.input(bytes))
    }

    /// Sends a `resize` on the **control** channel.
    public func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) async throws {
        try await requireControl().send(.resize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight))
    }

    /// Sends an `ack` (highest contiguous output seq durably received) on the
    /// **control** channel so the host can release replay-buffer entries.
    public func sendAck(seq: Int64) async throws {
        try await requireControl().send(.ack(seq: seq))
    }

    /// Sends a clean `bye` on the **control** channel.
    public func sendBye() async throws {
        try await requireControl().send(.bye)
    }

    /// Tears down both channels and finishes the inbound stream.
    public func close() {
        for task in forwarders { task.cancel() }
        forwarders.removeAll()
        let data = dataChannel
        let control = controlChannel
        Task {
            await data?.close()
            await control?.close()
        }
        inboundContinuation.finish()
        connection = nil
        dataChannel = nil
        controlChannel = nil
    }

    private func requireData() throws -> NWMessageChannel {
        guard let dataChannel else { throw RworkTransportError.invalidState("not connected (data)") }
        return dataChannel
    }

    private func requireControl() throws -> NWMessageChannel {
        guard let controlChannel else { throw RworkTransportError.invalidState("not connected (control)") }
        return controlChannel
    }
}
