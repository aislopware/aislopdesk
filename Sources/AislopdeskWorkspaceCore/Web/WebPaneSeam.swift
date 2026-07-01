#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a LOCAL built-in web-browser pane
/// (`PaneKind.web`, E18; `docs/ui-shell/spec/user-interface__files-and-links.md` › Web Browser Pane).
///
/// Exactly like ``VideoWindowFactory`` for the remote-GUI pixels, the cross-platform library cannot
/// reference a `WKWebView` directly — that would pull `WebKit` into the headless `swift build`, and a
/// `WKWebView` (like an `SCStream` / `VTCompressionSession`) is a GUI/WebKit object that must never be
/// instantiated in a test or headless context (CLAUDE.md hang-safety rule). Instead the GUI app target —
/// which links `WebKit` — registers a factory at launch; the library calls it through this seam and falls
/// back to a clearly-labelled placeholder when no factory was registered (the headless build, or a unit
/// test).
///
/// Unlike the video seam this pane is **fully local**: it rides no remote stream, opens no UDP, and has no
/// PTY funnel. The factory's production view builds a `WKWebView` with a **non-persistent** website data
/// store (D9 — no on-disk cookies/cache, nothing bleeds across panes or survives a restart) and
/// `mediaTypesRequiringUserActionForPlayback = .all` (no autoplay), per the pane's design spec.
///
/// Wiring (app target, once at launch — `Apps/Shared/WebPaneView.swift` + `AppMain`):
/// ```swift
/// import WebKit
/// WebRendererFactory.shared = { descriptor, context in
///     AnyView(WebPaneView(descriptor: descriptor, context: context))
/// }
/// ```
/// The production `WebPaneView` builds its `WKWebView` with `configuration.websiteDataStore =
/// .nonPersistent()` (D9) and `configuration.mediaTypesRequiringUserActionForPlayback = .all` (no autoplay),
/// loads ``WebPaneDescriptor/initialURL``, and forwards `didCommit`/title navigations back through the
/// ``WebPaneContext`` callbacks below.
public struct WebPaneDescriptor: Sendable, Equatable {
    /// The pane this web view backs (stable for the pane's lifetime — the leaf view keys on it).
    public var paneID: PaneID
    /// The address to load first, already normalized to a navigable `http(s)` URL by
    /// ``WebURLNormalizer``. `nil` ⇒ a fresh/blank pane (the factory shows an empty page / the address bar
    /// is empty until the user types).
    public var initialURL: URL?

    public init(paneID: PaneID, initialURL: URL? = nil) {
        self.paneID = paneID
        self.initialURL = initialURL
    }
}

/// The pure, hang-safe **navigation gate** the production `WKWebView`-backed web pane delegates its
/// "should I (re)issue a load?" decision to. A `WKWebView` is a GUI/WebKit object that must never be built in
/// a test (CLAUDE.md hang-safety rule), so the load-bearing policy lives here — a value type over plain
/// `URL`s — and is unit-tested without a web view (the same posture ``WebPaneController`` / `WebPaneModel`
/// give the chrome).
///
/// It tracks the URL the live view is ALREADY showing: the last URL we asked it to load (an address-bar
/// submit / Open-In-Place re-nav), OR the last navigation the page committed on its OWN — a link click, a
/// 30x redirect, or a controller-driven Back / Forward. `sync` re-issues a load ONLY when the requested URL
/// *leads* what the view shows; a page-initiated navigation is recorded as already-displayed so its
/// write-back echo (`onNavigated` → `WebPaneModel.requestedURL` changes → a fresh descriptor → `sync`) can
/// NOT re-load the destination — which would otherwise double-load every link click, refetch a POST result
/// as a GET, and turn Back into a fresh load that truncates forward history (ES-E18-4).
public struct WebNavigationGate: Equatable {
    /// The URL the live view is currently showing: the last URL we loaded into it, or the last page-driven
    /// navigation it committed. ``loadIfLeading(_:)`` compares the requested URL against this.
    public private(set) var displayedURL: URL?

