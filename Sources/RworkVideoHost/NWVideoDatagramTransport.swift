#if os(macOS)
import Foundation
import Network
import OSLog
import RworkVideoProtocol

/// Production UDP transport for the PATH 2 host, built on `Network.framework`
/// `NWListener`/`NWConnection` with `.udp` (the task-mandated socket).
///
/// ⚠️ **HANG / SOCKET SAFETY:** opens real UDP listeners + connections. Like the rest
/// of `RworkVideoHost` it is COMPILED + code-reviewed but NEVER instantiated in a
/// test (the orchestrator is tested against an in-memory ``VideoDatagramTransport``
/// fake). It binds on the host's NetBird-routable address; no app-layer crypto —
/// WireGuard already encrypts (doc 13, same rationale as `TransportParameters`).
///
/// Socket topology (doc 17 §3.3): TWO UDP listeners —
/// - **media** carries control / video / geometry datagrams (host→client) and input
///   datagrams (client→host). A 1-byte channel tag prefixes each media datagram so a
///   single socket multiplexes those lanes.
/// - **cursor** is a dedicated socket so video backpressure never delays the cursor.
///
/// A datagram framing prefix (1 byte) tells the channels apart ON THE MEDIA SOCKET
/// only; the cursor socket carries bare ``CursorChannelMessage`` bytes (it is
/// single-purpose, and its messages already self-describe via their leading type
/// byte). This prefix is the one wire detail introduced here for the docs step.
public final class NWVideoDatagramTransport: VideoDatagramTransport, @unchecked Sendable {
    /// 1-byte channel tag prepended to MEDIA-socket datagrams (control/video/
    /// geometry/input). The cursor socket carries no tag (single purpose).
    private static func mediaSocket(for channel: VideoChannel) -> Bool {
        channel != .cursor
    }

