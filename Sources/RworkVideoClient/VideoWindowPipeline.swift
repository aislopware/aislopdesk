#if canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import Foundation
import QuartzCore
import CoreVideo
import CoreGraphics
import OSLog
import RworkVideoProtocol
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The `@MainActor` glue that owns the GUI objects (``MetalVideoRenderer`` +
/// ``ClientCursorCompositor``) and the orchestrator (``RworkVideoClientSession``) for
/// one remote GUI window, and bridges layout + input from the platform backing view.
///
/// `VideoWindowView`'s `NSView`/`UIView` holds one of these. It is the single place
/// that constructs the live pipeline (renderer, compositor, transport, session) on
/// activate and tears it down on deactivate, computes the videoScale each layout pass,
/// and forwards input events to the host through the session.
///
/// ⚠️ **GUI-ONLY:** constructs a Metal renderer + UDP transport + orchestrator (which
/// brings up a `VTDecompressionSession` + display link). NEVER instantiated in a test.
@MainActor
final class VideoWindowPipeline {
    private let log = Logger(subsystem: "rwork.video.client", category: "VideoWindowPipeline")

    private var renderer: MetalVideoRenderer?
    private var compositor: ClientCursorCompositor?
    private var pacer: FramePacer?
    private var session: RworkVideoClientSession?
    private var activeConnection: VideoWindowConnection?
    private var layerSize: VideoSize = VideoSize(width: 0, height: 0)

    #if os(macOS)
    typealias HostView = NSView
    #elseif canImport(UIKit)
    typealias HostView = UIView
    #endif

    /// Brings up the pipeline against `connection`, attaching the display link to
    /// `view`. Idempotent: re-activating with the same connection is a no-op; a
    /// different connection tears the old one down first. `maxFrameRate` caps the GUI
    /// video path (~24-30fps; NOT a 60/120fps game stream).
    func activate(view: HostView, videoLayer: CAMetalLayer, connection: VideoWindowConnection?, maxFrameRate: Double = 30.0) {
        guard let connection else { return } // no live host: chrome only (placeholder owns the idle UI)
        if activeConnection == connection, session != nil { return }
        deactivate()
        activeConnection = connection

        guard let renderer = MetalVideoRenderer(metalLayer: videoLayer) else {
            log.error("MetalVideoRenderer init failed — no Metal device")
            return
        }
        let compositor = ClientCursorCompositor()
        videoLayer.addSublayer(compositor.cursorLayer)
        self.renderer = renderer
        self.compositor = compositor

        // The pacer pulls the newest decoded frame each vsync and renders it; the
        // render callback is main-confined (the renderer is `@MainActor`). The pacer's
        // callback is `@Sendable` and invoked on the display-link's main run loop.
        let pacer = FramePacer(maxFrameRate: maxFrameRate) { buffer in
            let box = UnsafeTransfer(buffer)
            Task { @MainActor in renderer.render(box.value) }
        }
        self.pacer = pacer

        // Initial viewport from the current layer size (≥1 so the hello carries a
        // sane size even before the first layout pass).
        let viewport = VideoSize(width: max(1, layerSize.width), height: max(1, layerSize.height))
        let transport = NWVideoClientTransport(host: connection.host, mediaPort: connection.mediaPort, cursorPort: connection.cursorPort)

        // GUI hooks: each hops to the main actor to touch the (main-confined) pacer /
        // compositor. The orchestrator actor calls these from its own executor.
        let gui = RworkVideoClientSession.GUIHooks(
            submitDecodedFrame: { buffer in
                // CVImageBuffer is a CoreVideo handle (not Sendable); after decode it is
                // read-only for our render path, so we ferry it across the isolation
                // boundary in an unchecked-Sendable box (the idiomatic escape hatch for
                // immutable CV/CG handles under strict concurrency). The pacer's submit
                // is internally locked, so the main hop only re-presents at vsync.
                pacer.submit(buffer)
            },
            applyCursor: { [weak compositor] update, placement in
                Task { @MainActor in
                    compositor?.apply(update, viewSize: placement.viewSize, videoNativeSize: placement.videoNativeSize, zoom: placement.zoom, pan: placement.pan)
                }
            },
            registerCursorShape: { [weak compositor] image, shapeID in
                let box = UnsafeTransfer(image)
                Task { @MainActor in compositor?.registerShape(box.value, for: shapeID) }
            }
        )

        let session = RworkVideoClientSession(
            requestedWindowID: connection.windowID,
            viewport: viewport,
            transport: transport,
            gui: gui
        )
        self.session = session

        // Start the display link (attached to the on-screen view) + the orchestrator.
        pacer.start(view: view)
        Task { try? await session.start() }
        let initialSize = layerSize
        Task { await session.setLayerSize(initialSize) }
    }

    /// Tears the pipeline + display link + sockets down (called on disappear/dismantle).
    func deactivate() {
        pacer?.stop()
        if let session {
            Task { await session.stop() }
        }
        compositor?.cursorLayer.removeFromSuperlayer()
        session = nil
        renderer = nil
        compositor = nil
        pacer = nil
        activeConnection = nil
    }

    /// Called each layout pass with the on-screen layer size (points). Updates the
    /// session's layer size, which recomputes `videoScale = layerSize / decodedSize`
    /// and re-places the cursor overlay.
    func layoutChanged(layerSize: VideoSize) {
        self.layerSize = layerSize
        // `layerSize` is in POINTS (the cursor/videoScale denominator stays in points). The
        // Metal DRAWABLE, however, must be sized in PIXELS — drawableSize = points ×
        // contentsScale — or the layer renders at 1× and the display upscales it to the Retina
        // screen, which looks badly BLURRED (the bug: drawableSize was set to the point size).
        if let layer = renderer?.metalLayer {
            let scale = layer.contentsScale > 0 ? layer.contentsScale : 1
            layer.drawableSize = CGSize(width: layerSize.width * scale, height: layerSize.height * scale)
        }
        guard let session else { return }
        Task { await session.setLayerSize(layerSize) }
    }

    /// VNC-style zoom/pan, forwarded to the renderer (applied as a UV crop next vsync)
    /// AND to the session, so the input encoder inverts — and the cursor overlay tracks —
    /// the EXACT SAME transform. Both must move together or a click while zoomed lands at
    /// the un-zoomed source position.
    func setZoom(_ zoom: CGFloat, pan: CGPoint) {
        renderer?.zoom = zoom
        renderer?.panNormalized = pan
        if let session {
            let z = Double(zoom)
            let p = VideoPoint(x: Double(pan.x), y: Double(pan.y))
            Task { await session.setZoom(z, pan: p) }
        }
    }

    // MARK: Input forwarding

    func mouseMove(_ viewPoint: VideoPoint) {
        guard let session else { return }
        Task { await session.sendMouseMove(viewPoint: viewPoint) }
    }
    func mouseDown(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        Task { await session.sendMouseDown(button: button, viewPoint: viewPoint, clickCount: clickCount, modifiers: modifiers) }
    }
    func mouseUp(_ button: MouseButton, _ viewPoint: VideoPoint, _ clickCount: UInt8, _ modifiers: InputModifiers) {
        guard let session else { return }
        Task { await session.sendMouseUp(button: button, viewPoint: viewPoint, clickCount: clickCount, modifiers: modifiers) }
    }
    func scroll(dx: Double, dy: Double, viewPoint: VideoPoint) {
        guard let session else { return }
        Task { await session.sendScroll(dx: dx, dy: dy, viewPoint: viewPoint) }
    }
    func key(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        guard let session else { return }
        Task { await session.sendKey(keyCode: keyCode, down: down, modifiers: modifiers) }
    }
    func text(_ string: String) {
        guard let session else { return }
        Task { await session.sendText(string) }
    }
}

/// Ferries a non-`Sendable` reference handle (a CoreVideo / CoreGraphics image buffer)
/// across an isolation boundary. SAFE here because the decoded `CVImageBuffer` and the
/// cursor `CGImage` are effectively immutable for the render / register path: the
/// decoder hands ownership to the pacer (most-recent-wins), and the renderer only
/// reads. This is the documented escape hatch for immutable CV/CG handles under strict
/// concurrency — NOT a license to mutate shared state.
struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
