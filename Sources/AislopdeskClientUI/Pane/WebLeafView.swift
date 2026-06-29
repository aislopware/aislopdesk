// WebLeafView — the content of a LOCAL web pane (`PaneKind.web`) leaf (E18 WI-4; otty
// `spec/user-interface__files-and-links.md` › Web Browser Pane, `web-broswer.png`).
//
// The web parallel of ``TerminalLeafView`` / ``GuiLeafView``: it renders the otty browser chrome — the
// address bar + back / forward / reload / close controls — over the headless-safe ``WebRendererFactory``
// seam. The real `WKWebView` is built ONLY by the Xcode app target (which links `WebKit`) and registered as
// `WebRendererFactory.shared` at launch, exactly like `VideoWindowFactory`; this cross-platform library
// NEVER imports `WebKit` and never instantiates a `WKWebView` (the CLAUDE.md hang-safety rule — a `WKWebView`
// is a GUI/WebKit object like `SCStream` / `VTCompressionSession`). When no factory is registered (a headless
// `swift build`, a preview, or a unit test) the content area renders a clearly-labelled placeholder instead.
//
// FUNCTIONAL through the seam: the address bar normalizes its input through ``WebURLNormalizer``
// (bare host → `https://`, free text → DuckDuckGo, a malformed / `javascript:` / `file:` string is DROPPED —
// validate-then-drop), writes the resolved address back into the pane's ``PaneSpec/webURL`` via
// `store.setPaneWebURL` (so a restored pane reopens the same page), and feeds it to the factory as
// `WebPaneDescriptor.initialURL`. A navigation INSIDE the live page (link click / redirect) flows BACK through
// `WebPaneContext.onNavigated` to track the address bar + persist.
//
// LIVE CONTROL: the `WKWebView`'s `goBack` / `goForward` / hard-`reload` ride the additive control sink on
// ``WebPaneContext`` (``onControllerReady`` — the proven `RemotePaneContext` `onKeyInjectorReady` hand-back
// pattern). The production `WebPaneView` publishes a ``WebPaneController`` once the view exists; this leaf
// holds it on the model and enables Back / Forward from its `canGoBack` / `canGoForward` history (greyed when
// there is no live view, faithful to `web-broswer.png`). Headless (no factory) ⇒ no controller, so Back /
// Forward stay disabled and Reload re-issues the current address through the navigate channel.
//
// The whole pane is keyed `.id(PaneID)` by ``SplitContainer``, so this view's `@State WebPaneModel` is
// per-pane (no cross-pane bleed). `Otty.*` tokens only (raw font / radius literals fail
// `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// The per-pane web-browser view-model: the editable address-bar text + the URL the ``WebRendererFactory``
/// should be showing. HEADLESS + hang-safe — it touches no `WKWebView`, only ``WebURLNormalizer`` — so the
/// GUI and the headless unit test (`WebPaneModelTests`) drive the SAME logic. `@Observable` so the chrome
/// re-renders on every edit / navigation; held as `@State` by ``WebLeafView`` (per-pane).
@MainActor
@Observable
final class WebPaneModel {
    /// The editable address-bar text (bound to the field). Free text while the user types; on submit it is
    /// replaced by the canonical absolute URL the input resolved to.
    var addressText: String

    /// The URL the gated web view should be showing — `nil` for a fresh / blank pane. Drives
    /// ``WebPaneDescriptor/initialURL``; a change re-navigates the live view (the app-target `updateNSView`).
    private(set) var requestedURL: URL?

    /// The live web view's navigation controller — published by the production `WebPaneView` through
    /// ``WebPaneContext/onControllerReady`` once the `WKWebView` exists (and `nil` on teardown / headless).
    /// Drives the chrome's Back / Forward / hard-Reload; `nil` ⇒ no live page (Back / Forward greyed,
    /// Reload re-issues the address bar).
    var controller: WebPaneController?