    public init(displayedURL: URL? = nil) {
        self.displayedURL = displayedURL
    }

    /// `sync`: the descriptor's requested URL may have changed. Returns the URL the view should load (and
    /// records it as now-displayed) when the request LEADS what the view shows — an address-bar submit /
    /// Open-In-Place re-nav — or `nil` when the view is already showing it (a write-back echo, or a
    /// page-initiated navigation that already committed) so an echo never re-triggers a load loop.
    public mutating func loadIfLeading(_ requested: URL?) -> URL? {
        guard let requested, requested != displayedURL else { return nil }
        displayedURL = requested
        return requested
    }

    /// `didCommit`: the live page committed a navigation it drove itself (link click / 30x redirect /
    /// controller-driven Back-Forward). Record what the view now shows as already-displayed so the write-back
    /// echo won't re-load it. Recorded on COMMIT — not provisional start — so a failed provisional, which
    /// never changes the displayed page, can't desync the gate into suppressing a genuine later load.
    public mutating func recordCommitted(_ committed: URL?) {
        guard let committed else { return }
        displayedURL = committed
    }
}

/// The IN-channel to the live web view — the additive control sink the browser chrome's
/// Back / Forward / hard-Reload need (the proven ``RemotePaneContext/onKeyInjectorReady`` hand-back
/// pattern). The production `WKWebView` view publishes one of these through
/// ``WebPaneContext/onControllerReady`` once it exists (and `nil` on teardown); the cross-platform leaf
/// holds it and drives `goBack()` / `goForward()` / `reload()` against the live page, reading
/// ``canGoBack`` / ``canGoForward`` (pushed from the web view's KVO) to enable / grey the buttons —
/// faithful to `web-broswer.png`, where a freshly-loaded page greys Back / Forward.
///
/// `@Observable` so a history change re-renders the chrome; `@MainActor` because it fronts a `WKWebView`
/// (main-thread-only). The command closures default to no-ops so a controller built before its actions are
/// installed is inert, never a crash (validate-then-drop discipline applied to the GUI seam).
@preconcurrency
@MainActor
@Observable
public final class WebPaneController {
    /// Whether the live page can navigate back — pushed from the `WKWebView`'s `canGoBack` KVO. `false`
    /// until a live view publishes history (so the chrome starts with Back greyed).
    public private(set) var canGoBack: Bool = false
    /// Whether the live page can navigate forward — pushed from the `WKWebView`'s `canGoForward` KVO.
    public private(set) var canGoForward: Bool = false
    /// Whether the live page is CURRENTLY loading — pushed from the `WKWebView`'s navigation delegate
    /// (`didStartProvisionalNavigation` → `true`, `didFinish`/`didFail` → `false`). `false` until a live view
    /// reports otherwise, so the chrome's leftmost button starts as Close (✗), flipping to Stop while loading.
    public private(set) var isLoading: Bool = false

    private let goBackAction: () -> Void
    private let goForwardAction: () -> Void
    private let reloadAction: () -> Void
    private let hardReloadAction: () -> Void
    private let findAction: () -> Void
    private let stopAction: () -> Void

    public init(
        goBack: @escaping () -> Void = {},
        goForward: @escaping () -> Void = {},
        reload: @escaping () -> Void = {},
        hardReload: @escaping () -> Void = {},
        find: @escaping () -> Void = {},
        stop: @escaping () -> Void = {},
    ) {
        goBackAction = goBack
        goForwardAction = goForward
        reloadAction = reload
        hardReloadAction = hardReload
        findAction = find
        stopAction = stop
    }

    /// Drive the live page back one history entry (no-op if the production view installed no action).
    public func goBack() { goBackAction() }
    /// Drive the live page forward one history entry.
    public func goForward() { goForwardAction() }
    /// Hard-reload the live page — re-fetches the CURRENT page (keeping history/POST state), unlike the
    /// address-bar fallback which re-issues the address as a fresh navigation.
    public func reload() { reloadAction() }
    /// Hard-reload IGNORING the cache (the ⌘⇧R browser idiom) — `WKWebView.reloadFromOrigin()`, which
    /// re-fetches every resource end-to-end rather than revalidating against the cache.
    public func hardReload() { hardReloadAction() }
    /// Present the live page's native find-in-page UI (⌘F) — the production view wires this to the
    /// platform's WebKit find (`UIFindInteraction` on iOS, the macOS find bar). No-op without a live view.
    public func find() { findAction() }

