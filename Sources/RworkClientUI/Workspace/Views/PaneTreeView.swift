#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneTreeView (the recursive split walker)

/// Recursively renders one ``PaneNode`` for a tab (docs/22 §3): a `.split` becomes a
/// ``SplitContainer`` of recursively-rendered children with draggable dividers; a `.leaf` becomes a
/// ``PaneChromeView`` wrapping ``PaneLeafView``.
///
/// ### Identity is load-bearing (docs/22 §7, §11.2)
/// Every leaf carries `.id(id)` where `id` is the leaf's ``PaneID``. A `PaneID` is stable for the
/// pane's whole session — split/close/resize/zoom/focus re-renders never change it — so a tree
/// reshape (e.g. a sibling split that re-nests this leaf deeper) NEVER rewires this leaf's live
/// session: SwiftUI keys the host view by `PaneID`, so the same `GhosttySurface` / video pipeline /
/// input `Coordinator` is reused, never torn down and rebuilt. If we keyed by structural position
/// instead, a reshape would silently swap surfaces between live panes — the exact hazard this `.id`
/// prevents.
///
/// ### Zoom is presentation, not surgery (docs/22 §3)
/// If the tab has a `zoomedPane`, the walker renders only that leaf full-bleed and skips the split
/// tree entirely. The tree and the registry are untouched (no materialize/teardown on zoom), and the
/// zoomed leaf keeps the SAME `.id`, so zooming never tears down its live session.
///
/// ### Geometry feedback (docs/22 §2.1, §3)
/// At the root, the view solves `LayoutSolver.solve(root, in:size, minLeaf:)` for the rendered size
/// and reports it to the store via ``WorkspaceStore/updateSolvedLayout(_:)`` so geometric focus
/// `move(.left/.right/.up/.down)` resolves against the exact rects the user sees. This is a view-only
/// read — it never mutates the tree, so reporting it never reconciles.
struct PaneTreeView: View {
    /// The node to render (the tab root at the top level; a child node in recursion).
    let node: PaneNode
    /// The child-index path from the root to `node` (empty at the root). Forwarded to the store so a
    /// divider drag in a nested split maps back to the right `settingFractions(at:)` address.
    let path: [Int]
    /// The store (read for handles/focus/zoom, written for split/close/focus/resize).
    let store: WorkspaceStore
    /// The tab this tree belongs to.
    let tab: TabID

    /// The minimum on-screen footprint of a single leaf, in points. Below this the responsive layer
    /// collapses to compact (docs/22 §3) — here it only bounds the divider clamp / solver floor.
    private static let minLeaf = CGSize(width: 160, height: 120)

    init(node: PaneNode, path: [Int] = [], store: WorkspaceStore, tab: TabID) {
        self.node = node
        self.path = path
        self.store = store
        self.tab = tab
    }

    var body: some View {
        // At the root, honour zoom and report the solved layout for geometric focus.
        if path.isEmpty {
            rootBody
        } else {
            nodeBody
        }
    }

    // MARK: Root (zoom + layout reporting)

    @ViewBuilder
    private var rootBody: some View {
        if let zoomed = activeTab?.zoomedPane, node.spec(for: zoomed) != nil {
            // Zoom: render only the zoomed leaf full-bleed. Same `.id`, so the live session survives.
            leafView(id: zoomed, spec: node.spec(for: zoomed)!)
                .padding(4)
        } else {
            nodeBody
                .background(layoutReporter)
        }
    }

    /// A zero-cost background that solves the layout for the rendered size and feeds it to the store
    /// (geometric focus source of truth). `.onChange` keeps it current across resizes/reshapes; the
    /// solve is pure and cheap (docs/22 §2.1).
    private var layoutReporter: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { reportLayout(size: geo.size) }
                .onChange(of: geo.size) { _, newSize in reportLayout(size: newSize) }
                .onChange(of: node) { _, _ in reportLayout(size: geo.size) }
        }
    }

    private func reportLayout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        store.updateSolvedLayout(LayoutSolver.solve(node, in: size, minLeaf: Self.minLeaf))
    }

    // MARK: Recursion

    @ViewBuilder
    private var nodeBody: some View {
        switch node {
        case let .leaf(id, spec):
            leafView(id: id, spec: spec)

        case let .split(axis, children, fractions):
            SplitContainer(
                axis: axis,
                fractions: fractions,
                minFraction: minFraction(forChildCount: children.count),
                onResize: { newFractions in
                    store.setFractions(tab: tab, path: path, to: newFractions)
                }
            ) { i in
                PaneTreeView(node: children[i], path: path + [i], store: store, tab: tab)
            }
            // Isolate child re-layout so a mid-drag preview doesn't cascade into descendant splits.
            .geometryGroup()
        }
    }

    /// A single leaf cell: chrome wrapping the leaf content, keyed by `PaneID` (the identity contract
    /// above), focusable on tap.
    private func leafView(id: PaneID, spec: PaneSpec) -> some View {
        PaneChromeView(
            id: id,
            spec: spec,
            handle: store.handle(for: id),
            isFocused: store.isFocused(id),
            isZoomed: activeTab?.zoomedPane == id,
            store: store
        ) {
            // The regular tree can show MULTIPLE terminal hosts at once (iPad-regular), so each routes
            // first-responder through the store's `focusCoordinator` (resign-before-become + generation
            // reject — docs/22 §7). The compact carousel mounts ONE host and passes nil (no race).
            PaneLeafView(
                handle: store.handle(for: id),
                spec: spec,
                isFocused: store.isFocused(id),
                focusCoordinator: store.focusCoordinator
            )
        }
        // STABLE identity: PaneID, NOT structural position — a reshape never rewires a live session.
        .id(id)
        .contentShape(Rectangle())
        .onTapGesture { store.focus(id) }
        .padding(2)
    }

    // MARK: Helpers

    /// The active tab (read for zoom/focus). `nil` only transiently during teardown.
    private var activeTab: Tab? {
        store.workspace.tabs.first { $0.id == tab }
    }

    /// A divider's minimum child fraction: enough that no child of an N-way split can shrink below a
    /// sane share. A coarse floor — the real min-size guarantee is the responsive collapse to compact.
    private func minFraction(forChildCount count: Int) -> Double {
        guard count > 1 else { return 0 }
        // At most a third of an even share, so a 2-way split can go ~17/83 before clamping.
        return (1.0 / Double(count)) / 3.0
    }
}
#endif
