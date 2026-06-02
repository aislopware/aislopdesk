#if os(macOS)
import Foundation
import AppKit
import RworkVideoProtocol

/// Samples the mouse position + current cursor shape and emits ``CursorUpdate``
/// messages for the cursor side-channel (doc 17 §3.3).
///
/// ⚠️ **HANG-SAFETY / GUI-ONLY:** uses AppKit (`NSEvent`, `NSCursor`) which require
/// an AppKit run loop. COMPILED + reviewed; not driven from tests.
///
/// Production wiring: a ~120 Hz timer samples `NSEvent.mouseLocation` (host CG/Cocoa
/// space) and the current `NSCursor`, converts the position into **host-window
/// space** (relative to the captured window's origin), assigns a stable `shapeID`
/// per distinct cursor image (the bitmap is shipped once, out of band, when a new
/// id appears), and sends a tiny <64-byte ``CursorUpdate``. The channel is a
/// **separate UDP socket** — never multiplexed with video — so video backpressure
/// never delays the cursor (doc 17 §3.3).
public final class CursorSampler: @unchecked Sendable {
    /// Sample rate (doc 17 §3.3: "~120 Hz").
    public static let sampleHz: Double = 120

    /// Emits a cursor position update for the side-channel socket to send (~120 Hz).
    public typealias UpdateHandler = @Sendable (CursorUpdate) -> Void
    /// Emits a cursor SHAPE bitmap ONCE per newly-seen `shapeID`, out of band, for the
    /// client to cache and composite (doc 17 §3.3). The orchestrator routes this to the
    /// cursor socket as a ``CursorShapeMessage``.
    public typealias ShapeHandler = @Sendable (CursorShapeMessage) -> Void

    private let updateHandler: UpdateHandler
    private let shapeHandler: ShapeHandler?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "rwork.video.cursor", qos: .userInteractive)

    /// The captured window's bounds in CG top-left space (kept in sync by the
    /// geometry watcher) — used to convert global mouse position to window space.
    private var windowBoundsCG: VideoRect
    private let boundsLock = NSLock()

    /// Stable shape-id assignment: each distinct `NSCursor` gets an incrementing id.
    private var shapeIDs: [ObjectIdentifier: UInt16] = [:]
    private var nextShapeID: UInt16 = 0

    public init(windowBoundsCG: VideoRect, updateHandler: @escaping UpdateHandler, shapeHandler: ShapeHandler? = nil) {
        self.windowBoundsCG = windowBoundsCG
        self.updateHandler = updateHandler
        self.shapeHandler = shapeHandler
    }

    /// Updates the tracked window bounds (call from the geometry watcher).
    public func updateWindowBounds(_ bounds: VideoRect) {
        boundsLock.lock(); windowBoundsCG = bounds; boundsLock.unlock()
    }

    /// Starts the ~120 Hz sampling timer. GUI-only.
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Self.sampleHz
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One sample: read mouse position + shape, convert to window space, emit.
    /// `NSEvent.mouseLocation` is Cocoa bottom-left global; we keep the math in
    /// window-relative normalized-free points (the side channel carries host-window
    /// points, which the client composites directly — doc 17 §3.3).
    @MainActor
    private func sampleOnMain() {
        let globalCocoa = NSEvent.mouseLocation // bottom-left, +Y up
        boundsLock.lock(); let bounds = windowBoundsCG; boundsLock.unlock()

        // Convert global Cocoa point to window-relative top-left points. The window
        // bounds are CG top-left; flip the cursor's Cocoa Y using the main screen
        // height so both are in the same top-left space, then subtract the origin.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgY = primaryHeight - Double(globalCocoa.y)
        let windowX = Double(globalCocoa.x) - bounds.origin.x
        let windowY = cgY - bounds.origin.y

        let cursor = NSCursor.current
        let hotspot = VideoPoint(x: Double(cursor.hotSpot.x), y: Double(cursor.hotSpot.y))
        let id = shapeID(for: cursor, hotspot: hotspot)
        let visible = windowX >= 0 && windowY >= 0 && windowX <= bounds.size.width && windowY <= bounds.size.height

        let update = CursorUpdate(
            position: VideoPoint(x: windowX, y: windowY),
            shapeID: id, hotspot: hotspot, visible: visible
        )
        updateHandler(update)
    }

    private func sample() {
        // Hop to main for AppKit reads (NSCursor.current / NSEvent.mouseLocation are
        // main-thread reads; doc 18 §C main-thread contract for AppKit state).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.sampleOnMain() }
        }
    }

    @MainActor
    private func shapeID(for cursor: NSCursor, hotspot: VideoPoint) -> UInt16 {
        let key = ObjectIdentifier(cursor)
        if let id = shapeIDs[key] { return id }
        let id = nextShapeID
        nextShapeID &+= 1
        shapeIDs[key] = id
        // OOB cursor-bitmap channel (doc 17 §3.3): the FIRST time a distinct cursor
        // appears, ship its bitmap + hotspot ONCE so the client caches it by `id` and
        // composites the pointer itself (`showsCursor` stays false on capture). The
        // hot per-sample message stays position-only.
        if let shapeHandler, let message = Self.encodeShape(cursor.image, shapeID: id, hotspot: hotspot) {
            shapeHandler(message)
        }
        return id
    }

    /// Encodes an `NSImage` cursor bitmap as a PNG ``CursorShapeMessage`` for the OOB
    /// shape channel. Returns `nil` if the image yields no bitmap representation.
    @MainActor
    static func encodeShape(_ image: NSImage, shapeID: UInt16, hotspot: VideoPoint) -> CursorShapeMessage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return CursorShapeMessage(
            shapeID: shapeID,
            size: VideoSize(width: Double(image.size.width), height: Double(image.size.height)),
            hotspot: hotspot,
            bitmap: png
        )
    }
}
#endif
