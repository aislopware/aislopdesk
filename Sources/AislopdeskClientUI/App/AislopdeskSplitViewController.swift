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
import SwiftUI

final class AislopdeskSplitViewController: NSSplitViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection

    /// Retained so the toolbar toggles can animate their collapse (set in `viewDidLoad`).
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?

    init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported — AislopdeskSplitViewController is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin

        // 1) Sidebar — the navigator (sessions / panes). Collapsible, spring-loaded so a drag over the
        //    collapsed edge reveals it. Width clamped to a sidebar-typical range.
        let navigator = NSHostingController(rootView: NavigatorColumn(store: store))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isSpringLoaded = true

        // 2) Content — the pane grid (terminal / claude / remote). The non-collapsible centre.
        let content = NSHostingController(rootView: ContentColumn(store: store, connection: connection))
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 420

        // 3) Inspector — the Session + Commands navigator (host/ping/agent status + the active pane's
        //    command blocks). Visible by default (L3); toggled from the toolbar (L4a).
        let inspector = NSHostingController(rootView: InspectorColumn(store: store, connection: connection))
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.isCollapsed = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        self.sidebarItem = sidebarItem
        self.inspectorItem = inspectorItem
    }

    /// Pin the WINDOW's appearance to the active otty theme. The three columns are hosted in
    /// `NSHostingController`s inside this AppKit split controller, so they do NOT inherit the SwiftUI
    /// `.preferredColorScheme` set on `WorkspaceRootView` — any system-dynamic colour / material in a column
    /// would otherwise resolve to the OS appearance and clash with the pinned otty palette (e.g. white text
    /// on the light Paper chrome when the user's Mac is in Dark mode). Setting it on the NSWindow propagates
    /// to every hosted NSView. Done in `viewDidAppear` because the window only exists once attached.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.appearance = NSAppearance(named: Otty.theme.isLight ? .aqua : .darkAqua)
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
#endif
