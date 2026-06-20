#if canImport(SwiftUI)
import SwiftUI

/// The terminal screen: hosts the ``TerminalRenderingView`` seam (production
/// `GhosttyTerminalView` via ``TerminalRendererFactory``, or the BUILD-STATUS placeholder),
/// full-bleed. Binds a ``TerminalViewModel``.
///
/// The view itself is renderer-agnostic — it just asks the factory for the rendering view. The
/// per-pane header (title + connection-status dot) is owned by ``PaneChromeView``, which wraps every
/// leaf, so this view no longer draws its own title/status strip (#25 — it overlaid live output). The
/// byte pipeline is driven by `observe(client:)`, started by the embedding scene (`AislopdeskClientApp`) so
/// this view can be reused inside the split layout.
public struct TerminalScreenView: View {
    @State private var model: TerminalViewModel
    /// The pane's workspace focus, threaded to the renderer so only the focused pane takes the macOS
    /// keyboard first responder (a plain `let`, NOT `@State`, so a focus change re-renders and updates
    /// the renderer; the model stays stable in `@State`). Defaults to `true` for the single-pane /
    /// preview callers that do not thread focus.
    private let isFocused: Bool

    /// W14 #5: whether the ⌘F find bar is showing over this pane. Owned here as VIEW state (not the tree);
    /// ⌘F / the right-click "Find…" flip it through ``TerminalViewModel/onRequestFind`` (wired below).
    @State private var isFindPresented = false

    /// WB2: whether the Command Navigator popover is showing over this pane. VIEW state (not the tree);
    /// ⌃⌘O / the chrome chip flip it through ``TerminalViewModel/onRequestBlockNavigator`` (wired below).
    @State private var isNavigatorPresented = false

    /// WB2: whether to draw the slim ``StickyCommandHeader`` overlay at the top of each pane. DEFAULT-OFF
    /// so panes are CHROME-LESS like Muxy (the block info is still reachable via the ⌃⌘O Command Navigator
    /// below — only the always-on top strip is gone, which also stops it overlaying the terminal's top
    /// rows). Opt back in with `AISLOPDESK_STICKY_BLOCK_HEADER=1` (default-OFF idiom: only "1" enables).
    private static let stickyHeaderEnabled =
        ProcessInfo.processInfo.environment["AISLOPDESK_STICKY_BLOCK_HEADER"] == "1"

    public init(model: TerminalViewModel, isFocused: Bool = true) {
        _model = State(initialValue: model)
        self.isFocused = isFocused
    }

    public var body: some View {
        // #25: the inner title/status strip was REMOVED — it was dead weight that OVERLAID the live
        // terminal output (the `.top`-aligned HStack sat on top of the first rows). `PaneChromeView`
        // already owns the per-pane header (kind glyph + title + connection-status dot + split/zoom/
        // close buttons) and wraps every leaf, so this strip duplicated that chrome while obscuring
        // text. The renderer is now full-bleed; the ZStack is kept so future overlays (e.g. a bell
        // flash) have an anchor without reintroducing a layout shift.
        ZStack(alignment: .top) {
            // The renderer seam — production GhosttyTerminalView, or the placeholder.
            TerminalRendererFactory.make(model: model, isFocused: isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Glitch caret (docs/31 #3): the dim "input received, echo pending" nudge.
            // A SwiftUI sibling overlay, never an NSView sublayer — libghostty owns the
            // renderer view's layer slot (the orphaned-CAMetalLayer freeze class), and
            // the C API exposes no cursor readback, so the honest v1 anchors to the
            // pane corner instead of pretending to know the cell.
            if model.glitchCaretVisible {
                GlitchCaretOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false) // the pane has a history of scroll-swallowing chrome
                    .transition(.opacity)
            }
            // WB2: the sticky command header — a slim overlay pinned at the TOP showing the CURRENT block's
            // command + running spinner / exit badge. DEFAULT-OFF (Muxy-clean panes); the block info lives
            // in the ⌃⌘O Command Navigator. Opt back in with AISLOPDESK_STICKY_BLOCK_HEADER=1.
            if Self.stickyHeaderEnabled {
                StickyCommandHeader(model: model)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            // W14 #5: the find-in-terminal bar, top-trailing so it doesn't cover the prompt.
            if isFindPresented {
                TerminalFindBar(model: model, isPresented: $isFindPresented)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // WB2: the Command Navigator popover (⌃⌘O / the chrome chip). A popover on macOS anchors near the
        // pane; on iOS SwiftUI presents it as a sheet automatically. Pure-block-list content; the surface
        // jump + copy-output flows are exercised on real hardware.
        .popover(isPresented: $isNavigatorPresented, arrowEdge: .top) {
            CommandNavigatorView(model: model, isPresented: $isNavigatorPresented)
        }
        // The visibility flips happen in plain (un-animated) model code — without an
        // animation bound to the VALUE the .transition above would be skipped and the
        // caret would pop. Scoped to this value so nothing else animates.
        .animation(.easeInOut(duration: 0.15), value: model.glitchCaretVisible)
        .animation(.easeInOut(duration: 0.15), value: isFindPresented)
        .onAppear {
            // ⌘F / right-click "Find…" toggle the bar through the model's find request (set here so the
            // closure captures THIS pane's @State; the leaf's onRequestFind is set on the same model).
            model.onRequestFind = { isFindPresented.toggle() }
            // WB2: ⌃⌘O / the chrome chip toggle the Command Navigator through the model's request hook
            // (same pattern — captures THIS pane's @State on the same model the store reaches).
            model.onRequestBlockNavigator = { isNavigatorPresented.toggle() }
        }
    }
}

/// The glitch-window speculative caret (docs/17 §2.4): a dim pulsing bar, deliberately
/// distinct from libghostty's own block cursor — advisory "your keystroke was sent,
/// the echo is in flight", never a position claim.
struct GlitchCaretOverlay: View {
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.secondary.opacity(pulsing ? 0.45 : 0.18))
            .frame(width: 7, height: 15)
            .padding(12)
            .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

// `StatusDot` was removed with the inner status strip (#25). The shared, more capable
// ``PaneStatusDot`` (in `PaneStatusIndicator.swift`) is the one source of truth for the connection
// dot, used by `PaneChromeView` (per-pane header) and `TabSidebarView`.
#endif