    private let log = Logger(subsystem: "rwork.video.host", category: "NWVideoDatagramTransport")
    private let mediaPort: NWEndpoint.Port
    private let cursorPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "rwork.video.transport", qos: .userInteractive)

    private var mediaListener: NWListener?
    private var cursorListener: NWListener?
    /// The accepted client connections (one per socket). UDP "connections" here are
    /// `NWListener`-accepted flows keyed to the client's source endpoint.
    private let lock = NSLock()
    private var mediaConn: NWConnection?
    private var cursorConn: NWConnection?

    /// Per-connection liveness, flipped to `false` by the connection's state handler at
    /// `.failed`/`.cancelled`. The receive loops consult it via ``UDPReceiveLoopPolicy``
    /// so a TRANSIENT per-datagram receive error (e.g. ICMP port-unreachable surfaced as
    /// ECONNREFUSED while the flow stays `.ready`) re-arms the loop instead of ending it
    /// forever (BUG-L) — without it the host stopped receiving the client's input /
    /// recovery requests on a single transient error. A truly dead flow flips the flag,
    /// which stops the loop. Reference type so the closures share one cell;
    /// `@unchecked Sendable` via the internal `NSLock`.
    private final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        var isAlive: Bool { lock.withLock { alive } }
        func markDead() { lock.withLock { alive = false } }
    }
    /// Set true inside ``stop()`` (under `lock`). Guards the accept-after-stop race: a
    /// connection the `NWListener` accepts concurrently with `stop()` must be cancelled,
    /// not stored+started (else it leaks — `stop()` already niled the slots).
    private var stopped = false

    public init(mediaPort: UInt16, cursorPort: UInt16) {
        self.mediaPort = NWEndpoint.Port(rawValue: mediaPort)!
        self.cursorPort = NWEndpoint.Port(rawValue: cursorPort)!
    }

    public func start(onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) async throws {
        let params = NWParameters.udp
        params.includePeerToPeer = false

        let media = try NWListener(using: params, on: mediaPort)
        media.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // Pin to the FIRST accepted client; reject later source endpoints so a stray/extra
            // inbound datagram never clobbers the streaming connection (the state machine + the
            // single-client model assume one peer).
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }   // accept-after-stop
            if self.mediaConn == nil { self.mediaConn = conn; self.lock.unlock() }
            else { self.lock.unlock(); conn.cancel(); return }
            // Clear the slot when this connection FAILS/CANCELS so a reconnecting client can
            // RE-PIN — without this the dead connection wedged the slot forever and every
            // reconnect was silently refused until daemon restart. RESIDUALS (follow-up):
            // (1) UDP has no FIN, so a client that restarts with a NEW source port does NOT
            //     promptly fail the OLD flow — the slot stays pinned until the path actually
            //     errors or an idle timeout fires, so an immediate same-window port-change
            //     reconnect is still refused in the interim. A proper fix needs a client
            //     identity in `hello` so the host can adopt the newest flow safely.
            // (2) Clearing the socket slot does NOT reset the VideoSessionStateMachine (still
            //     `.streaming`), so a re-pinned client is re-acked with the old streamID and no
            //     fresh IDR; it resumes via the existing client-driven IDR recovery (.recovery
            //     channel → requestIDR → capturer.requestKeyframe), not via an SM reset.
            let live = Liveness()
            self.installResetHandler(on: conn, isMedia: true, live: live)
            conn.start(queue: self.queue)
            self.receiveMedia(on: conn, live: live, onReceive: onReceive)
        }
        media.start(queue: queue)
        self.mediaListener = media

        let cursor = try NWListener(using: params, on: cursorPort)
        cursor.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }   // accept-after-stop
            if self.cursorConn == nil { self.cursorConn = conn; self.lock.unlock() }
            else { self.lock.unlock(); conn.cancel(); return }
            let live = Liveness()
            self.installResetHandler(on: conn, isMedia: false, live: live)
            conn.start(queue: self.queue)
            self.receiveCursor(on: conn, live: live, onReceive: onReceive)
        }
        cursor.start(queue: queue)
        self.cursorListener = cursor

        log.info("NWVideoDatagramTransport listening media=\(self.mediaPort.rawValue) cursor=\(self.cursorPort.rawValue)")
    }

    /// Installs a `stateUpdateHandler` that clears the pinned slot when `conn` fails or is
    /// cancelled, so the listener's `newConnectionHandler` can re-pin a reconnecting client.
    /// Must be set BEFORE `conn.start(...)` so no early transition is missed. Only clears the
    /// slot if it still holds THIS connection (identity check) — never clobbers a peer that
    /// re-pinned in the meantime.
    private func installResetHandler(on conn: NWConnection, isMedia: Bool, live: Liveness) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                // Mark the flow dead so its receive loop stops re-arming (BUG-L): the
                // receive loop survives transient per-datagram errors and relies on THIS
                // path to end it when the connection is genuinely gone.
                live.markDead()
                self.lock.lock()
                if isMedia {
                    if self.mediaConn === conn { self.mediaConn = nil }
                } else {
                    if self.cursorConn === conn { self.cursorConn = nil }
                }
                self.lock.unlock()
            default:
                break
            }
        }
    }

    private func receiveMedia(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 1 {
                let tag = data[data.startIndex]
                if let channel = VideoChannel(rawValue: tag) {
                    onReceive(channel, Data(data[(data.startIndex + 1)...]))
                }
            }
            // UDP: every datagram completes (`isComplete == true`), so re-arming only on
            // `!isComplete` would stop after the client's first datagram (the hello). We ALSO
            // must survive a TRANSIENT per-datagram error: an ICMP port-unreachable
            // (ECONNREFUSED) surfaces here as a receive error while the flow stays `.ready`,
            // and the old `if error == nil` ended the loop forever — the host then silently
            // stopped receiving the client's input / recovery requests (BUG-L). Re-arm unless
            // the flow is genuinely dead (its state handler flipped `live`).
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                // A SUSTAINED per-datagram error (ECONNREFUSED on every `receiveMessage` while
                // the flow stays `.ready`) would re-arm with zero delay every time → 100% CPU
                // busy-loop (F3). Back off with a small capped delay that grows with the
                // consecutive-error count; reset to immediate re-arm on the first good datagram.
                self.log.error("media receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveMedia(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                }
            } else {
                self.receiveMedia(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    private func receiveCursor(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { onReceive(.cursor, data) }
            // Same transient-error survival as receiveMedia (BUG-L): re-arm on a per-datagram
            // error, stop only when the flow's state handler marks it dead. Same
            // consecutive-error backoff as receiveMedia so a sustained error does not spin (F3).
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
                let next = consecutiveErrors + 1
                self.queue.asyncAfter(deadline: .now() + UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: next)) { [weak self] in
                    guard let self, live.isAlive else { return }
                    self.receiveCursor(on: conn, live: live, consecutiveErrors: next, onReceive: onReceive)
                }
            } else {
                self.receiveCursor(on: conn, live: live, consecutiveErrors: 0, onReceive: onReceive)
            }
        }
    }

    public func send(_ datagram: Data, on channel: VideoChannel) {
        lock.lock()
        let conn = Self.mediaSocket(for: channel) ? mediaConn : cursorConn
        lock.unlock()
        guard let conn else { return } // no client yet — drop (UDP, fire-and-forget)
        let payload: Data
        if Self.mediaSocket(for: channel) {
            var framed = Data(capacity: datagram.count + 1)
            framed.append(channel.rawValue)
            framed.append(datagram)
            payload = framed
        } else {
            payload = datagram
        }
        conn.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("udp send failed on channel \(channel.rawValue): \(String(describing: error))") }
        })
    }

    public func stop() async {
        mediaListener?.cancel(); mediaListener = nil
        cursorListener?.cancel(); cursorListener = nil
        lock.withLock {
            // Mark stopped FIRST so a connection the listener accepts concurrently with this
            // teardown is cancelled by `newConnectionHandler` instead of being stored after
            // we nil the slots (which would leak it).
            stopped = true
            mediaConn?.cancel(); mediaConn = nil
            cursorConn?.cancel(); cursorConn = nil
        }
    }
}

