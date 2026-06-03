#if canImport(Network)
import Foundation
import Network
import OSLog
import RworkVideoProtocol

/// Production UDP transport for the PATH 2 **client**, built on `Network.framework`
/// `NWConnection` with `.udp` — the mirror of the host's `NWVideoDatagramTransport`.
///
/// ⚠️ **HANG / SOCKET SAFETY:** opens real UDP connections. Like the rest of the live
/// client pipeline it is COMPILED + code-reviewed but NEVER instantiated in a test
/// (the orchestrator is tested against an in-memory ``VideoClientTransport`` fake).
/// No app-layer crypto — WireGuard already encrypts (doc 13, same rationale as the
/// host transport).
///
/// Socket topology (must match the host, doc 17 §3.3): TWO UDP connections —
/// - **media** → the host's media port: client SENDS control + input (each prefixed
///   with the 1-byte ``VideoChannel`` tag) and RECEIVES control / video / geometry
///   (tag-prefixed, demultiplexed back to a channel).
/// - **cursor** → the host's cursor port: receive-only, bare ``CursorChannelMessage``
///   bytes (single-purpose, no tag).
public final class NWVideoClientTransport: VideoClientTransport, @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool {
        channel != .cursor
    }

    private let log = Logger(subsystem: "rwork.video.client", category: "NWVideoClientTransport")
    private let mediaEndpoint: NWEndpoint
    private let cursorEndpoint: NWEndpoint
    private let queue = DispatchQueue(label: "rwork.video.client.transport", qos: .userInteractive)

    private let lock = NSLock()
    private var mediaConn: NWConnection?
    private var cursorConn: NWConnection?

    /// Per-connection liveness, flipped to `false` by the connection's
    /// `stateUpdateHandler` when it reaches `.failed`/`.cancelled`. The receive loops
    /// consult it via ``UDPReceiveLoopPolicy`` so a TRANSIENT per-datagram receive error
    /// (e.g. ICMP port-unreachable surfaced as ECONNREFUSED while the connection stays
    /// `.ready`) re-arms the loop instead of ending it forever (BUG-L). A truly dead
    /// socket flips the flag, which stops the loop. Reference type so the closure and the
    /// state handler share one cell; `@unchecked Sendable` via the internal `NSLock`.
    private final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        var isAlive: Bool { lock.withLock { alive } }
        func markDead() { lock.withLock { alive = false } }
    }

    /// - Parameters:
    ///   - host: the host's NetBird-routable address (or hostname).
    ///   - mediaPort: the host media UDP port (control/video/geometry/input).
    ///   - cursorPort: the host dedicated cursor UDP port.
    public init(host: String, mediaPort: UInt16, cursorPort: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        self.mediaEndpoint = NWEndpoint.hostPort(host: nwHost, port: NWEndpoint.Port(rawValue: mediaPort)!)
        self.cursorEndpoint = NWEndpoint.hostPort(host: nwHost, port: NWEndpoint.Port(rawValue: cursorPort)!)
    }

    public func start(
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void
    ) async throws {
        let params = NWParameters.udp
        params.includePeerToPeer = false

        let media = NWConnection(to: mediaEndpoint, using: params)
        let cursor = NWConnection(to: cursorEndpoint, using: params)
        lock.withLock { mediaConn = media; cursorConn = cursor }

        // One liveness cell per connection: its state handler flips it dead on
        // `.failed`/`.cancelled` so the receive loops stop only on a genuinely dead
        // socket, not on a transient per-datagram error (BUG-L). Installed BEFORE
        // `start(...)` so no early fatal transition is missed.
        let mediaLive = Liveness()
        let cursorLive = Liveness()
        media.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: mediaLive.markDead()
            default: break
            }
        }
        cursor.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: cursorLive.markDead()
            default: break
            }
        }

        media.start(queue: queue)
        cursor.start(queue: queue)
        receiveMedia(on: media, live: mediaLive, onMedia: onMedia)
        receiveCursor(on: cursor, live: cursorLive, onCursor: onCursor)

        // PRIME the cursor side-channel. The host binds the cursor port with an `NWListener`,
        // which only ACCEPTS (and pins) a flow once an inbound datagram arrives from us — but
        // the client is otherwise receive-only on cursor (`send` refuses the cursor channel).
        // Without this prime the host never learns our cursor endpoint, so its `cursorConn`
        // stays nil and NOT ONE cursor update is ever delivered (the side-channel is silently
        // dead). One non-empty datagram is enough to pin the flow; the host ignores inbound
        // `.cursor` payloads (`RworkVideoHostSession.receive` drops them), so the content is
        // irrelevant — send a 1-byte keepalive. (Over WireGuard the path is stable, so a
        // single prime suffices; a periodic keepalive could be added if a real NAT path needs
        // to keep the host→client mapping open.)
        cursor.send(content: Data([0x00]), completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("cursor prime send failed: \(String(describing: error))") }
        })

        log.info("NWVideoClientTransport connected media=\(String(describing: self.mediaEndpoint)) cursor=\(String(describing: self.cursorEndpoint))")
    }

    private func receiveMedia(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onMedia: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 1 {
                let tag = data[data.startIndex]
                if let channel = VideoChannel(rawValue: tag) {
                    onMedia(channel, Data(data[(data.startIndex + 1)...]))
                }
            }
            // UDP: `receiveMessage` delivers EVERY datagram with `isComplete == true` (each
            // datagram IS a complete message), so re-arming only on `!isComplete` would stop
            // the loop dead after the FIRST datagram. We ALSO must not stop on a transient
            // per-datagram error: an ICMP port-unreachable (ECONNREFUSED) surfaces here as a
            // receive error while the connection stays `.ready`, and the old `if error == nil`
            // ended the loop forever — the client silently stopped receiving all video
            // (BUG-L). Re-arm unless the connection is genuinely dead (its state handler
            // flipped `live`); a dead socket is stopped by that path, not by the error here.
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                // A SUSTAINED per-datagram error (e.g. ICMP port-unreachable delivered as
                // ECONNREFUSED on every `receiveMessage` while the connection stays `.ready`)
                // would re-arm immediately every time → 100% CPU busy-loop (F3). Back off with
                // a small capped delay that grows with the consecutive-error count; reset to
                // immediate re-arm on the first error-free datagram (below).
                self.log.error("media receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveMedia(on: conn, live: live, consecutiveErrors: next, onMedia: onMedia)
                }
            } else {
                self.receiveMedia(on: conn, live: live, consecutiveErrors: 0, onMedia: onMedia)
            }
        }
    }

    private func receiveCursor(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onCursor: @escaping @Sendable (Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { onCursor(data) }
            // Same transient-error survival as receiveMedia (BUG-L): re-arm on a per-datagram
            // error, stop only when the connection's state handler marks it dead. Same
            // consecutive-error backoff as receiveMedia so a sustained error does not spin (F3).
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveCursor(on: conn, live: live, consecutiveErrors: next, onCursor: onCursor)
                }
            } else {
                self.receiveCursor(on: conn, live: live, consecutiveErrors: 0, onCursor: onCursor)
            }
        }
    }

    public func send(_ datagram: Data, on channel: VideoChannel) {
        // The client only sends on the media socket (control + input). Cursor is
        // receive-only; a stray cursor send is dropped defensively.
        guard Self.mediaSocket(for: channel) else { return }
        lock.lock(); let conn = mediaConn; lock.unlock()
        guard let conn else { return } // not connected yet — drop (UDP, fire-and-forget)
        var framed = Data(capacity: datagram.count + 1)
        framed.append(channel.rawValue)
        framed.append(datagram)
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("udp send failed on channel \(channel.rawValue): \(String(describing: error))") }
        })
    }

    public func stop() async {
        lock.withLock {
            mediaConn?.cancel(); mediaConn = nil
            cursorConn?.cancel(); cursorConn = nil
        }
    }
}

