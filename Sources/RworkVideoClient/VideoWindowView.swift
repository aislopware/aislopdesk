#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import SwiftUI
import QuartzCore
import Metal
import CoreVideo
import RworkVideoProtocol

/// Connection parameters for a remote GUI window (PATH 2 / Phase 4, doc 17 §3): the
/// host endpoint + the window to remote. The GUI app builds this once it knows a host
/// is capturing a window and hands it to ``VideoWindowView``.
public struct VideoWindowConnection: Sendable, Equatable {
    /// The host's NetBird-routable address (or hostname).
    public var host: String
    /// The host media UDP port (control/video/geometry/input).
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port.
    public var cursorPort: UInt16
    /// The host CGWindowID to remote.
    public var windowID: UInt32

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16, windowID: UInt32) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
    }
}

/// A SwiftUI view that hosts the `CAMetalLayer` + cursor overlay for one remote GUI
/// window (doc 17 §3 PATH 2). It owns the Metal layer/view, builds the
/// ``MetalVideoRenderer`` + ``ClientCursorCompositor`` + ``RworkVideoClientSession``,
/// starts the orchestrator on appear and stops it on disappear, drives the decoded-
/// frame → renderer path through the ``FramePacer`` display link, and forwards input.
///
/// Each layout pass it computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / decoder / display link / sockets
/// needs a real device + screen + TCC. COMPILED + reviewed; not driven from tests.
/// This is the wiring point `RworkClientUI` injects via `VideoWindowFactory`.
public struct VideoWindowView: View {
    /// The remote window's title, shown for accessibility.
    public let title: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// The existing seam signature (title-only): renders the Metal-backed view chrome
    /// without a live connection. Kept so `VideoWindowFactory` callers compile.
    public init(title: String) {
        self.title = title
        self.connection = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`.
    public init(title: String, connection: VideoWindowConnection) {
        self.title = title
        self.connection = connection
    }

    public var body: some View {
        MetalVideoLayerView(connection: connection)
            .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

#if os(macOS)
/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?

    func makeNSView(context: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.activate(connection: connection)
        return view
    }

    func updateNSView(_ nsView: MetalLayerBackedView, context: Context) {
        nsView.activate(connection: connection)
    }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator: ()) {
        nsView.deactivate()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = videoLayer
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func makeBackingLayer() -> CALayer { videoLayer }

    func activate(connection: VideoWindowConnection?) {
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
    }
    func deactivate() { pipeline.deactivate() }

    override func layout() {
        super.layout()
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        return VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y))
    }
    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    override func mouseMoved(with event: NSEvent) { pipeline.mouseMove(viewPoint(event)) }
    override func mouseDragged(with event: NSEvent) { pipeline.mouseMove(viewPoint(event)) }
    override func mouseDown(with event: NSEvent) { pipeline.mouseDown(.left, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func mouseUp(with event: NSEvent) { pipeline.mouseUp(.left, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func rightMouseDown(with event: NSEvent) { pipeline.mouseDown(.right, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func rightMouseUp(with event: NSEvent) { pipeline.mouseUp(.right, viewPoint(event), UInt8(event.clickCount), mods(event)) }
    override func scrollWheel(with event: NSEvent) {
        pipeline.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), viewPoint: viewPoint(event))
    }
    override func keyDown(with event: NSEvent) {
        pipeline.key(keyCode: event.keyCode, down: true, modifiers: mods(event))
        if let chars = event.characters, !chars.isEmpty { pipeline.text(chars) }
    }
    override func keyUp(with event: NSEvent) {
        pipeline.key(keyCode: event.keyCode, down: false, modifiers: mods(event))
    }
    override var acceptsFirstResponder: Bool { true }

    /// AppKit only delivers `mouseMoved` when a tracking area requests it, and
    /// `acceptsFirstResponder` alone does NOT focus a bare layer-backed view inside a
    /// SwiftUI sheet — so without these two the cursor-follow + keyboard input paths are
    /// dead. Install/refresh a tracking area for the visible bounds, and grab first
    /// responder when the view enters a window.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> InputModifiers {
        var m: InputModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }
}

#elseif os(iOS)
import UIKit
/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?

    func makeUIView(context: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.activate(connection: connection)
        return view
    }
    func updateUIView(_ uiView: MetalLayerBackedView, context: Context) {
        uiView.activate(connection: connection)
    }
    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline. Adds VNC-style
/// pinch-to-zoom + one-finger pan (+ double-tap to reset) over the remote window.
final class MetalLayerBackedView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let pipeline = VideoWindowPipeline()

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var gestureBaseZoom: CGFloat = 1
    private var gestureBasePan: CGPoint = .zero
    private var gesturesInstalled = false

    func activate(connection: VideoWindowConnection?) {
        installGesturesIfNeeded()
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
    }
    func deactivate() { pipeline.deactivate() }

    private func installGesturesIfNeeded() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        isUserInteractionEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, pan, doubleTap] as [UIGestureRecognizer] { g.delegate = self; addGestureRecognizer(g) }
    }

    // Let pinch + pan run together (zoom while dragging).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureBaseZoom = zoom }
        zoom = min(max(gestureBaseZoom * g.scale, 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
    }
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureBasePan = pan }
        let t = g.translation(in: self)
        let invZoom = 1.0 / zoom
        pan.x = gestureBasePan.x - (t.x / max(bounds.width, 1)) * invZoom
        pan.y = gestureBasePan.y - (t.y / max(bounds.height, 1)) * invZoom
        pipeline.setZoom(zoom, pan: pan)
    }
    @objc private func onDoubleTap() {
        zoom = 1; pan = .zero
        pipeline.setZoom(zoom, pan: pan)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render at native Retina resolution: set the layer's contentsScale to the screen
        // scale so the pipeline's drawableSize (points × contentsScale) is the pixel size.
        videoLayer.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }
}
#endif
#endif
