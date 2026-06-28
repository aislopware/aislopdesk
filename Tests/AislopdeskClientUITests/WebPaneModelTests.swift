// WebPaneModelTests — E18 / WI-4. Pins the LOCAL web pane's view-model (``WebPaneModel``): the headless
// driver behind ``WebLeafView``'s address bar. The model owns the address-bar text + the URL the
// ``WebRendererFactory`` loads, normalizing submits through ``WebURLNormalizer`` (validate-then-drop) and
// surfacing the resolved URL to a write-back closure (the ``PaneSpec/webURL`` persistence). It touches NO
// `WKWebView` — only pure URL policy — so it is hang-safe (the CLAUDE.md rule) and drives the EXACT logic the
// GUI does (the `TerminalFindBarModel` test idiom).
//
// Every case FAILS on the un-fixed tree (``WebPaneModel`` did not exist before WI-4) and asserts an
// observable state transition (the requested URL / the reflected field text / whether the write-back fired)
// against an EXPECTED value, never against the output's own derivation.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class WebPaneModelTests: XCTestCase {
    /// Drives `navigate` and records the URL handed to the write-back closure (the store's `setPaneWebURL`).
    private func navigate(_ model: WebPaneModel, typing text: String) -> (resolved: URL?, committed: [URL]) {
        model.addressText = text
        var committed: [URL] = []
        let resolved = model.navigate { committed.append($0) }
        return (resolved, committed)
    }

    // MARK: - Address-bar submit policy (via WebURLNormalizer)

    func testBareHostGetsHTTPSAndPersists() {
        let model = WebPaneModel(initialAddress: nil)
        let (resolved, committed) = navigate(model, typing: "example.com")
        XCTAssertEqual(resolved?.absoluteString, "https://example.com", "a bare host gains https://")
        XCTAssertEqual(model.requestedURL?.absoluteString, "https://example.com", "the loaded URL updates")
        XCTAssertEqual(model.addressText, "https://example.com", "the field reflects the canonical URL")
        XCTAssertEqual(committed.map(\.absoluteString), ["https://example.com"], "the address is persisted once")
    }

    func testFreeTextBecomesDuckDuckGoSearch() {
        let model = WebPaneModel(initialAddress: nil)
        let (resolved, committed) = navigate(model, typing: "swift concurrency")
        XCTAssertEqual(resolved?.host, "duckduckgo.com", "non-URL text searches DuckDuckGo")
        XCTAssertEqual(resolved?.absoluteString, model.requestedURL?.absoluteString)
        XCTAssertEqual(committed.count, 1, "a resolved search URL is persisted")
    }

    func testExplicitHTTPSPassesThrough() {
        let model = WebPaneModel(initialAddress: nil)
        let (resolved, _) = navigate(model, typing: "https://duckduckgo.com/?q=1")
        XCTAssertEqual(resolved?.absoluteString, "https://duckduckgo.com/?q=1")
    }

    func testEmptyInputIsDroppedAndDoesNotPersist() {
        let model = WebPaneModel(initialAddress: "https://example.com")
        let (resolved, committed) = navigate(model, typing: "   ")
        XCTAssertNil(resolved, "whitespace-only input resolves to nothing (validate-then-drop)")
        XCTAssertEqual(model.requestedURL?.absoluteString, "https://example.com", "the loaded URL is unchanged")
        XCTAssertTrue(committed.isEmpty, "a dropped submit never writes back")
    }

    func testDangerousSchemeIsDroppedAndDoesNotPersist() {
        let model = WebPaneModel(initialAddress: nil)
        let (resolved, committed) = navigate(model, typing: "javascript:alert(1)")
        XCTAssertNil(resolved, "a non-http(s) scheme is dropped, never navigated")
        XCTAssertNil(model.requestedURL, "no URL is loaded")
        XCTAssertTrue(committed.isEmpty, "nothing is persisted")
    }

    // MARK: - Live-page navigation write-back (WebPaneContext.onNavigated)

    func testDidNavigateTracksTheLivePageWithoutCommitting() throws {
        let model = WebPaneModel(initialAddress: "https://example.com")
        // A link click inside the live page redirects — `onNavigated` reflects it into the chrome.
        try model.didNavigate(to: XCTUnwrap(URL(string: "https://example.com/docs")))
        XCTAssertEqual(model.requestedURL?.absoluteString, "https://example.com/docs", "the chrome follows the page")
        XCTAssertEqual(model.addressText, "https://example.com/docs", "the field follows the page")
    }

    // MARK: - External spec changes (initial stamp / Open-In-Place re-nav)

    func testSyncExternalAdoptsANewAddress() {
        let model = WebPaneModel(initialAddress: nil)
        model.syncExternal(address: "https://duckduckgo.com/")
        XCTAssertEqual(model.requestedURL?.absoluteString, "https://duckduckgo.com/", "an external stamp loads")
        XCTAssertEqual(model.addressText, "https://duckduckgo.com/")
    }

    func testSyncExternalIsDirtyGuarded() {
        let model = WebPaneModel(initialAddress: "https://example.com")
        // The user is mid-typing; an echo of the SAME address must not clobber the field.
        model.addressText = "github.c"
        model.syncExternal(address: "https://example.com")
        XCTAssertEqual(model.addressText, "github.c", "a same-address echo leaves the field untouched")
    }

    // MARK: - Live-page control sink (WebPaneContext.onControllerReady → Back / Forward / Reload)

    func testBackForwardGreyedWithoutALiveController() {
        let model = WebPaneModel(initialAddress: "https://example.com")
        // No production WKWebView has published a controller → no history feedback, so Back / Forward stay
        // greyed (faithful to web-broswer.png, where a freshly-loaded page disables them).
        XCTAssertFalse(model.canGoBack, "Back is greyed with no live web view")
        XCTAssertFalse(model.canGoForward, "Forward is greyed with no live web view")
    }

    func testControllerHistoryEnablesBackForwardAndCommandsRouteToTheLivePage() {
        let model = WebPaneModel(initialAddress: "https://example.com")
        var back = 0, forward = 0
        let controller = WebPaneController(goBack: { back += 1 }, goForward: { forward += 1 })
        // The production view publishes its controller (the `onControllerReady` hand-back).
        model.controller = controller
        // Still greyed until the live page reports history (its canGoBack/canGoForward KVO).
        XCTAssertFalse(model.canGoBack, "no history yet ⇒ Back greyed even with a controller")
        controller.updateHistory(canGoBack: true, canGoForward: false)
        XCTAssertTrue(model.canGoBack, "Back enables once the page has back-history")
        XCTAssertFalse(model.canGoForward, "Forward stays greyed at the tip of history")
        // The chrome's Back / Forward drive the live page.
        model.goBack()
        model.goForward()
        XCTAssertEqual(back, 1, "Back routes to the live web view exactly once")
        XCTAssertEqual(forward, 1, "Forward routes to the live web view exactly once")
    }

    func testReloadHardReloadsTheLivePageButReissuesTheAddressHeadlessly() {
        // No controller (headless / placeholder) → Reload re-issues the current address through navigate,
        // which persists it (the write-back fires).
        let headless = WebPaneModel(initialAddress: "https://example.com")
        var headlessCommitted: [URL] = []
        headless.reload { headlessCommitted.append($0) }
        XCTAssertEqual(
            headlessCommitted.map(\.absoluteString), ["https://example.com"],
            "with no live page, Reload re-issues the address (and persists it)",
        )

        // A live controller → Reload HARD-reloads the WKWebView and never re-commits the address (the live
        // page keeps its history / POST state; the address bar isn't re-navigated).
        let live = WebPaneModel(initialAddress: "https://example.com")
        var reloadFired = 0
        live.controller = WebPaneController(reload: { reloadFired += 1 })
        var liveCommitted: [URL] = []
        live.reload { liveCommitted.append($0) }
        XCTAssertEqual(reloadFired, 1, "a live page hard-reloads")
        XCTAssertTrue(liveCommitted.isEmpty, "a hard reload does not re-commit / re-persist the address")
    }
}
#endif