    /// Stop the live page's in-flight load (`WKWebView.stopLoading()`) — the browser ✗ button's "Stop"
    /// semantics while a page is loading. No-op without a live view / installed action.
    public func stop() { stopAction() }

    /// The production view pushes the live `WKWebView`'s navigation history here (its `canGoBack` /
    /// `canGoForward` KVO) so the chrome enables / greys Back / Forward.
    public func updateHistory(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    /// The production view pushes the live page's loading state here (its navigation-delegate start/finish/fail
    /// callbacks) so the chrome's leftmost button flips between Stop (loading) and Close (idle).
    public func updateLoading(_ isLoading: Bool) {
        self.isLoading = isLoading
    }
}

/// Per-render context the cross-platform leaf passes through the seam to the gated web view, so a
/// navigation in the live `WKWebView` writes its new address + title BACK into the pane's
/// ``PaneSpec/webURL`` / ``PaneSpec/title`` (the persistence write-back, so a restored web pane reopens
/// the same page — ``WorkspaceStore`` `setPaneWebURL`). Closures, so this type is intentionally not
/// `Sendable`/`Equatable` (matching ``RemotePaneContext``).
public struct WebPaneContext {
    /// Called when the live web view commits a navigation to `url` — the leaf forwards it to
    /// `store.setPaneWebURL(url.absoluteString, for: paneID)` (dirty-guarded write-back).
    public var onNavigated: (URL) -> Void
    /// Called when the page's `<title>` changes — the leaf can promote it into the pane title (a web pane
    /// is titled after the loaded page). `nil`-safe: a default no-op leaves the title untouched.
    public var onTitle: (String) -> Void
    /// The live web view publishes its ``WebPaneController`` here once it exists (and `nil` on teardown), so
    /// the chrome's Back / Forward / hard-Reload can drive the page — the additive IN-channel mirroring
    /// ``RemotePaneContext/onKeyInjectorReady``. `nil` (the standalone default) ⇒ no live view; Back /
    /// Forward stay greyed and Reload re-issues the address bar (the headless fallback).
    public var onControllerReady: ((WebPaneController?) -> Void)?

    public init(
        onNavigated: @escaping (URL) -> Void = { _ in },
        onTitle: @escaping (String) -> Void = { _ in },
        onControllerReady: ((WebPaneController?) -> Void)? = nil,
    ) {
        self.onNavigated = onNavigated
        self.onTitle = onTitle
        self.onControllerReady = onControllerReady
    }

    /// The standalone default (no store around it): no-op callbacks — for previews / the headless
    /// placeholder, which never navigates.
    public static var standalone: Self { Self() }
}

/// Injects the production local web-browser view when the app target provides one (it links `WebKit`).
/// `nil` → the gated placeholder is shown (the headless library + every test register no factory, so a
/// `WKWebView` is never built off the GUI path).
@preconcurrency
@MainActor
public final class WebRendererFactory {
    /// App-registered factory (set once at launch). `nil` → use the placeholder. Receives the descriptor +
    /// the per-render ``WebPaneContext`` (the navigation / title write-back closures).
    public static var shared: ((WebPaneDescriptor, WebPaneContext) -> AnyView)?

    /// Builds the web-pane view: the registered production renderer if present, else an empty view (the
    /// headless build registers no factory; the rebuilt `AislopdeskClientUI` `WebLeafView` provides the
    /// real placeholder body around this seam).
    public static func make(_ descriptor: WebPaneDescriptor, context: WebPaneContext = .standalone) -> AnyView {
        if let factory = shared {
            return factory(descriptor, context)
        }
        return AnyView(EmptyView())
    }
}
#endif
