// AislopdeskSplitViewController — the macOS shell (REBUILD-V2, L1). An `NSSplitViewController` with
// three `NSSplitViewItem`s (sidebar | content | inspector), each an `NSHostingController` over a SwiftUI
// column. Modelled on CodeEdit's `CodeEditSplitViewController`: an AppKit split shell with SwiftUI INSIDE
// each column. Keeping the split in AppKit (not a SwiftUI `HSplitView` that rebuilds subtrees) is the
// load-bearing no-teardown choice for L2's libghostty panes — a torn-down NSView kills the surface.
//
// L4a wires the toolbar collapse toggles into the sidebar/inspector `NSSplitViewItem`s (via
// `applyCollapse`) and threads `connection` into the inspector's Session section.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import ObjectiveC
import SwiftUI

final class AislopdeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let chrome: WorkspaceChromeState
    /// Opens the Connect-to-Host editor — wired into the inspector's Status row (ES-E2-6). The shell binds
    /// this to `overlay.openConnect()`; the no-op default keeps the controller buildable without an overlay.
    private let onConnect: () -> Void

    /// Retained so the titlebar toggles can animate their collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        chrome: WorkspaceChromeState,
        onConnect: @escaping () -> Void = {},
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.onConnect = onConnect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — AislopdeskSplitViewController is created in code")
    }

    /// Coalesces the bursts of `NSSplitView.didResizeSubviewsNotification` a divider (or window-edge) drag
    /// emits: `true` once the burst starts, flipped back `false` `resizeSettleDelay` after it stops.
    private var resizeForwardingSuspended = false
    private var resizeSettleWork: DispatchWorkItem?
    private let resizeSettleDelay: TimeInterval = 0.1

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin
        // FLAT DIVIDER: the default `.thin` NSSplitView draws its divider PURE BLACK in `drawDivider(in:)`,
        // a harsh "đen xì" seam on the lighter Monokai chrome. We cannot subclass `NSSplitView` via `loadView`
        // (it traps `_setupSplitView` during the controller's constraint setup — see the OBSERVE note below),
        // so we let the controller build its default split view, then ISA-SWIZZLE that fully-set-up instance
        // to a subclass that ONLY overrides `drawDivider(in:)` to fill the divider with the flat theme
        // backdrop. `object_setClass` is memory-safe here — `FlatDividerSplitView` adds no stored properties
        // (identical ivar layout) — and side-steps the constructor path that traps.
        object_setClass(splitView, FlatDividerSplitView.self)

        // 1) Sidebar — the navigator (sessions / panes). A PLAIN split item, NOT
        //    `NSSplitViewItem(sidebarWithViewController:)`: the native sidebar style paints system vibrancy +
        //    inset-grouped/rounded selection, which is the "native SwiftUI rounded corners" look we are
        //    replacing. A plain item lets `NavigatorColumn` paint otty's flat warm panel + white-card rows.
        //    Holding priority above the content's default so window-resize grows the content, not the sidebar.
        let navigator = NSHostingController(rootView: NavigatorColumn(store: store))
        let sidebarItem = NSSplitViewItem(viewController: navigator)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        // 2) Content — the pane grid (terminal / claude / remote) + otty's hover-reveal titlebar overlay.
        //    The non-collapsible centre. `chrome` drives the titlebar's sidebar/Details toggles.
        let content = NSHostingController(
            rootView: ContentColumn(store: store, connection: connection, chrome: chrome),
        )
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420

        // 3) Inspector — the Session + Commands navigator (host/ping/agent status + the active pane's
        //    command blocks). HIDDEN by default so the resting window is otty's two-column (sidebar | content)
        //    silhouette; revealed from the toolbar (L4a). Matches otty, whose Details panel is hidden until
        //    ⌘⇧R.
        let inspector = NSHostingController(
            rootView: InspectorColumn(store: store, connection: connection, onConnect: onConnect),
        )

        // Each column hosts SwiftUI in its own NSHostingController, which by DEFAULT insets its content below
        // the window's titlebar safe area (the traffic-light strip). With `.hiddenTitleBar` that pushed every
        // column's top chrome — the hover-reveal titlebar's centred title + Details toggle, and the sidebar's
        // "TABS" header — a full row BELOW the traffic lights. Dropping the safe-area regions lets each column
        // start at the window's top edge, so the titlebar's controls land ON the traffic-light row (each
        // column still reserves its own titlebar-height strip at the top).
        navigator.safeAreaRegions = []
        content.safeAreaRegions = []
        inspector.safeAreaRegions = []

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        self.sidebarItem = sidebarItem
        self.inspectorItem = inspectorItem

        // Defer remote terminal grid-resize forwarding while a sidebar/inspector divider (or the window edge)
        // is being dragged: NSSplitView re-lays its subviews every step and posts this notification, so each
        // step would otherwise be a host PTY reflow + a re-streamed redraw. We pause forwarding on the first
        // step and flush the FINAL grid once the drag settles (see `splitViewSubviewsDidResize`). We OBSERVE
        // the default split view rather than subclassing it — a custom `NSSplitView` destabilises
        // `NSSplitViewController._setupSplitView` and traps during constraint setup.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewSubviewsDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
        )

        // D3: SwiftUI `@Environment`/`.preferredColorScheme` does NOT cross into the three
        // `NSHostingController` columns, so a runtime theme change can't be observed inside them. Observe
        // the appearance-changed notification (posted by the `AppearanceApplier` hook after it repoints
        // `ThemeStore.shared`) and re-pin the WINDOW appearance + nudge each column to re-read the tokens —
        // otherwise the window half-repaints (the chrome flips but the columns keep the old palette).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeStore.didChangeNotification,
            object: nil,
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Resume terminal grid-resize forwarding if the column disappears mid-drag. The settle that resumes it is
    /// a `[weak self]` work item fired ~`resizeSettleDelay` after the last step; were this controller torn down
    /// inside that window (window closed mid-resize), the work item would early-return on the nil `self` and
    /// leave forwarding suspended (the next session on the SAME store would never flush its grid). Resuming
    /// here on a real lifecycle hook (not a timer) closes that gap.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        guard resizeForwardingSuspended else { return }
        resizeSettleWork?.cancel()
        resizeForwardingSuspended = false
        store.setTerminalResizeSuspended(false)
    }

    /// One step of a divider/window-edge resize burst: suspend remote terminal resize forwarding on the first
    /// step, then (re)arm a settle timer that resumes + flushes the final grid `resizeSettleDelay` after the
    /// last step — i.e. when the drag is released. Commit-on-release, without subclassing the split view.
    @objc
    private func splitViewSubviewsDidResize(_: Notification) {
        if !resizeForwardingSuspended {
            resizeForwardingSuspended = true
            store.setTerminalResizeSuspended(true)
        }
        resizeSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            resizeForwardingSuspended = false
            store.setTerminalResizeSuspended(false) // flush the grid the drag settled on
        }
        resizeSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeSettleDelay, execute: work)
    }

    /// Pin the WINDOW's appearance to the active otty theme. The three columns are hosted in
    /// `NSHostingController`s inside this AppKit split controller, so they do NOT inherit the SwiftUI
    /// `.preferredColorScheme` set on `WorkspaceRootView` — any system-dynamic colour / material in a column
    /// would otherwise resolve to the OS appearance and clash with the pinned otty palette (e.g. white text
    /// on the light Paper chrome when the user's Mac is in Dark mode). Setting it on the NSWindow propagates
    /// to every hosted NSView. Done in `viewDidAppear` because the window only exists once attached.
    override func viewDidAppear() {
        super.viewDidAppear()
        pinWindowAppearance()
    }

    /// Pin the WINDOW's `NSAppearance` to the active otty theme. Factored out so both `viewDidAppear` (first
    /// attach) and `themeDidChange` (runtime switch) drive the SAME re-pin.
    private func pinWindowAppearance() {
        // Concrete sRGB backdrop (NOT `NSColor(Otty.theme.window)`): the SwiftUI-Color→NSColor bridge resolves
        // through the effective appearance and left the divider reading black on the LIGHT themes; a plain
        // sRGB triple is appearance-stable. The theme's `terminalBackgroundHex` IS the flat window tone in hex.
        let backdrop = NSColor(ottyHex6: Otty.theme.terminalBackgroundHex)
        view.window?.appearance = NSAppearance(named: Otty.theme.isLight ? .aqua : .darkAqua)
        view.window?.backgroundColor = backdrop
        // The sidebar/content divider is the 1px GAP between the hosting columns. Once the split view is
        // layer-backed (it hosts layer-backed `NSHostingController` columns) `drawDivider(in:)` is bypassed and
        // the gap shows the split view's OWN backdrop — the default dark seam, invisible on the dark themes but
        // a black line on the LIGHT ones. Pin that backdrop to the faint DIVIDER tone (the theme hairline
        // composited over the window tone) so the seam reads as the SAME mờ-mờ line as the pane dividers
        // (which draw `Otty.Line.divider` over the flat pane) — theme-aware, in both appearances.
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = flatDividerTone().cgColor
        splitView.needsDisplay = true
    }

    /// React to a runtime theme switch (the `AppearanceApplier` hook already repointed `ThemeStore.shared`).
    /// Re-pin the window appearance AND force each hosted column to re-read the otty tokens — a SwiftUI
    /// `@Observable` change inside `ThemeStore` re-renders views that READ it, but the AppKit window
    /// appearance + any system-dynamic resolution must be re-pinned explicitly here (the boundary SwiftUI
    /// observation does not cross). `needsDisplay` on each column view nudges a redraw so no pane is left
    /// half-painted in the old palette.
    @objc
    private func themeDidChange() {
        pinWindowAppearance()
        for item in splitViewItems {
            item.viewController.view.needsDisplay = true
        }
    }

    /// Apply the toolbar collapse flags to the sidebar/inspector items (idempotent — only animates a real
    /// change so a steady-state update doesn't re-trigger the animation).
    func applyCollapse(sidebarCollapsed: Bool, inspectorCollapsed: Bool) {
        if let sidebarItem, sidebarItem.isCollapsed != sidebarCollapsed {
            sidebarItem.animator().isCollapsed = sidebarCollapsed
        }
        if let inspectorItem, inspectorItem.isCollapsed != inspectorCollapsed {
            inspectorItem.animator().isCollapsed = inspectorCollapsed
        }
    }
}

