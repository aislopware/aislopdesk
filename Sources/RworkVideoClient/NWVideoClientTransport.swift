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

        media.start(queue: queue)
        cursor.start(queue: queue)
        receiveMedia(on: media, onMedia: onMedia)
        receiveCursor(on: cursor, onCursor: onCursor)
        log.info("NWVideoClientTransport connected media=\(String(describing: self.mediaEndpoint)) cursor=\(String(describing: self.cursorEndpoint))")
    }

    private func receiveMedia(on conn: NWConnection, onMedia: @escaping @Sendable (VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.count >= 1 {
                let tag = data[data.startIndex]
                if let channel = VideoChannel(rawValue: tag) {
                    onMedia(channel, Data(data[(data.startIndex + 1)...]))
                }
            }
            if error == nil && !isComplete {
                self.receiveMedia(on: conn, onMedia: onMedia)
            }
        }
    }

    private func receiveCursor(on conn: NWConnection, onCursor: @escaping @Sendable (Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { onCursor(data) }
            if error == nil && !isComplete {
                self.receiveCursor(on: conn, onCursor: onCursor)
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
#endif