    /// Whether Back is available — `false` with no live controller (greyed, per `web-broswer.png`).
    var canGoBack: Bool { controller?.canGoBack ?? false }
    /// Whether Forward is available — `false` with no live controller (greyed at the tip of history).
    var canGoForward: Bool { controller?.canGoForward ?? false }
    /// Whether the live page is loading — drives the leftmost ✗ button's Stop-vs-Close role. `false` with no
    /// live controller (a headless placeholder never loads), so the button is Close.
    var isLoading: Bool { controller?.isLoading ?? false }

    init(initialAddress: String?) {
        addressText = initialAddress ?? ""
        requestedURL = initialAddress.flatMap { URL(string: $0) }
    }

    /// Back / Forward in the chrome → drive the live page (no-op without a live controller; the button is
    /// disabled in that state, so this is belt-and-braces).
    func goBack() { controller?.goBack() }
    func goForward() { controller?.goForward() }

    /// Reload in the chrome: hard-reload the LIVE page when a controller is present (keeps history / POST
    /// state), else fall back to re-issuing the current address through ``navigate(onCommit:)`` (the headless
    /// path, where there is no live `WKWebView` to reload).
    func reload(onCommit: (URL) -> Void) {
        if let controller {
            controller.reload()
        } else {
            _ = navigate(onCommit: onCommit)
        }
    }

    /// Submit the address bar: normalize (validate-then-drop a malformed / non-`http(s)` string → no
    /// navigation, `nil`), load it, reflect the canonical form back into the field, and notify `onCommit`
    /// (the ``PaneSpec/webURL`` persistence write-back). Returns the resolved URL (`nil` when dropped) so the
    /// headless test can assert the policy without a GUI.
    @discardableResult
    func navigate(onCommit: (URL) -> Void) -> URL? {
        guard let url = WebURLNormalizer.normalize(addressText) else { return nil }
        requestedURL = url
        addressText = url.absoluteString
        onCommit(url)
        return url
    }

    /// Hard-reload the LIVE page ignoring the cache (the ⌘⇧R browser idiom) — drives the controller's
    /// `reloadFromOrigin`. No-op without a live controller (headless / no live `WKWebView`).
    func hardReload() { controller?.hardReload() }

    /// Stop the live page's in-flight load — the ✗ button's "Stop" role while `isLoading`. No-op without a
    /// live controller.
    func stop() { controller?.stop() }

    /// Present the live page's native find-in-page UI (⌘F) through the controller. No-op without a live
    /// controller (the headless placeholder has nothing to search).
    func find() { controller?.find() }

    /// The live web view committed a navigation to `url` (a link click / redirect inside the page) — reflect
    /// it into the address bar + the requested URL so the chrome tracks the page. Does NOT call the commit
    /// closure: the ``WebPaneContext/onNavigated`` site forwards the store write-back separately (so the
    /// model stays free of the store, keeping it headless-testable).
    func didNavigate(to url: URL) {
        requestedURL = url
        addressText = url.absoluteString
    }

    /// Sync the model to an EXTERNAL address change on the spec — the initial stamp after `openWebPane`, or an
    /// Open-In-Place re-navigation of THIS pane. DIRTY-GUARDED: a no-op when already showing `address` (so a
    /// write-back round-trip can't churn the field). A `nil`/empty external address leaves the model untouched.
    func syncExternal(address: String?) {
        guard let address, !address.isEmpty, address != requestedURL?.absoluteString else { return }
        addressText = address
        requestedURL = URL(string: address)
    }
}

struct WebLeafView: View {
    /// The live workspace store — the address write-back (`setPaneWebURL`) + the close actuator
    /// (`requestClosePane`) sink, and the source of the pane's reactive ``PaneSpec/webURL``.
    let store: WorkspaceStore
    /// This pane's id — the spec / write-back / close key.
    let paneID: PaneID
    /// Workspace focus → forwarded for parity with the other leaves (the container already dims the
    /// unfocused panes, so this view applies no extra focus treatment).
    var isFocused: Bool = false
    /// EAGER/STATIC render path for headless ImageRenderer snapshots — always renders the placeholder, never
    /// a live `WKWebView` (no WebKit in an `ImageRenderer`).
    var staticMirror: Bool = false

