import XCTest
@testable import RworkVideoProtocol

/// PURE aspect-fit geometry (doc 17 §3.7): `displayedVideoRect` is the single source of
/// truth for where the decoded video is actually drawn inside the layer (letterbox /
/// pillarbox), and `viewPoint(forHostPoint:…)` is the forward render transform whose
/// inverse the input encoder uses. Both must mirror `MetalVideoRenderer`'s fit branch
/// exactly so render-forward and input-inverse can never drift.
final class AspectFitTests: XCTestCase {

    private func assertRect(_ r: VideoRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(r.origin.x, x, accuracy: 1e-9, "x", file: file, line: line)
        XCTAssertEqual(r.origin.y, y, accuracy: 1e-9, "y", file: file, line: line)
        XCTAssertEqual(r.size.width, w, accuracy: 1e-9, "w", file: file, line: line)
        XCTAssertEqual(r.size.height, h, accuracy: 1e-9, "h", file: file, line: line)
    }

    // MARK: displayedVideoRect

    func testWiderVideoGetsBarsTopAndBottomCentered() {
        // View 1600x1000 (aspect 1.6), video 1920x1080 (aspect ~1.778) → video is WIDER:
        // full width 1600, height = 1600/1.778 = 900, bars 50 top + 50 bottom.
        let r = AspectFit.displayedVideoRect(viewSize: VideoSize(width: 1600, height: 1000), videoNativeSize: VideoSize(width: 1920, height: 1080))
        assertRect(r, 0, 50, 1600, 900)
    }

    func testTallerVideoGetsBarsLeftAndRightCentered() {
        // View 1600x1000 (aspect 1.6), video 1000x1000 (aspect 1.0) → video is TALLER/narrower:
        // full height 1000, width = 1000*1.0 = 1000, bars 300 left + 300 right.
        let r = AspectFit.displayedVideoRect(viewSize: VideoSize(width: 1600, height: 1000), videoNativeSize: VideoSize(width: 1000, height: 1000))
        assertRect(r, 300, 0, 1000, 1000)
    }

    func testEqualAspectFillsLayer() {
        let r = AspectFit.displayedVideoRect(viewSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 1600, height: 1200))
        assertRect(r, 0, 0, 800, 600)
    }

    func testDegenerateZeroSizesFallBackToFullRect() {
        let zeroVideo = AspectFit.displayedVideoRect(viewSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 0, height: 0))
        assertRect(zeroVideo, 0, 0, 800, 600)
        let zeroView = AspectFit.displayedVideoRect(viewSize: VideoSize(width: 0, height: 0), videoNativeSize: VideoSize(width: 1920, height: 1080))
        assertRect(zeroView, 0, 0, 0, 0)
    }

    // MARK: viewPoint forward transform (host point → view point)

    func testForwardViewPointCenterAtUnityZoom() {
        // Center of the host window maps to the center of the displayed (letterboxed) rect.
        let p = AspectFit.viewPoint(forHostPoint: VideoPoint(x: 960, y: 540), viewSize: VideoSize(width: 1600, height: 1000), videoNativeSize: VideoSize(width: 1920, height: 1080))
        XCTAssertEqual(p.x, 800, accuracy: 1e-9)   // layer center x
        XCTAssertEqual(p.y, 500, accuracy: 1e-9)   // layer center y (= 50 + 900/2)
    }

    func testForwardViewPointTopLeftLandsOnDisplayedRectOrigin() {
        // Host (0,0) → the displayed rect's origin (0, 50) for the wider-video case.
        let p = AspectFit.viewPoint(forHostPoint: VideoPoint(x: 0, y: 0), viewSize: VideoSize(width: 1600, height: 1000), videoNativeSize: VideoSize(width: 1920, height: 1080))
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 50, accuracy: 1e-9)
    }
}
