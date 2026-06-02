#if canImport(VideoToolbox) && canImport(Metal) && canImport(QuartzCore)
import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import QuartzCore
import OSLog
import RworkVideoProtocol

/// The client-side session orchestrator for the GUI video path (PATH 2 / Phase 4) —
/// the exact mirror of `RworkVideoHost.RworkVideoHostSession`.
///
/// It wires the previously-disconnected client islands into a working pipeline:
///
/// ```
/// UDP media datagrams ─▶ ReceivedDatagramRouter
///   ├─ control  ─▶ VideoClientStateMachine (hello/helloAck/bye)
///   ├─ video    ─▶ FrameReassembler ─▶ FECScheme ─▶ VideoDecoder (VTDecompressionSession)
///   │                                            ─▶ FramePacer ─▶ MetalVideoRenderer
///   └─ geometry ─▶ window move/resize/title (drives the host view layout)
/// UDP cursor datagrams (own socket) ─▶ CursorChannelMessage ─▶ ClientCursorCompositor
/// view input (mouse/key/scroll/text) ─▶ InputEventEncoder ─▶ UDP input datagrams (→ host)
/// dropped frames ─▶ RecoveryPolicy ─▶ requestLTRRefresh / requestIDR (→ host)
/// ```
///
/// ⚠️ **HANG-SAFETY:** the live `start()` path brings up a `VTDecompressionSession`,
/// the Metal renderer, the `CVDisplayLink`/`CADisplayLink`, and UDP sockets — all of
/// which require a window-server / TCC session and HANG headlessly. This actor is
/// COMPILED + reviewed and only driven from a real GUI client app. Its PURE decision
/// logic (``VideoClientStateMachine`` / ``ReceivedDatagramRouter`` / ``VideoScaleMath``
/// / ``InputEventEncoder``) lives in `VideoClientSessionLogic.swift` and IS unit-tested.
public actor RworkVideoClientSession {
    private let log = Logger(subsystem: "rwork.video.client", category: "RworkVideoClientSession")

    /// Opt-in stderr diagnostics (`RWORK_VIDEO_DEBUG=1`) — the client counterpart to the host's,
    /// so `scripts/check-video.sh` can see whether media datagrams arrive, frames reassemble, and
    /// decode succeeds (OSLog `.info` is not persisted; a white client window is otherwise opaque).
    /// No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["RWORK_VIDEO_DEBUG"] != nil
    private var dbgMediaCount = 0
    private var dbgDecodeCount = 0
    nonisolated private func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("Rwork[video.client]: \(message())\n".utf8))
    }

    /// GUI hand-off seams. The renderer / cursor compositor / display link are all
    /// `@MainActor`-isolated (they touch `CAMetalLayer` / `CALayer` / a view's
    /// display link), so the actor never holds them directly; it calls these
    /// `@Sendable` closures. The decoded NV12 frame is submitted to the pacer the
    /// `VideoWindowPipeline` owns (most-recent-wins), which renders it at the display
    /// link's vsync. This keeps the orchestrator pure-actor and Sendable-clean while
    /// the GUI objects stay main-thread-confined. `VideoWindowPipeline` provides them.
    public struct GUIHooks: Sendable {
        /// Hand a freshly decoded NV12 buffer to the (pipeline-owned) frame pacer.
        public var submitDecodedFrame: @Sendable (CVImageBuffer) -> Void
        /// Place the cursor overlay (position scaled by videoScale, minus hotspot).
        public var applyCursor: @Sendable (CursorUpdate, Double) -> Void
        /// Register a cursor shape bitmap for its shapeID (shipped rarely, OOB).
        public var registerCursorShape: @Sendable (CGImage, UInt16) -> Void
        public init(
            submitDecodedFrame: @escaping @Sendable (CVImageBuffer) -> Void,
            applyCursor: @escaping @Sendable (CursorUpdate, Double) -> Void,
            registerCursorShape: @escaping @Sendable (CGImage, UInt16) -> Void
        ) {
            self.submitDecodedFrame = submitDecodedFrame
            self.applyCursor = applyCursor
            self.registerCursorShape = registerCursorShape
        }
    }

    private let transport: any VideoClientTransport
    private let gui: GUIHooks
    private let router = ReceivedDatagramRouter()
    private let recoveryPolicy: RecoveryPolicy

    private var stateMachine: VideoClientStateMachine
    private var reassembler: FrameReassembler
    private var inputEncoder = InputEventEncoder()

    /// The decoder is created on an accepted helloAck (never in a test).
    private var decoder: VideoDecoder?

    /// Decoded-frame geometry, used for the cursor placement scale. The capture size
    /// is the host's window-point size; the layer size is the on-screen point size.
    private var decodedSize: VideoSize = VideoSize(width: 0, height: 0)
    private var layerSize: VideoSize = VideoSize(width: 0, height: 0)
    /// The most recent host cursor position, re-applied whenever the scale changes so
    /// a layout/resize re-places the overlay without waiting for the next cursor packet.
    private var lastCursorUpdate: CursorUpdate?

    /// Recovery bookkeeping: when we last sent an LTR-refresh request (host time
    /// seconds), cleared once a keyframe decodes. Polled by ``shouldEscalateToIDR()``.
    private var lastRecoveryRequestTime: Double?
    /// Smoothed RTT estimate gating the 2·RTT IDR-escalation timeout. 50 ms default
    /// until ``updateRTTEstimate(_:)`` feeds a measurement.
    private var rttEstimate: TimeInterval = 0.05

    /// - Parameters:
    ///   - requestedWindowID: the host CGWindowID to remote.
    ///   - viewport: the client surface size sent in the hello.
    ///   - transport: the UDP transport (production: ``NWVideoClientTransport``).
    ///   - gui: the main-actor GUI hand-off seams (submit-frame / cursor / shape).
    ///   - fec: FEC scheme matching the host (default 20% XOR parity).
    public init(
        requestedWindowID: UInt32,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = XORParityFEC(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy()
    ) {
        self.transport = transport
        self.gui = gui
        self.recoveryPolicy = recoveryPolicy
        self.stateMachine = VideoClientStateMachine(requestedWindowID: requestedWindowID, viewport: viewport)
        self.reassembler = FrameReassembler(fec: fec)
        self.layerSize = viewport
    }

    // MARK: Lifecycle

    /// Connects the UDP flows, sends the `hello`, and starts receiving. The decode
    /// pipeline (decoder + display link) starts once the host accepts.
    public func start() async throws {
        try await transport.start { [weak self] channel, data in
            guard let self else { return }
            Task { await self.receiveMedia(channel: channel, data: data) }
        } onCursor: { [weak self] data in
            guard let self else { return }
            Task { await self.receiveCursor(data) }
        }
        for effect in stateMachine.start() { await apply(effect) }
        log.info("video client session started; hello sent")
    }

    /// Sends a best-effort `bye`, tears the pipeline + sockets down.
    public func stop() async {
        for effect in stateMachine.stop() { await apply(effect) }
        await transport.stop()
        log.info("video client session stopped")
    }

    // MARK: Layout (called by the host view each layout pass)

    /// Updates the on-screen layer size (points). Recomputes the cursor scale and
    /// re-applies the last cursor update so the overlay tracks the new layout.
    public func setLayerSize(_ size: VideoSize) {
        layerSize = size
        reapplyCursor()
    }

    /// The current videoScale = client-view-points per host-window-point. The host
    /// view feeds this to ``ClientCursorCompositor`` so the cursor lands correctly.
    public var videoScale: Double {
        VideoScaleMath.videoScale(layerSize: layerSize, decodedSize: decodedSize)
    }

    // MARK: Inbound media routing

    private func receiveMedia(channel: VideoChannel, data: Data) async {
        dbgMediaCount += 1
        if dbgMediaCount == 1 || dbgMediaCount % 30 == 0 {
            dbg("media datagram #\(dbgMediaCount) received (channel=\(channel), \(data.count)B, mediaFlowing=\(stateMachine.mediaFlowing))")
        }
        switch router.route(channel: channel, data: data, mediaFlowing: stateMachine.mediaFlowing) {
        case .control(let message):
            for effect in stateMachine.handleControl(message) { await apply(effect) }
        case .videoFragment(let fragment):
            ingestVideo(fragment)
        case .geometry(let message):
            applyGeometry(message)
        case .drop(let reason):
            log.error("dropping media datagram: \(reason)")
            dbg("media datagram DROPPED: \(reason)")
        case .ignore:
            break
        }
    }

    private func ingestVideo(_ fragment: FrameFragment) {
        let result = reassembler.ingest(fragment)
        if case .completed(let frame) = result {
            dbg("frame reassembled (keyframe=\(frame.keyframe)) → decoding")
            decode(frame)
        }
        // Drain any frames the reassembler declared unrecoverably lost and signal
        // recovery. First loss → prefer an LTR refresh; if an LTR refresh is already in
        // flight and no decodable frame has cleared it within 2·RTT, ESCALATE to a
        // forced IDR (doc 17 §3.6). The escalation is driven right here off the
        // loss-detection path — there is no separate timer.
        while let lost = reassembler.nextDroppedFrame() {
            if shouldEscalateToIDR() {
                requestIDR()
            } else {
                requestRecovery(lostFrameID: lost)
            }
        }
    }

    /// Whether a forced-IDR escalation is due: an LTR refresh is already outstanding
    /// (`lastRecoveryRequestTime` set, not yet cleared by a keyframe) and at least
    /// 2·RTT has elapsed since it (``RecoveryPolicy/shouldEscalateToIDR``).
    private func shouldEscalateToIDR() -> Bool {
        guard let requestedAt = lastRecoveryRequestTime else { return false }
        let elapsed = FramePacer.currentHostTimeSeconds() - requestedAt
        return recoveryPolicy.shouldEscalateToIDR(elapsedSinceRequest: elapsed, rtt: rttEstimate)
    }

    /// Updates the smoothed RTT estimate that gates the IDR-escalation timeout. Fed by
    /// the transport / control round-trip when a measurement is available; until then
    /// the conservative 50 ms default holds. Exposed for the GUI layer to drive.
    public func updateRTTEstimate(_ rtt: TimeInterval) {
        guard rtt > 0 else { return }
        // Simple EWMA so a single spike does not whipsaw the escalation timeout.
        rttEstimate = rttEstimate * 0.75 + rtt * 0.25
    }

    private func decode(_ frame: ReassembledFrame) {
        guard let decoder else { return }
        do {
            // The decoded NV12 size becomes the cursor-scale denominator.
            updateDecodedSize(from: frame)
            try decoder.decode(frame)
            dbgDecodeCount += 1
            if dbgDecodeCount == 1 || dbgDecodeCount % 15 == 0 {
                dbg("DECODED frame #\(dbgDecodeCount) (keyframe=\(frame.keyframe)) → submitted to pacer/render")
            }
            // A successful keyframe clears any in-flight recovery wait.
            if frame.keyframe { lastRecoveryRequestTime = nil }
        } catch VideoDecoderError.awaitingKeyframe {
            // A delta arrived before the first IDR — drop it and ask for a keyframe.
            dbg("decode: awaiting keyframe (delta dropped) → requesting IDR")
            requestIDR()
        } catch {
            log.error("decode failed: \(String(describing: error))")
            dbg("DECODE FAILED: \(String(describing: error))")
        }
    }

    private func updateDecodedSize(from frame: ReassembledFrame) {
        // The capture size negotiated in the helloAck is the authoritative frame size
        // (host window points). Keep it; the decoded CVPixelBuffer matches it.
        if decodedSize.width == 0 {
            decodedSize = stateMachine.captureSize
            reapplyCursor()
        }
    }

    private func applyGeometry(_ message: WindowGeometryMessage) {
        // Geometry move/resize affects the on-screen window the host view manages; the
        // orchestrator forwards size changes into the decoded-size baseline so the
        // cursor scale stays correct after a resize (a fresh IDR carries the new size).
        switch message {
        case .resize(let size):
            decodedSize = size
            reapplyCursor()
        case .bounds(let rect):
            decodedSize = rect.size
            reapplyCursor()
        case .move, .title:
            break
        }
    }

    // MARK: Inbound cursor (dedicated socket)

    private func receiveCursor(_ data: Data) async {
        guard stateMachine.mediaFlowing else { return }
        let message: CursorChannelMessage
        do { message = try CursorChannelMessage.decode(data) } catch {
            log.error("dropping malformed cursor datagram")
            return
        }
        switch message {
        case .update(let update):
            lastCursorUpdate = update
            applyCursor(update)
        case .shape(let shape):
            registerCursorShape(shape)
        }
    }

    private func applyCursor(_ update: CursorUpdate) {
        gui.applyCursor(update, videoScale) // hops to the main actor inside the hook
    }

    private func reapplyCursor() {
        if let update = lastCursorUpdate { applyCursor(update) }
    }

    private func registerCursorShape(_ shape: CursorShapeMessage) {
        // Decode the PNG bitmap to a CGImage and register it for its shapeID. CGImage
        // decode is cheap + safe (no window-server); only the layer wiring is GUI.
        guard let image = Self.decodePNG(shape.bitmap) else {
            log.error("failed to decode cursor shape \(shape.shapeID) PNG")
            return
        }
        gui.registerCursorShape(image, shape.shapeID)
        // Re-apply the last position so the newly-registered shape shows immediately.
        reapplyCursor()
    }

    // MARK: Outbound input (view → host)

    /// Forwards an already-built ``InputEvent`` to the host on the input channel.
    /// The view layer builds events via ``InputEventEncoder`` (normalised coords) and
    /// hands them here; sent fire-and-forget (UDP).
    public func sendInput(_ event: InputEvent) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(event.encode(), on: .input)
    }

    /// Convenience: normalise + send a pointer move in the layer's view space.
    public func sendMouseMove(viewPoint: VideoPoint) {
        sendInput(inputEncoder.mouseMove(viewPoint: viewPoint, layerSize: layerSize))
    }

    public func sendMouseDown(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        sendInput(inputEncoder.mouseDown(button: button, viewPoint: viewPoint, layerSize: layerSize, clickCount: clickCount, modifiers: modifiers))
    }

    public func sendMouseUp(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        sendInput(inputEncoder.mouseUp(button: button, viewPoint: viewPoint, layerSize: layerSize, clickCount: clickCount, modifiers: modifiers))
    }

    public func sendScroll(dx: Double, dy: Double, viewPoint: VideoPoint) {
        sendInput(inputEncoder.scroll(dx: dx, dy: dy, viewPoint: viewPoint, layerSize: layerSize))
    }

    public func sendKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        sendInput(inputEncoder.key(keyCode: keyCode, down: down, modifiers: modifiers))
    }

    public func sendText(_ string: String) {
        sendInput(inputEncoder.text(string))
    }

    // MARK: Recovery (client → host)

    private func requestRecovery(lostFrameID: UInt32) {
        // Prefer an LTR refresh over a forced IDR (doc 17 §3.6). Sent on the DEDICATED
        // `.recovery` channel — never `.input` — so the host does not mis-decode a
        // RecoveryMessage (type bytes 1/2/3) as a phantom InputEvent.
        let message = recoveryPolicy.initialRequest(lostFrom: lostFrameID, lostTo: lostFrameID)
        transport.send(message.encode(), on: .recovery)
        lastRecoveryRequestTime = FramePacer.currentHostTimeSeconds()
    }

    private func requestIDR() {
        transport.send(RecoveryMessage.requestIDR.encode(), on: .recovery)
        lastRecoveryRequestTime = FramePacer.currentHostTimeSeconds()
    }

    // MARK: Effects

    private func apply(_ effect: VideoClientStateMachine.Effect) async {
        switch effect {
        case .sendControl(let message):
            transport.send(message.encode(), on: .control)
        case .startDecodePipeline(let captureSize, _):
            startDecodePipeline(captureSize: captureSize)
        case .stopDecodePipeline:
            stopDecodePipeline()
        }
    }

    private func startDecodePipeline(captureSize: VideoSize) {
        decodedSize = captureSize
        // The decoder hands each decoded NV12 buffer to the pipeline-owned pacer (via
        // the GUI hook, most-recent-wins); the pacer renders it at the display link's
        // vsync. GUI-only — the decode path is never reached in a test.
        let submit = gui.submitDecodedFrame
        let decoder = VideoDecoder { imageBuffer in submit(imageBuffer) }
        self.decoder = decoder
        reapplyCursor()
        log.info("client decode pipeline up at capture \(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public)")
    }

    private func stopDecodePipeline() {
        decoder = nil
    }

    // MARK: PNG decode (cross-platform, no window-server)

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