    /// Per-pane browser state, seeded from the persisted address. `.id(PaneID)`-keyed leaf ⇒ this is per-pane.
    @State private var model: WebPaneModel

    /// Opens the current page in the system browser (cross-platform — no AppKit/UIKit import, so this view
    /// type-checks unchanged on the iOS slice).
    @Environment(\.openURL) private var openURL

    init(store: WorkspaceStore, paneID: PaneID, isFocused: Bool = false, staticMirror: Bool = false) {
        self.store = store
        self.paneID = paneID
        self.isFocused = isFocused
        self.staticMirror = staticMirror
        let seed = store.tree.activeSession?.specs[paneID]?.webURL
        _model = State(initialValue: WebPaneModel(initialAddress: seed))
    }

    /// The pane's persisted address — reactive (reading it in `body` re-renders on a store change), so an
    /// external `openWebPane` stamp or Open-In-Place re-navigation flows into the field via `.onChange`.
    private var specAddress: String? { store.tree.activeSession?.specs[paneID]?.webURL }

    var body: some View {
        VStack(spacing: 0) {
            addressChrome
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            webContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
        // The otty web-browser chords (web-broswer.png / files-and-links.md › Web Browser Pane), SCOPED to
        // THIS pane's focus — see `webShortcuts`.
        .background(webShortcuts)
        // External address changes (the initial `openWebPane` stamp, or an Open-In-Place re-nav of THIS pane)
        // land in the field; `syncExternal` dirty-guards against the write-back echo.
        .onChange(of: specAddress) { _, address in model.syncExternal(address: address) }
    }

    // MARK: - Focus-scoped browser keyboard shortcuts (otty: ⌘[ ⌘] ⌘R ⌘⇧R ⌘F)

    /// The documented web-pane chords (`spec/user-interface__files-and-links.md` › Web Browser Pane) as
    /// hidden, focus-gated `.keyboardShortcut` buttons. They are SCOPED to this pane via `.disabled(!isFocused)`
    /// — a disabled button's shortcut never fires, so only the FOCUSED web pane owns these chords (no
    /// cross-pane leak; ⌘[ / ⌘] still cycle panes when a non-web pane is focused). On macOS the app-level
    /// `WorkspaceKeyDispatcher` (which preempts the responder chain) YIELDS ⌘[ / ⌘] / ⌘⇧R / ⌘F to the focused
    /// web pane so these buttons receive them rather than the global pane-cycle / Details / Find bindings;
    /// plain ⌘R is unbound globally and reaches here directly. Back / Forward are additionally gated by the
    /// live history (`canGoBack` / `canGoForward`), faithful to web-broswer.png.
    private var webShortcuts: some View {
        Group {
            Button("Back", action: model.goBack)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward", action: model.goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            Button("Reload") { model.reload(onCommit: commit) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Reload Ignoring Cache", action: model.hardReload)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Find", action: model.find)
                .keyboardShortcut("f", modifiers: .command)
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(!isFocused)
    }

    // MARK: - Address-bar chrome (matches web-broswer.png: ✕ ‹ › ↻ [address] ⬆)

    private var addressChrome: some View {
        HStack(spacing: Otty.Metric.space1) {
            // Leftmost ✗ (web-broswer.png): STOP the in-flight load while the page is loading, else CLOSE the
            // pane — the browser stop/close idiom (same glyph, role flips with `model.isLoading`).
            OttyPlateButton(
                symbol: .xmark,
                help: model.isLoading ? "Stop loading" : "Close pane",
            ) {
                if model.isLoading { model.stop() } else { store.requestClosePane(paneID) }
            }
            // Back / Forward drive the live page through the `WebPaneController` the production WebPaneView
            // publishes; enabled by its `canGoBack` / `canGoForward` history (greyed when there is no live
            // view or at the ends of history — faithful to web-broswer.png).
            OttyPlateButton(symbol: .chevronLeft, help: "Back") { model.goBack() }
                .disabled(!model.canGoBack)
            OttyPlateButton(symbol: .chevronRight, help: "Forward") { model.goForward() }
                .disabled(!model.canGoForward)
            OttyPlateButton(symbol: .arrowClockwise, help: "Reload") { model.reload(onCommit: commit) }
            addressField
            OttyPlateButton(symbol: .squareAndArrowUp, help: "Open in browser") { openExternally() }
        }
        .padding(.horizontal, Otty.Metric.space2)
        .padding(.vertical, Otty.Metric.space1)
        .background(Otty.Surface.window)
    }

    private var addressField: some View {
        TextField("Search or enter address", text: addressBinding)
            .textFieldStyle(.plain)
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.primary)
            .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Otty.Metric.space2)
            .padding(.vertical, Otty.Metric.space1)
            .background(Otty.Surface.element, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
            )
            .onSubmit { _ = model.navigate(onCommit: commit) }
    }

    /// Two-way binding into the model's editable address text (read live, write straight through so the
    /// `@Observable` re-renders on every keystroke).
    private var addressBinding: Binding<String> {
        Binding(get: { model.addressText }, set: { model.addressText = $0 })
    }

    // MARK: - Web content (the gated factory seam, else a placeholder)

    @ViewBuilder private var webContent: some View {
        if !staticMirror, WebRendererFactory.shared != nil {
            // The app target registered a real `WKWebView` view — mount it through the seam (non-persistent
            // store + no-autoplay are the production view's concern, per WebPaneSeam's doc).
            WebRendererFactory.make(descriptor, context: makeContext())
        } else {
            placeholder
        }
    }

    private var descriptor: WebPaneDescriptor {
        WebPaneDescriptor(paneID: paneID, initialURL: model.requestedURL)
    }

    /// The per-render seam context: a navigation inside the live page reflects into the chrome AND persists
    /// the new address. Captures locals (not `self`) + a `weak` model so a context the factory retains can't
    /// keep a torn-down pane's model alive (the `.id(PaneID)` identity hazard).
    private func makeContext() -> WebPaneContext {
        let store = store
        let paneID = paneID
        return WebPaneContext(
            onNavigated: { [weak model] url in
                model?.didNavigate(to: url)
                store.setPaneWebURL(url.absoluteString, for: paneID)
            },
            // The loaded page's `<title>` promotes into the pane / rail tab label (otty parity): persist it
            // onto the spec's `lastKnownTitle` (dirty-guarded), which the rail + titlebar resolve ahead of the
            // static "Web" default. Captures the store + paneID locals (not `self`), like `onNavigated`.
            onTitle: { title in store.setPaneWebTitle(title, for: paneID) },
            // The live WebPaneView hands back its navigation controller (and `nil` on teardown); hold it on
            // the model so the chrome's Back / Forward / Reload drive the page (mirrors GuiLeafView's
            // `onKeyInjectorReady` → `model.keyInjector` hand-back).
            onControllerReady: { [weak model] controller in model?.controller = controller },
        )
    }

    private var placeholder: some View {
        VStack(spacing: Otty.Metric.space3) {
            Image(systemSymbol: .globe)
                .font(.system(size: Otty.Typeface.display, weight: .regular))
                .foregroundStyle(Otty.Text.secondary)
            Text("web pane")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Text(
                "The built-in browser (WKWebView) is registered by the app target. The headless build renders this panel.",
            )
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.secondary)
            .multilineTextAlignment(.center)
            if let address = model.requestedURL?.absoluteString {
                Text(address)
                    .font(.system(size: Otty.Typeface.footnote).monospaced())
                    .foregroundStyle(Otty.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(Otty.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    // MARK: - Actuators

    /// The address write-back: persist the resolved URL onto the pane's spec (dirty-guarded in the store), so
    /// a restored web pane reopens the same page.
    private func commit(_ url: URL) {
        store.setPaneWebURL(url.absoluteString, for: paneID)
    }

    private func openExternally() {
        guard let url = model.requestedURL else { return }
        openURL(url)
    }
}
#endif
