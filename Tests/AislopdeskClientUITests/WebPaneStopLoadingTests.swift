// WebPaneStopLoadingTests — Batch-4 item 8: the leftmost web-toolbar ✗ acts as STOP while the page is
// loading and CLOSE when idle (web-broswer.png). Headless + hang-safe: drives the `WebPaneModel` over a
// plain `WebPaneController` (no `WKWebView` — the controller is the seam the production view publishes), so
// the loading-state → Stop/Close role + the stop-action passthrough are pinned without WebKit.
// Revert-to-confirm-fail: before the fix the model exposed no `isLoading`/`stop` and the controller had no
// `stop`/`updateLoading`, so this would not compile.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class WebPaneStopLoadingTests: XCTestCase {
    func testStopRoleFlipsWithLoadingAndStopDrivesTheController() {
        let model = WebPaneModel(initialAddress: "https://example.com")
        // No live controller (headless placeholder): never loading → the ✗ stays Close.
        XCTAssertFalse(model.isLoading, "no live controller ⇒ not loading (the ✗ stays Close)")

        var stopCount = 0
        let controller = WebPaneController(stop: { stopCount += 1 })
        model.controller = controller
        XCTAssertFalse(model.isLoading, "a fresh controller starts idle")

        controller.updateLoading(true)
        XCTAssertTrue(model.isLoading, "a loading page flips the ✗ to Stop")

        model.stop()
        XCTAssertEqual(stopCount, 1, "model.stop() drives the controller's stop action while loading")

        controller.updateLoading(false)
        XCTAssertFalse(model.isLoading, "finishing the load returns the ✗ to Close")
    }
}
#endif
