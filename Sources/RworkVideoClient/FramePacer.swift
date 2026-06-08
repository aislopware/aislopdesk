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
/// Pacing policy — small JITTER BUFFER (2026-06-08, motion-smoothness):
/// - The decoder pushes decoded frames into ``submit(_:)``; they queue oldest-first.
/// - Presentation HOLDS until the buffer first fills to ``targetDepth`` (priming),
///   establishing a few frames of slack. Thereafter each VSync presents ONE frame in
///   order — converting bursty / variable arrival into a steady one-per-vsync cadence.
/// - The slack absorbs the arrival/decode latency SPIKE at a static→motion transition
///   (idle = tiny 1.5 KB frames → scroll = 40–220 KB frames): without it the previous
///   "present newest / skip-late" pacer re-showed the last frame for a tick = the
///   "khựng khựng on idle-then-scroll" judder. (This is the Parsec/Moonlight render-ahead.)
/// - HOMEOSTASIS: presentation never carries more than ``targetDepth`` frames (drops the
///   oldest excess), so steady-state depth — and thus added latency — settles at
///   ≈targetDepth/fps instead of ratcheting up to ``maxDepth`` under sustained motion or
///   clock skew. ``maxDepth`` is a submit-side hard backstop. An empty buffer re-presents
///   the last frame (no judder beyond a single repeat).
/// - RE-PRIME: the host idle-skips static frames, so during any idle the buffer drains to
///   empty. After a sustained dry spell the pacer drops back to priming, so the slack is
///   REBUILT before the next scroll — making every stop→scroll transition smooth, not just
///   the first of a session.
///
/// The queue policy is pure and unit-testable in isolation; the `CADisplayLink` wiring
/// is GUI-only. Trade-off: ~``targetDepth`` frames of added latency (≈targetDepth/fps s)
/// bought for smoothness — the same trade Parsec makes. Both depths are env-tunable from
/// the construction site (``VideoWindowPipeline``) via `RWORK_JITTER_DEPTH` / `_MAX`.
public final class FramePacer: @unchecked Sendable {
    /// Called each VSync with the frame to draw (the next queued, or the last shown when
    /// the buffer is empty / still priming). `nil` only before the first frame.
    public typealias RenderCallback = @Sendable (CVImageBuffer) -> Void

    private let log = Logger(subsystem: "rwork.video.client", category: "FramePacer")
    private let renderCallback: RenderCallback
    private let lock = NSLock()
    /// Jitter buffer: decoded frames awaiting presentation, oldest first. Drained one per
    /// vsync; the oldest are dropped if it grows past ``maxDepth`` (bounded latency).
    private var queue: [CVImageBuffer] = []
    /// The last frame shown — re-presented while priming or on an empty buffer.
    private var lastShownFrame: CVImageBuffer?
    /// False until the buffer reaches ``targetDepth``; while false we hold (re-show last) so
    /// the slack that absorbs jitter is established before steady presentation. RESET to false
    /// after a SUSTAINED dry spell (``underflowRun`` ≥ ``targetDepth`` — a real idle, since the
    /// host idle-skips static frames, NOT a transient single-frame dip during scroll), so the
    /// slack is REBUILT before motion resumes. This is what makes EVERY stop→scroll transition
    /// smooth, not only the first of a session.
    private var primed = false
    /// Consecutive vsyncs the buffer has been empty (underflow). Reaching ``targetDepth`` means
    /// a genuine producer stall/idle (re-prime); reset to 0 on any presented frame.
    private var underflowRun = 0

    /// Frames to buffer before presentation begins. The absorbed arrival/decode jitter is
    /// ≈ this many frames; it is also the steady-state added latency (≈ targetDepth / fps).
    public let targetDepth: Int
    /// Hard cap on buffered frames; beyond it the oldest are dropped so latency cannot grow.
    public let maxDepth: Int

    /// The GUI video-path frame-rate cap (matches the host's `--fps`, default 60). On a
    /// 120 Hz display the link runs at full vsync but ``tick()`` only presents every Nth
    /// refresh so the cap holds without extra work the host never produces.
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

    public init(maxFrameRate: Double = 60.0, targetDepth: Int = 2, maxDepth: Int = 5, renderCallback: @escaping RenderCallback) {
        self.maxFrameRate = maxFrameRate
        self.targetDepth = max(1, targetDepth)
        self.maxDepth = max(max(1, targetDepth), maxDepth)
        self.renderCallback = renderCallback
    }

    /// Submits a freshly decoded frame to the tail of the jitter buffer. If the buffer has
    /// grown past ``maxDepth`` (producer outran the display), the OLDEST frames are dropped
    /// so latency cannot accumulate — we catch up to "now" rather than playing stale frames.
    public func submit(_ frame: CVImageBuffer) {
        lock.lock()
        queue.append(frame)
        if queue.count > maxDepth { queue.removeFirst(queue.count - maxDepth) }
        lock.unlock()
    }

    /// One VSync step: decide which frame to present (pure; the GUI link calls this).
    /// Returns the next queued frame in order, or the last shown while priming / on an
    /// empty buffer, or `nil` if nothing has ever been decoded yet.
    public func frameForVSync() -> CVImageBuffer? {
        lock.lock(); defer { lock.unlock() }
        if !primed {
            // (Re)prime: hold (re-show last) until the buffer fills to targetDepth, (re)building the
            // jitter slack BEFORE steady presentation. Re-entered after a sustained dry spell (below),
            // so the slack is rebuilt ahead of every stop→scroll resume — not just once per session.
            if queue.count >= targetDepth { primed = true; underflowRun = 0 } else { return lastShownFrame }
        }
        // Homeostasis: never carry MORE than targetDepth frames — drop the OLDEST excess so steady-state
        // depth (hence added latency) settles at ≈ targetDepth/fps instead of ratcheting up to maxDepth
        // under sustained motion / clock skew. Catches up to the freshest within the slack window.
        if queue.count > targetDepth { queue.removeFirst(queue.count - targetDepth) }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            lastShownFrame = next
            underflowRun = 0
            return next
        }
        // Underflow: producer fell behind (idle-skip or stall). Re-present last. After a SUSTAINED dry
        // spell (empty ≥ targetDepth vsyncs ⇒ a real idle, not a transient scroll dip) drop back to
        // priming so slack is rebuilt before motion resumes.
        underflowRun += 1
        if underflowRun >= max(1, targetDepth) { primed = false }
        return lastShownFrame
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