/// Pure re-arm decision for a UDP `receiveMessage` loop (BUG-L) — the host-side mirror
/// of the client's `RworkVideoClient.UDPReceiveLoopPolicy`.
///
/// The receive loop must keep itself armed across TRANSIENT per-datagram errors (an
/// ICMP port-unreachable surfaces as a receive error even while the flow stays
/// `.ready`) and stop ONLY when the flow is genuinely dead. The liveness signal comes
/// from the connection's state handler (`.failed`/`.cancelled`), not from the
/// per-receive error — so the decision is purely "is the flow still alive?", which is
/// unit-testable without a socket. (Client + host live in separate modules and each
/// owns an identical copy; the behaviour contract is the agreement, not a shared type.)
public enum UDPReceiveLoopPolicy {
    /// Re-arm the receive loop iff the flow is still alive. A per-datagram error does
    /// NOT stop the loop; only a dead flow does.
    public static func shouldRearm(connectionIsAlive: Bool) -> Bool {
        connectionIsAlive
    }

    /// Smallest re-arm delay after the first consecutive error (5 ms).
    static let baseBackoff: TimeInterval = 0.005
    /// Capped re-arm delay so a long ECONNREFUSED storm settles at ~250 ms, not a spin.
    static let maxBackoff: TimeInterval = 0.25

    /// The delay before re-arming the UDP `receiveMessage` loop after an ERROR-bearing
    /// completion, given how many errors have arrived back-to-back without an
    /// intervening good datagram (F3) — the host-side mirror of the client's policy. The
    /// BUG-L fix re-arms on a transient error, but a SUSTAINED error (an ICMP
    /// port-unreachable delivered as ECONNREFUSED on every `receiveMessage` while the
    /// flow stays `.ready`) re-armed with ZERO delay → 100% CPU busy-loop. Exponential
    /// growth from `baseBackoff` (×2 per consecutive error), capped at `maxBackoff`. The
    /// loop RESETS `consecutiveErrors` to 0 on the first error-free datagram, so
    /// `nextBackoff(0)` is 0 (immediate re-arm — the normal hot path is never delayed).
    /// Pure + unit-testable (no socket / clock).
    ///
    /// - Parameter consecutiveErrors: number of back-to-back errors INCLUDING the one
    ///   just observed (0 ⇒ no error, immediate re-arm).
    public static func nextBackoff(consecutiveErrors: Int) -> TimeInterval {
        guard consecutiveErrors > 0 else { return 0 }
        let exponent = min(consecutiveErrors - 1, 16) // 2^16 · 5ms ≫ 250ms cap
        let scaled = baseBackoff * Double(1 << exponent)
        return min(scaled, maxBackoff)
    }
}
#endif
