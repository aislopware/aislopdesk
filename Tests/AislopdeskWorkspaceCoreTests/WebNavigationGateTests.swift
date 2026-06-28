// WebNavigationGateTests — E18 / ES-E18-4. Pins the LOAD-decision gate (``WebNavigationGate``) behind the
// production `WKWebView`-backed `WebPaneView`: the hang-safe logic that decides when `sync` may (re)issue a
// `webView.load(...)`. A `WKWebView` is a GUI/WebKit object that must never be built in a test (CLAUDE.md
// hang-safety), so — exactly like ``WebPaneModel`` for the chrome — the load-bearing policy lives in this pure
// value type and is driven here without a web view; `WebPaneView`'s `didCommit`/`sync` are the code-reviewed
// glue that call it.
//
// Every case asserts the EXACT load/suppress decision against an expected value, and reproduces the
// feedback-loop ordering of the live `WebPaneView` call sites (attach → sync → didCommit). On the un-fixed
// tree the gate did not exist, so the file fails to compile (the WebPaneStoreTests revert-to-confirm-fail
// idiom); the regression it guards is the bug where a page-initiated navigation (link click / 30x redirect /
// chrome Back-Forward) was NOT recorded as displayed, so its write-back echo re-issued a fresh load —
// double-loading every click and truncating forward history.

#if canImport(SwiftUI)
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

@MainActor
final class WebNavigationGateTests: XCTestCase {
    private func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s)) }

    // MARK: - The address-bar / Open-In-Place path: a LEADING request issues exactly one load

    func testLeadingRequestLoadsOnceAndThenSuppressesTheEcho() throws {
        // attach(initialURL: A): the view is already showing A — the first `sync(A)` must NOT double-load it.
        var gate = try WebNavigationGate(displayedURL: url("https://example.com/"))
        XCTAssertNil(try gate.loadIfLeading(url("https://example.com/")), "the initial address is not re-loaded")

        // Address-bar submit to B: requestedURL now LEADS the view (still on A) → exactly one real load.
        let b = try url("https://example.com/page2")
        XCTAssertEqual(gate.loadIfLeading(b), b, "a leading request issues the load")
        XCTAssertEqual(gate.displayedURL, b, "and is recorded as now-displayed")

        // The page commits B and echoes it back (onNavigated → requestedURL == B → a fresh `sync(B)`):
        // the echo must be suppressed, or the address-bar load would fire twice.
        gate.recordCommitted(b)
        XCTAssertNil(gate.loadIfLeading(b), "the write-back echo of the just-loaded URL is suppressed")
    }

    // MARK: - ES-E18-4: a PAGE-INITIATED navigation must not be re-loaded by its own write-back echo

    func testPageInitiatedNavigationIsNotReloadedByItsEcho() throws {
        // Live page is showing A (committed by the initial load).
        var gate = try WebNavigationGate(displayedURL: url("https://example.com/"))
        try gate.recordCommitted(url("https://example.com/"))

        // The user clicks a link / the server 30x-redirects to B. `didCommit` fires first:
        // recordCommitted(B) before the write-back echo flows through onNavigated → requestedURL = B.
        let b = try url("https://example.com/article")
        gate.recordCommitted(b)

        // The echo re-renders the descriptor (initialURL = B) and re-runs `sync(B)`. THE BUG: on the un-fixed
        // path `loadedURL` was still A, so this returned B → a SECOND, fresh load of the destination (POST →
        // GET refetch, page state reset). With the commit recorded, it must suppress.
        XCTAssertNil(gate.loadIfLeading(b), "a page-driven navigation is not re-loaded by its write-back echo")
        XCTAssertEqual(gate.displayedURL, b, "the gate now tracks the page's own destination")
    }

    // MARK: - Chrome Back/Forward (controller-driven) is a history pop, never a fresh load

    func testChromeBackIsAHistoryPopNotAFreshLoad() throws {
        // History A → B, view currently on B.
        var gate = try WebNavigationGate(displayedURL: url("https://example.com/b"))

        // Chrome Back → webView.goBack() pops to A; `didCommit` fires for A, then echoes A back.
        let a = try url("https://example.com/a")
        gate.recordCommitted(a)
        // The echo (requestedURL = A) re-runs `sync(A)`: a fresh `load(A)` here would truncate forward
        // history (B would be lost), defeating ⌘[/⌘] Back/Forward. It must be a no-op.
        XCTAssertNil(gate.loadIfLeading(a), "Back pops history; it does not re-load and truncate forward history")

        // Chrome Forward → webView.goForward() returns to B; same contract.
        let b = try url("https://example.com/b")
        gate.recordCommitted(b)
        XCTAssertNil(gate.loadIfLeading(b), "Forward pops history; it does not re-load")
    }

    // MARK: - A genuine new address still loads after the page navigated on its own

    func testFreshAddressStillLoadsAfterAPageInitiatedNav() throws {
        var gate = try WebNavigationGate(displayedURL: url("https://example.com/"))
        // The page redirected itself to B (recorded).
        let b = try url("https://example.com/landing")
        gate.recordCommitted(b)
        XCTAssertNil(gate.loadIfLeading(b), "the redirect's echo is suppressed")

        // Now the user types a genuinely new address C — it LEADS the view, so it must load.
        let c = try url("https://duckduckgo.com/")
        XCTAssertEqual(gate.loadIfLeading(c), c, "a new leading address still issues a load")
    }

    // MARK: - A nil request / nil commit are inert (a blank pane never loads)

    func testNilRequestAndNilCommitAreInert() throws {
        var gate = WebNavigationGate()
        XCTAssertNil(gate.loadIfLeading(nil), "a blank pane (nil requested URL) issues no load")
        gate.recordCommitted(nil) // a commit with no URL leaves the gate untouched
        XCTAssertNil(gate.displayedURL, "nothing is displayed yet")
        let a = try url("https://example.com/")
        XCTAssertEqual(gate.loadIfLeading(a), a, "the first real address then loads")
    }
}
#endif
