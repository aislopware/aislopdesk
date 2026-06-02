#if canImport(QuartzCore) && canImport(CoreVideo)
import Foundation
import CoreVideo
import QuartzCore
import OSLog
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Drives display from VSync (`CADisplayLink`), NOT decode-completion (doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY** for the `CADisplayLink` path (needs a run loop + a screen).
/// COMPILED + reviewed; not driven from tests.
///
/// Pacing policy (doc 17 §3.7, Moonlight pacer):
/// - The decoder pushes decoded frames into ``submit(_:)`` (most-recent wins).
/// - Each VSync tick pulls the latest decoded frame and renders it; an EMPTY queue
///   shows the LAST decoded frame again (no judder).
/// - A late frame is SKIPPED, never queued, so latency does not accumulate — we keep
///   only the single most-recent frame, dropping any older one still pending.
///
/// The "keep only the newest frame" logic is pure and is unit-testable in isolation;
/// the `CADisplayLink` wiring is GUI-only.
public final class FramePacer: @unchecked Sendable {
    /// Called each VSync with the frame to draw (the newest decoded, or the last
    /// shown when nothing newer arrived). `nil` only before the first frame.
    public typealias RenderCallback = @Sendable (CVImageBuffer) -> Void

    private let log = Logger(subsystem: "rwork.video.client", category: "FramePacer")
    private let renderCallback: RenderCallback
    private let lock = NSLock()
    /// The newest decoded frame not yet shown; replaced (dropped) when a newer one
    /// arrives before the next vsync — this is the skip-late behaviour.
    private var pendingFrame: CVImageBuffer?
    /// The last frame shown — re-presented on an empty queue (show-last-frame).
    private var lastShownFrame: CVImageBuffer?

    /// The GUI video-path frame-rate cap. The video path is capped at ~24-30fps (the
    /// measured GUI cadence — NOT a 60/120fps game-stream); on a 120 Hz display we run
    /// the link at full vsync but only render every Nth tick so the cap holds without
    /// extra encode/decode work the host never produces (doc 18, FPS memory note).
    public let maxFrameRate: Double

    // On BOTH platforms the modern driver is a `CADisplayLink`: macOS 14+ exposes
    // `NSView.displayLink(target:selector:)` (the non-deprecated replacement for
    // `CVDisplayLink`, run-loop driven like iOS), and iOS uses `CADisplayLink`
    // directly. A tiny `@objc` proxy forwards each vsync into ``tick()``.
    #if canImport(QuartzCore)
    private var displayLink: CADisplayLink?
    /// A small target object the `CADisplayLink` retains; it forwards to ``tick()``.
    private final class DisplayLinkProxy: NSObject {
        let pacer: FramePacer
        init(_ pacer: FramePacer) { self.pacer = pacer }
        @objc func step() { pacer.tick() }
    }
    private var proxy: DisplayLinkProxy?
    #endif

    /// Tracks the elapsed time so the cap throttles ticks below the display refresh.
    private var lastRenderHostTime: Double = 0

    public init(maxFrameRate: Double = 30.0, renderCallback: @escaping RenderCallback) {
        self.maxFrameRate = maxFrameRate
        self.renderCallback = renderCallback
    }

    /// Submits a freshly decoded frame. If an earlier frame is still pending for this
    /// vsync it is dropped (skip-late: only the newest frame is presented).
    public func submit(_ frame: CVImageBuffer) {
        lock.lock()
        pendingFrame = frame // drops any older pending frame
        lock.unlock()
    }

    /// One VSync step: decide which frame to present (pure; the GUI link calls this).
    /// Returns the frame to draw, or `nil` if nothing has ever been decoded yet.
    public func frameForVSync() -> CVImageBuffer? {
        lock.lock(); defer { lock.unlock() }
        if let pending = pendingFrame {
            lastShownFrame = pending
            pendingFrame = nil
            return pending
        }
        return lastShownFrame // show-last-frame on empty queue
    }

    /// VSync handler: pull the frame and render it, honouring the frame-rate cap.
    /// Called by the display-link driver each refresh (and directly from tests).
    public func tick(hostTimeSeconds: Double = currentHostTimeSeconds()) {
        guard Self.shouldRender(now: hostTimeSeconds, lastRender: lastRenderHostTime, maxFrameRate: maxFrameRate) else {
            return // throttle: a display refresh faster than the GUI cap is skipped
        }
        lastRenderHostTime = hostTimeSeconds
        if let frame = frameForVSync() {
            renderCallback(frame)
        }
    }

    /// Pure cap decision: render only when at least `1/maxFrameRate` seconds elapsed
    /// since the last render (a small slack absorbs vsync jitter so we don't drop one
    /// extra frame to rounding). `lastRender == 0` ⇒ first tick always renders.
    /// Unit-testable without a display link.
    public static func shouldRender(now: Double, lastRender: Double, maxFrameRate: Double) -> Bool {
        guard maxFrameRate > 0 else { return true }
        guard lastRender > 0 else { return true }
        let minInterval = 1.0 / maxFrameRate
        // 0.5 ms slack so a refresh landing a hair early still counts (avoids a
        // beat-frequency stutter between the display vsync and the cap interval).
        return (now - lastRender) >= (minInterval - 0.0005)
    }

    // MARK: Display-link driver (GUI-only; never created in tests)

    /// Monotonic host time in seconds (vsync timestamp source). Pure read.
    public static func currentHostTimeSeconds() -> Double {
        CACurrentMediaTime()
    }

    #if os(macOS)
    /// Starts the display link driving ``tick()`` at the display's refresh rate, using
    /// the modern, NON-deprecated `NSView.displayLink(target:selector:)` (macOS 14+) —
    /// the replacement for `CVDisplayLink`. It is bound to `view`'s screen and runs on
    /// the main run loop (like iOS's `CADisplayLink`), so the cap throttle + render path
    /// are consistent across OSes. ⚠️ GUI-only — needs a view on screen; NEVER called
    /// from a test. `@MainActor`: `NSView.displayLink(target:selector:)` is main-actor
    /// API and the returned `CADisplayLink` is main-confined; the pipeline calls this on
    /// the main actor.
    @MainActor
    public func start(view: NSView) {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(self)
        self.proxy = proxy
        let link = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.step))
        configureCadence(link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    #elseif canImport(UIKit)
    /// Starts the `CADisplayLink` driving ``tick()`` at the display's refresh rate,
    /// capped to ``maxFrameRate`` via the throttle in ``tick()``. `view` is accepted for
    /// signature parity with the macOS path (and so the link's screen could be derived
    /// later); iOS constructs the `CADisplayLink` directly.
    /// ⚠️ GUI-only — needs a run loop + a screen; NEVER called from a test.
    @MainActor
    public func start(view: UIView) {
        guard displayLink == nil else { return }
        _ = view // parity with macOS NSView.displayLink; the link runs on the main loop
        let proxy = DisplayLinkProxy(self)
        self.proxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step))
        configureCadence(link)
        link.add(to: RunLoop.main, forMode: .common)
        displayLink = link
    }
    #endif

    #if canImport(QuartzCore)
    /// Hints the system to the GUI cap so it can coalesce vsyncs (24-30fps, NOT 120 —
    /// the GUI video path is not a 60/120fps game stream). The ``tick()`` throttle is
    /// the authoritative cap; this just lets the OS pace the link efficiently.
    @MainActor
    private func configureCadence(_ link: CADisplayLink) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: Float(maxFrameRate), preferred: Float(maxFrameRate))
    }

    /// Stops + releases the display link. `@MainActor`: the link is main-confined.
    @MainActor
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
    }
    #endif
}
#endif