/// Pure re-arm decision for a UDP `receiveMessage` loop (BUG-L).
///
/// The receive loop must keep itself armed across TRANSIENT per-datagram errors (an
/// ICMP port-unreachable surfaces as a receive error even while the `NWConnection`
/// stays `.ready`) and stop ONLY when the connection is genuinely dead. The liveness
/// signal comes from the connection's `stateUpdateHandler` (`.failed`/`.cancelled`),
/// not from the per-receive error — so the decision is purely "is the connection still
/// alive?", which is unit-testable without a socket. (The host's
/// `NWVideoDatagramTransport` carries its own identical copy: the two transports live
/// in separate modules and each owns its policy, the wire/behaviour contract being the
/// agreement rather than a shared Swift type.)
public enum UDPReceiveLoopPolicy {
    /// Re-arm the receive loop iff the connection is still alive. A per-datagram error
    /// does NOT stop the loop; only a dead connection does.
    public static func shouldRearm(connectionIsAlive: Bool) -> Bool {
        connectionIsAlive
    }

    /// Smallest re-arm delay after the first consecutive error (5 ms).
    static let baseBackoff: TimeInterval = 0.005
    /// Capped re-arm delay so a long ECONNREFUSED storm settles at ~250 ms, not a spin.
    static let maxBackoff: TimeInterval = 0.25

    /// The delay before re-arming the UDP `receiveMessage` loop after an ERROR-bearing
    /// completion, given how many errors have arrived back-to-back without an
    /// intervening good datagram (F3). The BUG-L fix re-arms on a transient error, but a
    /// SUSTAINED error (an ICMP port-unreachable delivered as ECONNREFUSED on every
    /// `receiveMessage` while the connection stays `.ready`) re-armed with ZERO delay →
    /// 100% CPU busy-loop. Exponential growth from `baseBackoff` (×2 per consecutive
    /// error), capped at `maxBackoff`. The loop RESETS `consecutiveErrors` to 0 on the
    /// first error-free datagram, so `nextBackoff(0)` is 0 (immediate re-arm — the normal
    /// hot path is never delayed). Pure + unit-testable (no socket / clock).
    ///
    /// - Parameter consecutiveErrors: number of back-to-back errors INCLUDING the one
    ///   just observed (0 ⇒ no error, immediate re-arm).
    public static func nextBackoff(consecutiveErrors: Int) -> TimeInterval {
        guard consecutiveErrors > 0 else { return 0 }
        // baseBackoff · 2^(n-1), clamped to maxBackoff. Compute the multiplier without
        // overflow for large n by capping the shift exponent.
        let exponent = min(consecutiveErrors - 1, 16) // 2^16 · 5ms ≫ 250ms cap
        let scaled = baseBackoff * Double(1 << exponent)
        return min(scaled, maxBackoff)
    }
}
#endif
