import XCTest
import CoreVideo
@testable import RworkVideoClient

/// PURE frame-pacer logic: most-recent-wins submit, show-last-frame on empty queue,
/// skip-late, and the GUI frame-rate cap throttle. NO display link is created here —
/// only `submit` / `frameForVSync` / `tick(hostTimeSeconds:)` / `shouldRender`, which
/// are pure. `CVPixelBufferCreate` is a plain CoreVideo allocation (no decode session,
/// no window-server) so it is hang-safe.
final class FramePacerTests: XCTestCase {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        precondition(status == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate failed (\(status))")
        return pb!
    }

    // MARK: Queue policy (pure)

    func testFirstSubmitIsPresentedAndBecomesLastShown() {
        let pacer = FramePacer(renderCallback: { _ in })
        XCTAssertNil(pacer.frameForVSync(), "no frame ever decoded → nil")
        let frame = makePixelBuffer()
        pacer.submit(frame)
        XCTAssertTrue(pacer.frameForVSync() === frame)
        // Empty queue now → re-present the last shown.
        XCTAssertTrue(pacer.frameForVSync() === frame)
    }

    func testSkipLateKeepsOnlyNewest() {
        let pacer = FramePacer(renderCallback: { _ in })
        let older = makePixelBuffer()
        let newer = makePixelBuffer()
        pacer.submit(older)
        pacer.submit(newer) // drops `older` before any vsync pulled it
        XCTAssertTrue(pacer.frameForVSync() === newer)
    }

    // MARK: Frame-rate cap (pure)

    func testCapFirstTickAlwaysRenders() {
        XCTAssertTrue(FramePacer.shouldRender(now: 1234.0, lastRender: 0, maxFrameRate: 30))
    }

    func testCapThrottlesRefreshFasterThanCap() {
        // A 120 Hz display ticks every ~8.33ms; a 30fps cap allows ~33.3ms apart.
        // 10ms after the last render is too soon at a 30fps cap.
        XCTAssertFalse(FramePacer.shouldRender(now: 0.010, lastRender: 0.001, maxFrameRate: 30))
        // 34ms apart clears the 33.3ms interval.
        XCTAssertTrue(FramePacer.shouldRender(now: 0.044, lastRender: 0.010, maxFrameRate: 30))
    }

    func testCapDisabledWhenRateNonPositive() {
        XCTAssertTrue(FramePacer.shouldRender(now: 0.001, lastRender: 0.0005, maxFrameRate: 0))
    }

    func testTickHonoursCapAndRenders() {
        let counter = RenderCounter()
        let pacer = FramePacer(maxFrameRate: 30, renderCallback: { _ in counter.bump() })
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 0.0)   // first tick (lastRender==0) → renders
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 1.000) // lastRender still 0 → renders
        pacer.submit(makePixelBuffer())
        pacer.tick(hostTimeSeconds: 1.005) // 5ms later, under the 33ms cap → throttled
        XCTAssertEqual(counter.count, 2, "two ticks cleared the cap; the third was throttled")
    }
}

/// Thread-safe render counter (the pacer's `@Sendable` render callback forbids
/// capturing a mutable local).
private final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
