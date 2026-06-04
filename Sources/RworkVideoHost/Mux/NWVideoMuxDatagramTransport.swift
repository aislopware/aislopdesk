#if os(macOS)
import Foundation
import Network
import OSLog
import RworkVideoProtocol

/// The MUX (Stage S3) sibling of ``NWVideoDatagramTransport``: ONE physical UDP flow
/// (media + cursor sockets) shared across N client video channels, demultiplexed by a
/// `UInt32` channelID prefix (``VideoMuxHeaderCodec``) instead of the single-slot
/// client pin.
///
/// ⚠️ **GATED + WIRE-INCOMPATIBLE.** This type is used ONLY when `RWORK_VIDEO_MUX` is
/// ON (both ends must agree, ``VideoMuxGate``). The wire here is the 4-byte channelID
/// prefix in FRONT of the existing 1-byte channel tag + payload:
/// ```
///   [UInt32 BE channelID][UInt8 channelTag][payload...]   (media socket)
///   [UInt32 BE channelID][payload...]                     (cursor socket)
/// ```
/// A client that did NOT enable the gate writes the OFF framing (`[tag][payload]`),
/// which this transport parses as a stray channelID and routes through
/// ``VideoMuxRouter`` — which rejects the unadmitted lane (a clean DROP, never a crash
/// or a corrupt inject). That is the mixed-version "fail cleanly" contract.
///
/// ## Per-channel loss isolation (RTP semantics)
/// A lost datagram, or one channel's `retire`, only affects THAT channelID — sibling
/// lanes keep routing (``VideoMuxRouter/dropRetired`` keeps a retired lane's in-flight
/// bytes out of survivors). The router never tears the shared flow down for a single
/// bad/late datagram.
///
/// ## HANG / SOCKET SAFETY
/// Opens real `NWListener`/`NWConnection` `.udp` flows — COMPILED + code-reviewed,
/// NEVER instantiated in a test (like ``NWVideoDatagramTransport``). The pure routing
/// it drives (``VideoMuxRouter``) and the per-channel framing (``VideoMuxHeaderCodec``)
/// ARE unit-tested in isolation; an in-memory routing harness covers the dispatch.
public final class NWVideoMuxDatagramTransport: @unchecked Sendable {
    private static func mediaSocket(for channel: VideoChannel) -> Bool { channel != .cursor }