/// A drop-in `NSSplitView` whose ONLY change is a flat, theme-coloured divider — installed via
/// `object_setClass` onto the controller's already-built split view (so it never goes through the
/// `NSSplitViewController` construction path that traps `_setupSplitView` when a custom split view is
/// supplied up front). `drawDivider(in:)` fills the 1px `.thin` divider rect with the active otty backdrop,
/// so the sidebar/content/inspector seam blends into the flat chrome instead of AppKit's default pure-black
/// hairline. Adds NO stored properties — the isa-swizzle keeps the original instance's ivar layout intact.
private final class FlatDividerSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        flatDividerTone().setFill()
        NSBezierPath(rect: rect).fill()
    }
}

/// The flat divider tone: the theme hairline ``Otty/Line/divider`` composited OVER the flat window backdrop
/// into an OPAQUE sRGB colour, so the 1px split gap reads as the SAME faint line as the pane dividers (which
/// draw that hairline over the flat pane) — in BOTH appearances. Built from concrete sRGB components (the
/// window tone from the theme hex, the overlay resolved through `.sRGB`) so it never resolves to black on the
/// light themes the way a raw `NSColor(_: SwiftUI.Color)` fill did.
@MainActor
private func flatDividerTone() -> NSColor {
    let backdrop = NSColor(ottyHex6: Otty.theme.terminalBackgroundHex)
    guard let base = backdrop.usingColorSpace(.sRGB),
          let overlay = NSColor(Otty.theme.divider).usingColorSpace(.sRGB) else { return backdrop }
    let a = overlay.alphaComponent
    return NSColor(
        srgbRed: base.redComponent * (1 - a) + overlay.redComponent * a,
        green: base.greenComponent * (1 - a) + overlay.greenComponent * a,
        blue: base.blueComponent * (1 - a) + overlay.blueComponent * a,
        alpha: 1,
    )
}

private extension NSColor {
    /// Concrete sRGB `NSColor` from a 6-hex backdrop string (the theme's flat window tone). Avoids the
    /// appearance-sensitivity of `NSColor(_: SwiftUI.Color)` — a plain sRGB triple resolves identically in
    /// `.aqua` and `.darkAqua`, so the flat divider no longer reads black on the light themes.
    convenience init(ottyHex6 hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#endif
