#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import AislopdeskVideoProtocol
import CoreVideo
import Metal
import QuartzCore
import SwiftUI

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

/// Bridges the SwiftUI control overlay (fit/fill toggle + zoom reset) to the platform
/// backing view's pipeline. The backing view sets the `onToggle*` closures on `activate`
/// and publishes `mode`/`zoomed` so the overlay icons reflect live state. Deliberately a
/// SwiftUI overlay — NOT AppKit/UIKit subviews of the Metal view: adding subviews +
/// gesture recognizers to the layer-backed Metal view perturbed its geometry and swallowed
/// the `mouseUp` of a trackpad three-finger-drag (→ a stuck remote button). The overlay
/// touches none of that.
@preconcurrency
@MainActor
public final class VideoPaneControls: ObservableObject {
    @Published public var mode: VideoContentMode = .fit
    @Published public var zoomed: Bool = false
    var onToggleFill: () -> Void = {}
    var onResetZoom: () -> Void = {}
    public init() {}
    func toggleFill() { onToggleFill() }
    func resetZoom() { onResetZoom() }
}

/// A SwiftUI view that hosts the `CAMetalLayer` + cursor overlay for one remote GUI
/// window (doc 17 §3 PATH 2). It owns the Metal layer/view, builds the
/// ``MetalVideoRenderer`` + ``ClientCursorCompositor`` + ``AislopdeskVideoClientSession``,
/// starts the orchestrator on appear and stops it on disappear, drives the decoded-
/// frame → renderer path through the ``FramePacer`` display link, and forwards input.
///
/// Each layout pass it computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / decoder / display link / sockets
/// needs a real device + screen + TCC. COMPILED + reviewed; not driven from tests.
/// This is the wiring point `AislopdeskClientUI` injects via `VideoWindowFactory`.
public struct VideoWindowView: View {
    /// The remote window's title, shown for accessibility.
    public let title: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// Whether this pane is the active/focused pane on the canvas. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes scroll to ``onCanvasScroll`` (the
    /// "only the active pane swallows pointer" rule). Plain (non-isolated) closures + Bool so the
    /// `AppMain` factory can bridge them across the seam without importing `AislopdeskClientUI`.
    let isActive: Bool
    /// READ-ONLY INPUT GATE (E21 WI-3). `false` ⇒ this pane is read-only: forward NEITHER pointer/scroll
    /// NOR keycodes to the host. A click may still ACTIVATE the workspace pane (`onActivate`), but it is not
    /// relayed and the host window is not raised; the paste-as-keystrokes sink is also withheld. Gated with
    /// `isActive && inputEnabled` on every relay. Defaults `true` (a writable pane).
    let inputEnabled: Bool
    /// Make this pane active (set workspace focus) — called on click. The host window is also raised
    /// (via the pane's own `focusWindow`).
    let onActivate: () -> Void
    /// Pan the canvas when a NON-active pane is scrolled (so scroll over a background pane navigates the
    /// canvas instead of being swallowed by the remote window).
    let onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: ask the surrounding canvas pane to resize its VIDEO CONTENT from `current`
    /// to `target` points so the stream renders pixel-for-pixel (`target` = decoded pixels /
    /// contentsScale, fired on the first decoded frame and on host-side capture-size changes).
    /// `nil` ⇒ standalone window (no pane to snap) → the session keeps the legacy connect-time
    /// host-follow negotiation instead.
    let onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the backing view publishes a key-injection closure here once it exists
    /// (and `nil` on teardown), routed to `pipeline.key(...)` — the same secure-input-aware path the
    /// keyboard uses. `(keyCode, down, shift)`. `nil` ⇒ no canvas wants the sink (preview/standalone).
    let onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?
    /// RESIZE GRIP: the live view publishes a resize-drive closure here once its session exists (and
    /// `nil` on teardown), so the pane's bottom-right grip can drive an absolute host-window resize.
    /// The closure is `(phase, tx, ty)` — phase `0` = drag began, `1` = changed, `2` = ended; `tx`/`ty`
    /// are the cumulative drag translation in LOCAL pane points. `nil` ⇒ no canvas to receive the sink.
    let onResizeInjectorReady: ((((_ phase: UInt8, _ tx: Double, _ ty: Double) -> Void)?) -> Void)?