    private let log = Logger(subsystem: "rwork.video.host", category: "NWVideoMuxDatagramTransport")
    private let mediaPort: NWEndpoint.Port
    private let cursorPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "rwork.video.transport.mux", qos: .userInteractive)

    private var mediaListener: NWListener?
    private var cursorListener: NWListener?

    /// All accepted client flows (UDP "connections" the listener pins per source endpoint).
    /// Under mux MANY clients legitimately share the listener, so — unlike the single-slot
    /// `NWVideoDatagramTransport` — every accepted flow is kept; demux happens per-datagram by
    /// channelID. Keyed by an opaque token so a failed flow removes only itself.
    private let lock = NSLock()
    private var mediaConns: [ObjectIdentifier: NWConnection] = [:]
    private var cursorConns: [ObjectIdentifier: NWConnection] = [:]
    /// channelID → the cursor flow that primed it, so a per-channel cursor datagram is sent back
    /// on the SAME flow the client opened (the host learns a cursor endpoint only from an inbound
    /// prime, exactly as in the OFF path). Media replies pick the flow that last carried the lane.
    private var channelMediaConn: [UInt32: NWConnection] = [:]
    private var channelCursorConn: [UInt32: NWConnection] = [:]
    /// The reconnect-generation-safe admit/retire/route table (PURE; unit-tested).
    private var muxRouter = VideoMuxRouter()
    private var stopped = false

    private final class Liveness: @unchecked Sendable {
        private let lock = NSLock()
        private var alive = true
        var isAlive: Bool { lock.withLock { alive } }
        func markDead() { lock.withLock { alive = false } }
    }

    public init(mediaPort: UInt16, cursorPort: UInt16) {
        self.mediaPort = NWEndpoint.Port(rawValue: mediaPort)!
        self.cursorPort = NWEndpoint.Port(rawValue: cursorPort)!
    }

    // MARK: - Admission (driven by the daemon's session registry on hello / bye)

    /// Admit a channelID as a live lane (the daemon minted/looked-up a session for it). Idempotent.
    public func admit(_ channelID: UInt32) {
        lock.withLock { muxRouter.admit(channelID) }
    }

    /// Retire a channelID (the daemon saw its `bye` or tore the session down). Its still-in-flight
    /// datagrams are dropped; SIBLING lanes are untouched — the bye retires ONLY the closing lane.
    public func retire(_ channelID: UInt32) {
        lock.withLock {
            muxRouter.retire(channelID)
            channelMediaConn.removeValue(forKey: channelID)
            channelCursorConn.removeValue(forKey: channelID)
        }
    }

    // MARK: - Lifecycle

    /// Binds the shared media + cursor sockets and routes each inbound datagram, by its leading
    /// channelID, to `onReceive(channelID, channel, payload)`. The daemon dispatches that to the
    /// per-channel session. A datagram for an unadmitted/retired channelID is dropped (per-channel
    /// loss isolation), never delivered, never fatal.
    public func start(onReceive: @escaping @Sendable (_ channelID: UInt32, _ channel: VideoChannel, _ data: Data) -> Void) async throws {
        let params = NWParameters.udp
        params.includePeerToPeer = false

        let media = try NWListener(using: params, on: mediaPort)
        media.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }
            self.mediaConns[ObjectIdentifier(conn)] = conn
            self.lock.unlock()
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
            if self.stopped { self.lock.unlock(); conn.cancel(); return }
            self.cursorConns[ObjectIdentifier(conn)] = conn
            self.lock.unlock()
            let live = Liveness()
            self.installResetHandler(on: conn, isMedia: false, live: live)
            conn.start(queue: self.queue)
            self.receiveCursor(on: conn, live: live, onReceive: onReceive)
        }
        cursor.start(queue: queue)
        self.cursorListener = cursor

        log.info("NWVideoMuxDatagramTransport listening media=\(self.mediaPort.rawValue) cursor=\(self.cursorPort.rawValue) (shared mux flow)")
    }

    // ⚠️ KNOWN ON-PATH RESIDUAL (MEDIUM, audit review — mux analogue of the OFF-path
    // CONCURRENCY-HOST-1 'crash-without-bye needs an idle-timeout reaper', docs/25 §4): a client
    // that vanishes WITHOUT a bye (crash, or last-lane close racing the fire-and-forget bye egress)
    // leaves its host session minted + its SCStream capture/encode RUNNING (bye → stopCapture never
    // fires). This handler only forgets the flow's socket bookkeeping on .failed/.cancelled — it does
    // NOT retire the channelIDs that rode the flow nor stop their sessions, so capture leaks CPU with
    // no client. Worse than OFF (where idle capture is one window) only because mux multiplies it.
    // The correct fix is an idle-timeout reaper (no datagram for N seconds → retire + stop the lane),
    // which depends on real UDP liveness timing and cannot be verified headlessly — deferred to the
    // Mac Studio bring-up rather than shipped blind. Bind a per-flow retire here once that lands.
    private func installResetHandler(on conn: NWConnection, isMedia: Bool, live: Liveness) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                live.markDead()
                self.lock.lock()
                if isMedia {
                    self.mediaConns.removeValue(forKey: ObjectIdentifier(conn))
                    self.channelMediaConn = self.channelMediaConn.filter { $0.value !== conn }
                } else {
                    self.cursorConns.removeValue(forKey: ObjectIdentifier(conn))
                    self.channelCursorConn = self.channelCursorConn.filter { $0.value !== conn }
                }
                self.lock.unlock()
            default:
                break
            }
        }
    }

    private func receiveMedia(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.routeMedia(data, on: conn, onReceive: onReceive)
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("mux media receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
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

    /// Parses `[channelID][tag][payload]`, routes by channelID (per-channel loss isolation), and on
    /// a routed datagram remembers the flow for the lane so host→client media for it can reply.
    ///
    /// **Bootstrap exception (the first hello).** A lane is only `admit`ted once the daemon's session
    /// registry mints its session — but the very FIRST hello for a never-seen channelID arrives BEFORE
    /// that, so it is not yet admitted. A `.control` datagram for an UNADMITTED (never-retired) lane is
    /// therefore still delivered to `onReceive` so the registry can mint on the hello; the registry's
    /// own `decide` drops a non-hello unbound control datagram. A RETIRED lane is always hard-dropped
    /// (reconnect-generation safety — a stale frame must never reach a survivor), and a non-control
    /// unadmitted datagram (a stray video/input for an unknown lane) is dropped.
    private func routeMedia(_ data: Data, on conn: NWConnection, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        guard let (channelID, rest) = try? VideoMuxHeaderCodec.decode(data), rest.count >= 1 else { return }
        let tag = rest[rest.startIndex]
        guard let channel = VideoChannel(rawValue: tag) else { return }
        let payload = Data(rest[(rest.startIndex + 1)...])
        let deliver: Bool = lock.withLock {
            switch muxRouter.route(channelID: channelID, channel: channel, bytesCount: data.count) {
            case .route:
                channelMediaConn[channelID] = conn
                return true
            case .rejectUnadmitted:
                // Bootstrap: let an unadmitted CONTROL datagram (the hello) through to the registry,
                // which mints the lane; remember the flow so the helloAck can reply. Anything else is
                // a stray for an unknown lane — drop.
                if channel == .control {
                    channelMediaConn[channelID] = conn
                    return true
                }
                return false
            case .dropRetired, .drop:
                return false   // benign — never fatal, never a sibling teardown
            }
        }
        guard deliver else { return }
        onReceive(channelID, channel, payload)
    }

    private func receiveCursor(on conn: NWConnection, live: Liveness, consecutiveErrors: Int = 0, onReceive: @escaping @Sendable (UInt32, VideoChannel, Data) -> Void) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                // The cursor flow's leading prime + any client→host bytes are channelID-prefixed so
                // the host can bind the lane's reply flow. The host does not deliver inbound cursor
                // payloads to the session (host→client only), but it MUST learn the lane's flow.
                // Remember it unconditionally — the prime can race AHEAD of the media hello, so the
                // lane may not be admitted yet; the first cursor SEND after admission uses this flow.
                if let (channelID, _) = try? VideoMuxHeaderCodec.decode(data) {
                    self.lock.withLock { self.channelCursorConn[channelID] = conn }
                }
            }
            guard UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: live.isAlive) else { return }
            if let error {
                self.log.error("mux cursor receive error (transient, backing off + re-arming if alive): \(String(describing: error))")
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

    // MARK: - Send (host → client, per channelID)

    /// Sends one datagram for `channelID` on `channel`, stamping `[channelID][tag][payload]` (media)
    /// or `[channelID][payload]` (cursor). Fire-and-forget (UDP). A lane with no known flow yet
    /// drops (the client has not opened it) — never blocks, never errors out the shared flow.
    public func send(_ datagram: Data, on channel: VideoChannel, channelID: UInt32) {
        let isMedia = Self.mediaSocket(for: channel)
        let conn: NWConnection? = lock.withLock { isMedia ? channelMediaConn[channelID] : channelCursorConn[channelID] }
        guard let conn else { return }
        let framed: Data
        if isMedia {
            var inner = Data(capacity: datagram.count + 1)
            inner.append(channel.rawValue)
            inner.append(datagram)
            framed = VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner)
        } else {
            framed = VideoMuxHeaderCodec.encode(channelID: channelID, payload: datagram)
        }
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("mux udp send failed channel=\(channel.rawValue) chan=\(channelID): \(String(describing: error))") }
        })
    }

    public func stop() async {
        mediaListener?.cancel(); mediaListener = nil
        cursorListener?.cancel(); cursorListener = nil
        lock.withLock {
            stopped = true
            for conn in mediaConns.values { conn.cancel() }
            for conn in cursorConns.values { conn.cancel() }
            mediaConns.removeAll()
            cursorConns.removeAll()
            channelMediaConn.removeAll()
            channelCursorConn.removeAll()
        }
    }
}
#endif
