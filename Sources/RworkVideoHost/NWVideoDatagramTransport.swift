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
            // Clear the slot when this connection dies so a reconnecting client (process
            // restart, path flap, new source port) can RE-PIN — without this the dead
            // connection wedges the slot forever and every reconnect is silently refused.
            self.installResetHandler(on: conn, isMedia: true)
            conn.start(queue: self.queue)
            self.receiveMedia(on: conn, onReceive: onReceive)
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
            self.installResetHandler(on: conn, isMedia: false)
            conn.start(queue: self.queue)
            self.receiveCursor(on: conn, onReceive: onReceive)
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
    private func installResetHandler(on conn: NWConnection, isMedia: Bool) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
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

    private func receiveMedia(on conn: NWConnection, onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.count >= 1 {
                let tag = data[data.startIndex]
                if let channel = VideoChannel(rawValue: tag) {
                    onReceive(channel, Data(data[(data.startIndex + 1)...]))
                }
            }
            if error == nil && !isComplete {
                self.receiveMedia(on: conn, onReceive: onReceive)
            }
        }
    }

    private func receiveCursor(on conn: NWConnection, onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { onReceive(.cursor, data) }
            if error == nil && !isComplete {
                self.receiveCursor(on: conn, onReceive: onReceive)
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
#endif