    /// The existing seam signature (title-only): renders the Metal-backed view chrome
    /// without a live connection. Kept so `VideoWindowFactory` callers compile.
    public init(title: String) {
        self.title = title
        connection = nil
        isActive = true
        inputEnabled = true
        onActivate = {}
        onCanvasScroll = { _ in }
        onStreamNativeSize = nil
        onKeyInjectorReady = nil
        onResizeInjectorReady = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`. `isActive` /
    /// `onActivate` / `onCanvasScroll` carry the canvas pane behaviour (active-only pointer + click-to-
    /// activate + non-active scroll-to-pan); they default to the standalone (always-active) values.
    public init(
        title: String,
        connection: VideoWindowConnection,
        isActive: Bool = true,
        inputEnabled: Bool = true,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
        onResizeInjectorReady: ((((_ phase: UInt8, _ tx: Double, _ ty: Double) -> Void)?) -> Void)? = nil,
    ) {
        self.title = title
        self.connection = connection
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
        self.onResizeInjectorReady = onResizeInjectorReady
    }

    /// Owns the control bridge for this view's lifetime; the backing view wires its closures.
    @StateObject private var controls = VideoPaneControls()

    public var body: some View {
        // FILL THE PANE. Without this frame the bare representable does not claim space, so it shrinks to a
        // small island and clicks across the rest of the pane miss it. Mirrors the proven terminal seam.
        // No control overlay any more: the ACTUAL-SIZE viewport auto-anchors to the window top-left and the
        // edge-pan navigates — there is no zoom to reset, so the old 1× button (which collided with the
        // resize grip) is gone.
        MetalVideoLayerView(
            connection: connection,
            controls: controls,
            isActive: isActive,
            inputEnabled: inputEnabled,
            onActivate: onActivate,
            onCanvasScroll: onCanvasScroll,
            onStreamNativeSize: onStreamNativeSize,
            onKeyInjectorReady: onKeyInjectorReady,
            onResizeInjectorReady: onResizeInjectorReady,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

#if os(macOS)
/// Env-gated (`AISLOPDESK_VIDEO_DEBUG`) stderr diagnostics for the remote-GUI VIEW layer (scroll routing +
/// isActive delivery) — the BUG-2 ground-truth probe. A non-active pane that logs `isActive=true` proves a
/// stale/sticky focus value; `isActive=false` with no pan proves a downstream scroll-routing problem.
func videoViewDbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("Aislopdesk[video.client.view]: \(message())\n".utf8))
}

/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE (E21 WI-3): `false` ⇒ the backing view forwards no pointer/scroll/keycode to the
    /// host (gated `isActive && inputEnabled`) and withholds the paste-as-keystrokes sink. Set on every render.
    var inputEnabled: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    var onResizeInjectorReady: ((((UInt8, Double, Double) -> Void)?) -> Void)?

    func makeNSView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.onActivate = onActivate
        view.onCanvasScroll = onCanvasScroll
        view.onStreamNativeSize = onStreamNativeSize // before activate — its nil-ness picks snap vs host-follow
        view.activate(connection: connection)
        // PASTE AS KEYSTROKES: publish a key-injection sink routed to THIS view's pipeline (the
        // `pipeline.key` guard no-ops until the session is up, so publishing now is safe). The
        // backing view clears it on `deactivate`.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        // RESIZE GRIP: publish a resize-drive sink routed to THIS view's pipeline (the session's
        // resize guard no-ops until streaming, so publishing now is safe). Cleared on `deactivate`.
        view.onResizeInjectorReady = onResizeInjectorReady
        view.publishResizeInjector()
        // BUG-2 probe: a recreate (makeNSView) on focus change — vs an in-place updateNSView — would reset
        // isActive to its `true` default mid-stream; logging it distinguishes "stale Bool" from "recreate".
        videoViewDbg("makeNSView (CREATED) isActive=\(isActive)")
        return view
    }

    func updateNSView(_ nsView: MetalLayerBackedView, context _: Context) {
        nsView.controls = controls
        if nsView.isActive != isActive { videoViewDbg("updateNSView isActive \(nsView.isActive)→\(isActive)") }
        nsView.isActive = isActive
        // READ-ONLY INPUT GATE (E21 WI-3): apply the current gate every render. On a FLIP, re-publish the
        // paste-as-keystrokes sink so the seam's `onKeyInjectorReady` (which binds a nil sink while read-only)
        // re-evaluates — locking a live pane withholds the sink, unlocking restores it, with no view rebuild.
        let inputGateFlipped = nsView.inputEnabled != inputEnabled
        nsView.inputEnabled = inputEnabled
        nsView.onActivate = onActivate
        nsView.onCanvasScroll = onCanvasScroll
        nsView.onStreamNativeSize = onStreamNativeSize
        nsView.activate(connection: connection)
        if inputGateFlipped {
            nsView.onKeyInjectorReady = onKeyInjectorReady
            nsView.publishKeyInjector()
            // RESIZE GRIP: the seam binds a nil resize sink while read-only (like the key sink), so a
            // read-only flip must re-publish to withdraw / restore the grip's drive.
            nsView.onResizeInjectorReady = onResizeInjectorReady
            nsView.publishResizeInjector()
        }
    }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator _: ()) {
        nsView.deactivate()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

    /// Whether THIS pane is the canvas's active/focused pane. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes a scroll to ``onCanvasScroll`` (so
    /// scroll navigates the canvas) and ignores hover, matching the terminal pane's `isFocusedPane` rule.
    /// Set by `MetalVideoLayerView` on every render (reactive to focus changes). On change it re-applies
    /// the local cursor — a pane losing focus must drop the host shape back to the arrow even if the
    /// pointer never moved.
    var isActive: Bool = true { didSet { applyLocalCursor() } }

    /// READ-ONLY INPUT GATE (E21 WI-3). `false` ⇒ this pane is read-only: every pointer/scroll/keycode relay
    /// to the host is suppressed (gated `isActive && inputEnabled`; a drag/up forward checks `inputEnabled`
    /// alone since it only follows a `mouseDown` that already passed the gate). A click still ACTIVATES the
    /// workspace pane but is not relayed and the host window is not raised. The paste-as-keystrokes sink is
    /// withheld by the seam (a `nil` `keyInjector`). Set by `MetalVideoLayerView` on every render.
    var inputEnabled: Bool = true

    // ── CURSOR (Parsec model): the host streams its cursor SHAPE (cached bitmaps); the OS draws that
    //    shape on the LOCAL cursor at the INSTANT mouse position — zero added latency, and exactly ONE
    //    cursor because macOS does NOT composite the host's RTT-delayed POSITION overlay. While the
    //    pointer is inside an ACTIVE pane and the host cursor is visible we set the host's shape; in a
    //    `.fit` letterbox margin / host-hidden-cursor / a background pane we keep the plain arrow.
    //    `pointerInside` gates the work to when the pointer is actually over this view.
    private var pointerInside = false
    /// Make this pane the active pane — called at the top of `mouseDown` (click-to-activate). Sets the
    /// *workspace* focus; the host window is raised separately via `pipeline.focusWindow()`.
    var onActivate: () -> Void = {}
    /// Pan the canvas by a (sign-adjusted) delta — called from `scrollWheel` when this pane is NOT active.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    /// 1:1 PANE SNAP: ask the canvas pane to resize its video content from `current` to `target`
    /// points so the stream renders pixel-for-pixel. `nil` ⇒ standalone (no pane). Set by the
    /// representable BEFORE ``activate(connection:)`` — its nil-ness picks pane-follows-stream
    /// vs the legacy connect-time host-follow when the session's GUI hooks are built.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the canvas publishes a key-injection sink through this (and `nil` on
    /// teardown), so the pane's "Paste as Keystrokes" can drive `pipeline.key(...)` — the same
    /// secure-input-aware key path the keyboard uses. Set by the representable before `activate`.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    /// RESIZE GRIP: the canvas publishes a resize-drive sink through this (and `nil` on teardown), so the
    /// pane's bottom-right grip can drive an absolute host-window resize. `(phase, tx, ty)` — phase `0`
    /// began / `1` changed / `2` ended; `tx`/`ty` = cumulative drag translation in LOCAL pane points.
    var onResizeInjectorReady: ((((UInt8, Double, Double) -> Void)?) -> Void)?

    /// Hands the canvas a key-injection closure routed to THIS view's pipeline (Shift folded into the
    /// modifiers; `pipeline.key` no-ops until the session is up). Idempotent — safe to call on every
    /// render; the sink captures `self` weakly so a torn-down view injects nothing.
    func publishKeyInjector() {
        onKeyInjectorReady? { [weak self] keyCode, down, shift in
            self?.pipeline.key(keyCode: keyCode, down: down, modifiers: shift ? .shift : [])
        }
    }

    /// Hands the canvas a resize-drive closure routed to THIS view's pipeline. Phase `0` snapshots the
    /// drag base; `1`/`2` forward the cumulative translation (the session maps it to an absolute target
    /// and debounce-requests the resize). `self` weak so a torn-down view resizes nothing.
    func publishResizeInjector() {
        onResizeInjectorReady? { [weak self] phase, tx, ty in
            guard let self else { return }
            switch phase {
            case 0: pipeline.userResizeBegan()
            case 2: pipeline.userResize(translationX: tx, translationY: ty, final: true)
            default: pipeline.userResize(translationX: tx, translationY: ty, final: false)
            }
        }
    }

    /// Bridge to the SwiftUI control overlay; the SwiftUI view owns it. Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?

    // ── ACTUAL-SIZE VIEWPORT (RealVNC-mobile, 2026-06-30). The host sends + the client decodes the WHOLE
    //    window every frame; the renderer draws the whole window at its native resolution into `videoLayer`,
    //    which is sized to the window's POINT size and added as a SUBLAYER of this view's clipping backing
    //    layer. The pane is a fixed viewport: we PAN by translating `videoLayer` (a compositor move — smooth,
    //    no per-frame reshader) instead of cropping the texture. Edge-hover drives the translation. The
    //    visible sub-rect is reported to the session as a `viewportCrop` so a pane click maps to the right
    //    host pixel. Window point size arrives via `onDecodedPointsChanged`.
    /// The host window's current POINT size. `nil` until the first decoded frame (then the layer is sized).
    private var streamPoints: VideoSize?
    /// The viewport's top-left offset INTO the window, in WINDOW POINTS (top-left origin, +y down). `(0,0)`
    /// = the window's top-left corner (default). Clamped to `[0, max(0, window − pane)]`; pan moves it.
    private var panOffset: CGPoint = .zero
    /// Whether the user has explicitly PANNED (edge-pan). Until then the offset stays at the window top-left
    /// (the default anchor, not centred); the 1× reset clears it.
    private var viewportTouched = false

    // ── EDGE-PAN (RealVNC-mobile): nudging the pointer into a pane edge auto-translates the video layer
    //    toward that edge so you can reach off-screen window content without a scroll gesture. Driven by a
    //    `.common`-mode timer (a default-mode timer would freeze during event tracking). Inert when the
    //    window fits inside the pane.
    private var edgePanTimer: Timer?
    private var edgePanVelocity: CGPoint = .zero
    /// Last pointer position in this view's coordinates (AppKit, origin bottom-left) — re-forwarded each
    /// edge-pan tick so the host cursor follows into the newly revealed region while the content scrolls.
    private var lastPointerView: CGPoint = .zero
    /// Pane-edge band width (points) within which the pointer triggers an auto-pan.
    private static let edgePanThreshold: CGFloat = 44
    /// Full-penetration pan speed (WINDOW POINTS per second) at the pane border.
    private static let edgePanPointsPerSec: Double = 1600

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The video layer is an oversized SUBLAYER (sized to the whole remote window) of a CLIPPING backing
        // layer, so we can translate it for panning while the pane masks the overflow. (It used to BE the
        // backing layer, filling the pane.)
        wantsLayer = true
        let host = CALayer()
        host.masksToBounds = true
        host.addSublayer(videoLayer)
        layer = host
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func activate(connection: VideoWindowConnection?) {
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate: the session decides pane-follows-stream
        // (snap) vs the legacy connect-time host-follow by whether this hook exists when the GUI
        // hooks are built. The closure reads the live `onStreamNativeSize`, so updateNSView
        // refreshing the seam closure stays picked up without re-activation.
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // Re-apply the local cursor when the host SWAPS shape, or when the host cursor enters/leaves the
        // captured window (visible flip) — so the pointer shape tracks the remote with no RTT lag.
        pipeline.onServerCursorVisibilityChanged = { [weak self] _ in self?.applyLocalCursor() }
        pipeline.onRemoteCursorChanged = { [weak self] in self?.applyLocalCursor() }
        // ACTUAL-SIZE VIEWPORT: learn the host window's point size, size the video layer to it, lay out.
        pipeline.onDecodedPointsChanged = { [weak self] points in
            guard let self else { return }
            streamPoints = points
            needsLayout = true
            layoutVideoLayer()
        }
        // Wire the SwiftUI overlay's buttons to THIS view's pipeline (live connection only). The fit/fill
        // toggle was removed (the ACTUAL-SIZE viewport auto-drives content mode), so only the 1× reset wires.
        if connection != nil, let controls {
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    func deactivate() {
        if pointerInside { NSCursor.arrow.set() } // restore the arrow before the pipeline tears down
        pointerInside = false
        onKeyInjectorReady?(nil) // PASTE AS KEYSTROKES: drop the stale sink before teardown
        onResizeInjectorReady?(nil) // RESIZE GRIP: drop the stale sink before teardown
        pipeline.deactivate()
    }

    /// 1:1 PANE SNAP: the stream's decoded size changed (first frame, or the host re-captured
    /// after a window resize). The session already converted it to the HOST WINDOW's POINT size
    /// (`points`, = decoded pixels / the inferred host captureScale — NOT the client contentsScale,
    /// which halved the pane on a 1× capture). Rebase the session's resize debounce on it FIRST
    /// (so the snap-induced layout pass holds instead of echoing a `resizeRequest` back to the
    /// host — the snap is client-side only), then ask the canvas pane to adopt it. Skips the pane
    /// mutation for a sub-half-point delta (already at the native size; the rebase alone suffices).
    private func adoptStreamNativePoints(_ points: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        pipeline.adoptLayerSize(points)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: points, current: current) else { return }
        videoViewDbg(
            "1:1 snap → video \(Int(current.width))x\(Int(current.height)) → \(Int(points.width))x\(Int(points.height))pt (host window points)",
        )
        handler(
            CGSize(width: points.width, height: points.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    // MARK: Local cursor (Parsec model — host shape on the instant local pointer)

    /// Sets the local OS cursor to the host's CURRENT shape while the pointer is inside an ACTIVE pane
    /// and the host cursor is visible there; otherwise the plain arrow. The OS draws it at the live mouse
    /// position so there's no RTT lag, and macOS composites no host-position overlay so there's no
    /// duplicate. No-op unless the pointer is over this view (so a shape swap elsewhere can't hijack the
    /// global cursor).
    private func applyLocalCursor() {
        guard pointerInside else { return }
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func layout() {
        super.layout()
        layer?.masksToBounds = true // clip the oversized video sublayer to the pane
        layoutVideoLayer()
        // session.layerSize = the PANE point size (the input/cursor denominator). The DRAWABLE pixel size is
        // owned by `layoutVideoLayer()` (window-sized), so the pipeline no longer touches it.
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }

    /// ACTUAL-SIZE VIEWPORT: size + position the oversized video sublayer. It is sized to the remote
    /// window's POINT size (so the renderer draws the WHOLE window at native res into a window-sized
    /// drawable), and positioned so the visible pane shows the region at `panOffset` (top-left anchored by
    /// default). Pure compositor geometry — panning later just moves this layer, no reshader. Falls back to
    /// filling the pane until the window size is known.
    private func layoutVideoLayer() {
        // layer-HOSTING views (we assign `layer`) are NOT auto-promoted to the window's backing scale, so set
        // contentsScale from `backingScaleFactor` (never hardcode 2 — 1× externals/Sidecar); fall back to the
        // last good value so a window==nil teardown layout never drops to 1×.
        let scale = window?.backingScaleFactor ?? videoLayer.contentsScale
        layer?.contentsScale = scale
        videoLayer.contentsScale = scale
        // No implicit position/size animation — panning sets these directly each tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let win = streamPoints, win.width > 1, win.height > 1, bounds.width > 1, bounds.height > 1 else {
            // No stream geometry yet → fill the pane (the renderer aspect-fits the first frames).
            videoLayer.frame = bounds
            videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return
        }
        let ww = CGFloat(win.width), wh = CGFloat(win.height)
        // Clamp the pan offset to the overflow on each axis (0 when the window fits → top-left anchored).
        let maxX = Swift.max(0, ww - bounds.width)
        let maxY = Swift.max(0, wh - bounds.height)
        if !viewportTouched { panOffset = .zero }
        panOffset.x = Swift.min(Swift.max(panOffset.x, 0), maxX)
        panOffset.y = Swift.min(Swift.max(panOffset.y, 0), maxY)
        // Position (parent layer is bottom-left origin): origin.x = −panOffset.x; origin.y places the window
        // TOP at the pane top and reveals lower content as panOffset.y grows (derived for y-down panOffset).
        videoLayer.frame = CGRect(x: -panOffset.x, y: bounds.height - wh + panOffset.y, width: ww, height: wh)
        videoLayer.drawableSize = CGSize(width: ww * scale, height: wh * scale)
        publishInputViewport()
    }

    /// Report the currently-visible texture sub-rect (UV) to the session so a pane click maps to the right
    /// host pixel. `origin = panOffset / window`, `size = pane / window` (size may exceed 1 when the window
    /// is smaller than the pane — `normalize` then clamps a click outside the window, which is correct).
    private func publishInputViewport() {
        guard let win = streamPoints, win.width > 1, win.height > 1 else { pipeline.setInputViewport(nil)
            return
        }
        pipeline.setInputViewport(VideoRect(
            x: Double(panOffset.x) / win.width,
            y: Double(panOffset.y) / win.height,
            width: Double(bounds.width) / win.width,
            height: Double(bounds.height) / win.height,
        ))
        controls?.zoomed = viewportTouched
    }

    /// Fires on window-attach and when the view moves between Retina/non-Retina displays.
    /// Re-syncs the hosted layer's scale and re-lays-out so the drawable is sized for the new
    /// backing scale (the initial scale is set in `layout()`; this keeps it correct across moves).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil else { return } // can fire with window==nil during teardown
        videoLayer.contentsScale = window?.backingScaleFactor ?? videoLayer.contentsScale
        needsLayout = true
    }

    // MARK: Local navigation (pan) — responder methods, never gesture recognizers

    /// Trackpad pinch is unused in the ACTUAL-SIZE viewport (the window already shows at its native size;
    /// the pane is a fixed viewport you pan, not a zoom surface). Left as a no-op so a stray pinch can't
    /// perturb geometry. (Edge-hover does the navigation.)
    override func magnify(with _: NSEvent) {}

    /// 1× reset → re-anchor the viewport to the window's TOP-LEFT.
    private func applyResetZoom() {
        viewportTouched = false
        panOffset = .zero
        stopEdgePan()
        needsLayout = true
        layoutVideoLayer()
    }

    /// Whether there is window content beyond the pane to pan to (the window is larger than the pane on at
    /// least one axis). Gates edge-pan.
    private var isNavigable: Bool {
        guard let win = streamPoints else { return false }
        return win.width > Double(bounds.width) + 1 || win.height > Double(bounds.height) + 1
    }

    // MARK: Edge-pan (translate the oversized video layer when the pointer hugs a pane edge)

    /// Recompute the edge-pan velocity from the pointer's distance to each edge and (re)arm/stop the
    /// drive timer. `p` is in this view's coordinates (AppKit, origin bottom-left). Inert when the window
    /// fits the pane.
    private func updateEdgePan(at p: CGPoint) {
        lastPointerView = p
        edgePanVelocity = computeEdgePanVelocity(at: p)
        if edgePanVelocity == .zero {
            stopEdgePan()
        } else if edgePanTimer == nil {
            // `.common` mode so the timer keeps firing during mouse-tracking / gesture runloop modes.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepEdgePan() }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgePanTimer = timer
        }
    }

    private func stopEdgePan() {
        edgePanVelocity = .zero
        edgePanTimer?.invalidate()
        edgePanTimer = nil
    }

    /// Signed pan velocity (WINDOW POINTS/sec) for a pointer at `p`. Each axis ramps linearly from 0 at the
    /// band's inner edge to ``edgePanPointsPerSec`` at the pane border. Sign is in the `panOffset` basis
    /// (top-left, y-down): right edge → +x (reveal right); the view's BOTTOM (small AppKit y) → +y (reveal
    /// the window's bottom).
    private func computeEdgePanVelocity(at p: CGPoint) -> CGPoint {
        guard isNavigable, bounds.width > 1, bounds.height > 1 else { return .zero }
        let t = Self.edgePanThreshold
        let maxV = Self.edgePanPointsPerSec
        func ramp(_ depth: CGFloat) -> Double { min(max(Double(depth) / Double(t), 0), 1) * maxV }
        var v = CGPoint.zero
        if p.x < t { v.x = -ramp(t - p.x) } else if p.x > bounds.width - t { v.x = ramp(p.x - (bounds.width - t)) }
        if p.y < t { v.y = ramp(t - p.y) } else if p.y > bounds.height - t { v.y = -ramp(p.y - (bounds.height - t)) }
        return v
    }

    /// One 60 Hz edge-pan step: advance ``panOffset`` (window points) by `velocity · dt`, clamp to the
    /// overflow `[0, window − pane]`, re-lay-out the video layer (a compositor translate), and re-forward
    /// the (edge-pinned) pointer so the host cursor walks into the revealed region.
    private func stepEdgePan() {
        guard isNavigable, edgePanVelocity != .zero, let win = streamPoints else { stopEdgePan()
            return
        }
        let dt = 1.0 / 60.0
        let maxX = Swift.max(0, win.width - Double(bounds.width))
        let maxY = Swift.max(0, win.height - Double(bounds.height))
        let nx = min(max(Double(panOffset.x) + Double(edgePanVelocity.x) * dt, 0), maxX)
        let ny = min(max(Double(panOffset.y) + Double(edgePanVelocity.y) * dt, 0), maxY)
        let xDone = edgePanVelocity
            .x == 0 || (edgePanVelocity.x < 0 && nx <= 0) || (edgePanVelocity.x > 0 && nx >= maxX)
        let yDone = edgePanVelocity
            .y == 0 || (edgePanVelocity.y < 0 && ny <= 0) || (edgePanVelocity.y > 0 && ny >= maxY)
        panOffset = CGPoint(x: nx, y: ny)
        viewportTouched = true // explicit edge-pan → stop re-anchoring to top-left
        layoutVideoLayer() // compositor translate (smooth) + republish input viewport
        if isActive, inputEnabled {
            pipeline.mouseMove(VideoPoint(x: Double(lastPointerView.x), y: Double(bounds.height - lastPointerView.y)))
        }
        if xDone, yDone { stopEdgePan() }
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        return VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y))
    }

    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    /// Clamps `NSEvent.clickCount` (an unbounded `Int` — AppKit keeps incrementing it for consecutive
    /// in-place clicks within the double-click interval) into the wire `UInt8`. `UInt8(clamping:)`
    /// saturates at 255 instead of the trapping `UInt8(Int)` that would crash the client on a 256th rapid
    /// click; identical for every real 1/2/3-click, and the host only uses it as a click-state hint
    /// (`max(1, Int(clickCount))`), so saturating is harmless (R14).
    nonisolated static func clampClickCount(_ n: Int) -> UInt8 { UInt8(clamping: n) }

    // Only the ACTIVE pane tracks hover (the "only the active pane swallows pointer" rule). A non-active
    // pane ignores hover so it never injects a stray remote mouse-move; you must click it first.
    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        // Edge-pan is local view-nav (moves the zoomed crop) — runs even on a read-only pane; inert at 1×.
        updateEdgePan(at: convert(event.locationInWindow, from: nil))
        guard inputEnabled else { return } // read-only ⇒ no remote mouse-move (E21 WI-3)
        pipeline.mouseMove(viewPoint(event))
    }

    // A drag (a button is HELD) is a DISTINCT NSView callback from a hover `mouseMoved`, so the
    // client KNOWS which button is down and forwards an explicit `.mouseDrag`; the host posts
    // the matching `*MouseDragged` STATELESSLY — no host-side held-button guess. NOT gated on
    // `isActive`: a drag only follows a `mouseDown` on THIS pane, which already activated it, so the
    // in-gesture frames must keep flowing even before SwiftUI re-renders `isActive` true.
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag (E21 WI-3)
        pipeline.mouseDrag(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag (E21 WI-3)
        pipeline.mouseDrag(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    // CLICK = ACTIVATE: a mouseDown makes this the active pane (`onActivate` → workspace focus) AND
    // raises the host window to top (`focusWindow`), THEN lands as a remote click. This is the
    // "click to activate + raise GUI window on click" model (replaces the earlier hover-raise). The
    // activating click is always forwarded so clicking a control in a background window just works.
    override func mouseDown(with event: NSEvent) {
        // BUG-1 probe: clicking is the reported freeze trigger. Correlate this line with `cursorAPPLY`/
        // `RENDER` gaps (client main-actor block from focus()) and `mediaRX` gaps (host capture hitch on
        // window-raise) to see which path stalls on a click.
        videoViewDbg("click → activate isActive=\(isActive)")
        onActivate()
        // READ-ONLY (E21 WI-3): a locked pane still ACTIVATES (workspace focus, above), but the click is NOT
        // relayed to the host and the host window is NOT raised — the pane is view-only.
        guard inputEnabled else { return }
        // Send the host window-raise ONLY when (re)activating an UNfocused pane — not on every click of
        // an already-active pane. The host raise is best-effort + costly (AX IPC); re-raising on each
        // click of the focused pane is wasted work (the host throttles redundant raises as a backstop).
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click (E21 WI-3)
        pipeline.mouseUp(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate()
        guard inputEnabled else { return } // read-only ⇒ activate only, no remote relay (E21 WI-3)
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click (E21 WI-3)
        pipeline.mouseUp(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    /// Maps a finger-on-glass `NSEvent.phase` to its `CGScrollPhase` integer code so the host can set
    /// `kCGScrollWheelEventScrollPhase` verbatim (`0`=none, `1`=began, `2`=changed, `4`=ended,
    /// `8`=cancelled, `128`=mayBegin). `.stationary`/empty → `0`.
    static func cgScrollPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        if phase.contains(.mayBegin) { return 128 }
        return 0
    }

    /// Maps an inertial-coast `NSEvent.momentumPhase` to its `CGMomentumScrollPhase` integer code
    /// (`0`=none, `1`=begin, `2`=continue, `3`=end) — a SEPARATE encoding from `cgScrollPhaseCode`.
    static func cgMomentumPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 3 }
        return 0
    }

    override func scrollWheel(with event: NSEvent) {
        // ACTUAL-SIZE viewport: a two-finger scroll FORWARDS to the remote (scrolls the editor) — it is NOT
        // hijacked to pan the viewport. Moving the viewport is the EDGE-PAN's job (hover-to-edge, RealVNC
        // model). So there is no local crop-pan branch here.
        //
        // SCROLL ROUTING — gated on EXPLICIT canvas focus (`isActive == store.isFocused(id)`),
        // the desktop model the user asked for ("khi focus vào pane gui rồi, pane gui phải nuốt scroll"):
        //   • FOCUSED pane   → forward the scroll to the REMOTE window (you clicked in, you're scrolling
        //     its content). Forwarding is a UDP send — no `@Observable` mutation, so it never blocks the
        //     stream. Mirrors the terminal pane's focused-scrollback rule.
        //   • UNFOCUSED pane → PAN THE CANVAS, never swallow — so panning across a background pane keeps
        //     navigating instead of stopping at its edge. Routed through the debounced `onCanvasScroll`
        //     accumulator (NOT a per-step commitCamera), so it never blocks the stream either.
        //   • ⌥ held         → ALWAYS pan the canvas, even while focused (escape hatch to pan a focused
        //     pane without first unfocusing it).
        // Natural-scroll sign matches `CanvasView.PanView` so a pane-pan feels identical to the bg pan.
        // READ-ONLY (E21 WI-3): a locked focused pane does NOT swallow the scroll into the remote window —
        // `inputEnabled == false` falls through to the canvas-pan branch (view-only, no host relay).
        if isActive, inputEnabled, !event.modifierFlags.contains(.option) {
            videoViewDbg("scroll → remote (focused)")
            // Forward the trackpad gesture state so the host can replay a native continuous/inertial
            // scroll (Began→Changed→Ended, then momentum Begin→Continue→End) instead of a phase-less
            // wheel tick. `event.phase` (finger-on-glass) and `event.momentumPhase` (coast) are
            // distinct and mutually exclusive; map each to its CoreGraphics integer code.
            pipeline.scroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                viewPoint: viewPoint(event),
                scrollPhase: Self.cgScrollPhaseCode(event.phase),
                momentumPhase: Self.cgMomentumPhaseCode(event.momentumPhase),
                continuous: event.hasPreciseScrollingDeltas,
            )
            return
        }
        let dx: CGFloat, dy: CGFloat
        if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else { dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        videoViewDbg("scroll → canvas pan d=(\(Int(-dx)),\(Int(-dy))) isActive=\(isActive)")
        onCanvasScroll(CGSize(width: -dx, height: -dy))
    }

    // ALL keys (printable + special) go through the layout-level keycode `.key` path so
    // the HOST's keyboard layout + input method (e.g. OpenKey/xkey Telex) interpret and
    // COMPOSE them server-side — exactly like Parsec/VNC/Screen-Sharing "scancode mode".
    // The old `.text` path posted a virtualKey-0 CGEvent + keyboardSetUnicodeString, which
    // is invisible to an IME's keycode-driven composer (OpenKey reads only the virtual
    // keycode + shift/caps flag, never the event's Unicode string), so the pre-baked glyph
    // rode straight through and Vietnamese never composed (`tieesng` inserted literally).
    // Forwarding the real keycode + modifier flags lets the host IME compose normally.
    //
    // We send ONLY `.key` per keypress (never `.key` + `.text` together) — sending both was
    // the old duplicate-character bug, because the host injects a char from EACH path.
    // The `.text` / pipeline.text(...) / host `postText` plumbing stays in place (now unused
    // by live typing) for future layout-independent input such as clipboard paste.
    // WS-B / B6 — WORKSPACE PREFIX over the video pane.
    //
    // The tmux/zellij prefix (⌃A by default) MUST NOT leak to the remote host when it is meant to arm a
    // LOCAL workspace command. That interception happens UPSTREAM of this responder: the app-level
    // `WorkspaceKeyDispatcher` (B3) installs ONE `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` at
    // launch, which fires BEFORE the first responder — so a prefix arm / resolved chord / send-prefix
    // double-tap is consumed (the handler returns `nil`) and this `keyDown` is NEVER reached for those
    // keystrokes. A bare/unmodified key returns from the monitor unchanged and lands here, where it is
    // forwarded to the host as normal typing — exactly the intended behaviour.
    //
    // No thin pre-check is mirrored here (unlike B4's libghostty surface) ON PURPOSE: the
    // `TerminalKeyInterceptor` lives in `AislopdeskWorkspaceCore`, and `AislopdeskVideoClient` depends ONLY
    // on `AislopdeskVideoProtocol` (Package.swift) — importing WorkspaceCore here would invert the module
    // graph (the HARD RULE keeps these layers separated). The B4 belt-and-suspenders pass exists because the
    // libghostty surface is hosted INSIDE the WorkspaceCore-importing app target and can reach the engine;
    // this gated video surface cannot, and does not need to — the monitor already covers it. (Gated module:
    // never instantiated in tests; verified by REVIEW per the brief.)
    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward (E21 WI-3)
        pipeline.key(keyCode: event.keyCode, down: true, modifiers: mods(event))
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward (E21 WI-3)
        pipeline.key(keyCode: event.keyCode, down: false, modifiers: mods(event))
    }

    // Modifier press/release. Without this, ⌘/⇧/⌃/⌥ are NEVER sent as discrete key
    // events — they only ride as per-event flags on key/mouse events. On the host
    // `postKey` posts a CGEvent whose flags come from those per-event mods, but the
    // shared `CGEventSource(stateID:.hidSystemState)` LATCHES modifier state: a ⌘ flag
    // injected on (say) Delete with no matching modifier KEY-UP stays latched and
    // corrupts every later `.text` insertion (e.g. ⌘+Delete then a stuck ⌘ turns the
    // next Return into a newline-with-⌘). Emitting the real modifier key-up here posts a
    // CGEvent that clears the latched flag. (`pipeline.key` already carries
    // keyCode+down+modifiers — no protocol change.)
    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no modifier key-event forward (E21 WI-3)
        guard let down = Self.modifierDown(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        pipeline.key(keyCode: event.keyCode, down: down, modifiers: mods(event))
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
            // `.mouseEnteredAndExited` tracks whether the pointer is in the pane; `.cursorUpdate` makes
            // AppKit call `cursorUpdate(with:)` on each move so we re-assert the host's cursor shape.
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        pointerInside = true
        applyLocalCursor()
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        stopEdgePan() // pointer left the pane → stop auto-scrolling the crop
        NSCursor.arrow.set() // leaving the pane → restore the normal pointer
    }

    /// AppKit's per-move cursor callback while the pointer is in the pane: re-assert the host shape (or
    /// fall through to AppKit's default arrow) so a transient `.set()` from elsewhere can't win on a move.
    override func cursorUpdate(with event: NSEvent) {
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            super.cursorUpdate(with: event) // AppKit already set the window's default (arrow) pre-callback
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // FOCUS-STEALING FIX: only grab first responder when THIS pane is the ACTIVE one and we are not
        // already the responder. An unconditional makeFirstResponder on every NSView mount let the
        // LAST-mounted video pane steal the keyboard regardless of workspace focus (and thrash the
        // responder on tab switches). Mirrors the terminal pane's `isFocusedPane` guard.
        guard isActive, let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Restore the arrow when the view leaves its window (drag-out / pane close): a teardown that skipped
    /// `mouseExited` must not leave a stale host-shape cursor set.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { if pointerInside { NSCursor.arrow.set() }
            pointerInside = false
            stopEdgePan() // teardown — never leave a timer firing on a detached view
        }
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

    /// Pure: decide whether a `flagsChanged` keyCode is a modifier press (`down`) or a
    /// release. `flagsChanged` fires for BOTH edges with the same keyCode; the only way
    /// to tell them apart is to ask whether the corresponding modifier is still present
    /// in `flags` after the event. Returns `nil` for a keyCode that is not a known
    /// modifier (so the caller sends nothing). Factored out so the keyCode→modifier-mask
    /// mapping is unit-testable without an `NSEvent`.
    static func modifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        switch Int(keyCode) {
        case 55,
             54: flags.contains(.command) // ⌘ left / right
        case 56,
             60: flags.contains(.shift) // ⇧ left / right
        case 59,
             62: flags.contains(.control) // ⌃ left / right
        case 58,
             61: flags.contains(.option) // ⌥ left / right
        case 57: flags.contains(.capsLock) // ⇪
        case 63: flags.contains(.function) // fn
        default: nil
        }
    }
}

#elseif os(iOS)
import UIKit

/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    // Accepted for signature parity with the macOS representable (the shared `VideoWindowView.body`
    // constructs both). iOS pane activation already runs through the canvas's per-pane SwiftUI tap
    // gesture + a background `DragGesture` for panning, so these are currently unused on iOS.
    var isActive: Bool = true
    // E21 WI-3 read-only gate — signature parity only. The iOS video view forwards NO host pointer/key
    // input (its gestures are LOCAL zoom/pan), so there is nothing to suppress; accepted + ignored here.
    var inputEnabled: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    // Signature parity with the macOS representable (the shared `VideoWindowView.body` passes it).
    // iOS has no host-key-injection sink (paste-as-keystrokes is macOS-only), so this is unused here.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    // Signature parity with the macOS representable. iOS resizes the remote window via pinch, not a
    // grip drag forwarded to the host, so the resize sink is accepted + ignored here.
    var onResizeInjectorReady: ((((UInt8, Double, Double) -> Void)?) -> Void)?

    func makeUIView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.onStreamNativeSize = onStreamNativeSize // before activate — nil-ness picks snap vs host-follow
        view.activate(connection: connection)
        return view
    }

    func updateUIView(_ uiView: MetalLayerBackedView, context _: Context) {
        uiView.controls = controls
        uiView.onStreamNativeSize = onStreamNativeSize
        uiView.activate(connection: connection)
    }

    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator _: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline. Adds VNC-style
/// pinch-to-zoom + one-finger pan (+ double-tap to reset) over the remote window.
final class MetalLayerBackedView: UIView, UIGestureRecognizerDelegate {
    override static var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("layerClass is CAMetalLayer, so the backing layer is always a CAMetalLayer")
        }
        return metalLayer
    }

    private let pipeline = VideoWindowPipeline()

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var gestureBaseZoom: CGFloat = 1
    private var gestureBasePan: CGPoint = .zero
    private var gesturesInstalled = false
    /// Bridge to the SwiftUI control overlay (fit/fill toggle + zoom reset). Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?
    /// 1:1 PANE SNAP (see the macOS sibling): ask the canvas pane to resize its video content from
    /// `current` to `target` points. Set by the representable BEFORE ``activate(connection:)``.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?

    func activate(connection: VideoWindowConnection?) {
        installGesturesIfNeeded()
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate (nil-ness picks snap vs host-follow at
        // session construction; mirrors the macOS sibling).
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    func deactivate() { pipeline.deactivate() }

    /// 1:1 PANE SNAP: the session handed us the host window's POINT size (the snap target).
    /// Rebase the session's resize debounce (no host echo), then ask the pane to adopt it —
    /// mirrors the macOS sibling.
    private func adoptStreamNativePoints(_ points: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        pipeline.adoptLayerSize(points)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: points, current: current) else { return }
        handler(
            CGSize(width: points.width, height: points.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }

    private func applyResetZoom() {
        zoom = 1
        pan = .zero
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = false
    }

    private func installGesturesIfNeeded() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        isUserInteractionEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, pan, doubleTap] as [UIGestureRecognizer] { g.delegate = self
            addGestureRecognizer(g)
        }
    }

    // Let pinch + pan run together (zoom while dragging).
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool { true }

    @objc
    private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureBaseZoom = zoom }
        zoom = min(max(gestureBaseZoom * g.scale, 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = zoom > 1.001
    }

    @objc
    private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureBasePan = pan }
        let t = g.translation(in: self)
        let invZoom = 1.0 / zoom
        pan.x = gestureBasePan.x - (t.x / max(bounds.width, 1)) * invZoom
        pan.y = gestureBasePan.y - (t.y / max(bounds.height, 1)) * invZoom
        pipeline.setZoom(zoom, pan: pan)
    }

    @objc
    private func onDoubleTap() { applyResetZoom() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render at native Retina resolution: set the layer's contentsScale to the screen
        // scale so the pipeline's drawableSize (points × contentsScale) is the pixel size.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        videoLayer.contentsScale = scale
        // Own drawableSize in the view (always lays out), same as the macOS sibling — so the
        // pixel size is correct regardless of renderer-activation ordering.
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }
}
#endif
#endif
