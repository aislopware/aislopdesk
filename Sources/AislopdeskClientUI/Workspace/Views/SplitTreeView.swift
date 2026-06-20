#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - SplitTreeView (the recursive tiled split content — W5)

/// The active tab's recursive ``SplitNode`` tree, laid out by the pure ``SplitTreeRenderModel`` and
/// rendering a **reused** ``PaneLeafView`` (wrapped in the repurposed ``PaneChromeView``) per leaf, with
/// draggable ``DividerHandleView``s between siblings (docs/42 W5). Replaces `CanvasView` as the detail
/// content.
///
/// ### Absolute placement + the no-teardown zoom trick
/// Every leaf of the tab is mounted **once** and positioned at its solved rect via `.position`. A zoom
/// (`tab.zoomedPane`) renders the zoomed leaf full-bounds; the OTHER leaves stay MOUNTED at `opacity 0`
/// + `allowsHitTesting(false)` (the proven `CanvasView` no-teardown trick — a SwiftUI subtree swap would
/// rebuild the libghostty surface and replay stale bytes). So `SplitTreeRenderModel` need only place the
/// visible leaves; the hidden ones are parked off the layout.
///
/// The store reports the solved layout (`updateSolvedLayout`) so geometric focus moves (`moveFocusTree`)
/// resolve against the exact rects the user sees.
struct SplitTreeView: View {
    @Bindable var store: WorkspaceStore
    /// The session + tab to render. Passed by ``SplitWorkspaceView`` so this view stays a pure
    /// function of (tab, bounds) — it does not re-derive the active tab itself.
    let session: Session
    let tab: Tab
    /// Whether THIS tab is the one on screen. ``SplitWorkspaceView`` mounts EVERY tab of every session
    /// at once (so a libghostty surface is never torn down + recreated on a tab/session switch — the
    /// recreate is what reflowed the grid and dropped a segment of the prompt) and hides the inactive
    /// ones at `opacity 0`. Only the active tab reports its solved layout to the store (the focus
    /// resolver's single source of truth) — otherwise a hidden tab would clobber it.
    var isActive: Bool = true

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
            let visible = Set(layout.leaves.map(\.id))
            let placement = Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })

            ZStack(alignment: .topLeading) {
                // Every leaf of the tab is mounted once (so libghostty surfaces persist across zoom / tab
                // switches). A visible leaf sits at its solved rect; a hidden one (zoomed-away) stays
                // mounted at opacity 0 with hit-testing off.
                ForEach(tab.allPaneIDs(), id: \.self) { id in
                    leaf(id: id, rect: placement[id] ?? bounds, isVisible: visible.contains(id))
                }

                // Dividers between adjacent siblings (none when zoomed / single-leaf). Each converts a pixel
                // drag into a sum-preserving flex-weight shift via the store.
                ForEach(Array(layout.dividers.enumerated()), id: \.offset) { _, divider in
                    // Fills the bounds; its hit region is constrained to the seam band by an internal
                    // `contentShape(DividerBandShape)` in absolute bounds coords — so off-seam drags fall
                    // through to the pane below and ONLY the band resizes.
                    DividerHandleView(
                        handle: divider,
                        pairPixelLength: pairPixelLength(for: divider, in: bounds),
                        store: store,
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Report the solved active-tab layout so geometric focus moves resolve against these rects.
            .onChange(of: geo.size) { _, _ in reportLayout(placement) }
            .onAppear { reportLayout(placement) }
            // When this tab BECOMES the active one (a tab/session switch flips it visible without a
            // remount), re-publish its solved layout so geometric focus moves resolve against it.
            .onChange(of: isActive) { _, active in if active { reportLayout(placement) } }
        }
        .background(.background)
    }

    // MARK: Leaf

    @ViewBuilder
    private func leaf(id: PaneID, rect: CGRect, isVisible: Bool) -> some View {
        let spec = store.tree.spec(for: id) ?? PaneSpec(kind: .terminal, title: "Terminal")
        PaneChromeView(
            id: id,
            spec: spec,
            handle: store.handle(for: id),
            isFocused: tab.activePane == id,
            isZoomed: tab.zoomedPane == id,
            store: store,
        ) {
            PaneLeafView(
                handle: store.handle(for: id),
                spec: spec,
                isFocused: tab.activePane == id,
                focusCoordinator: store.focusCoordinator,
                store: store,
            )
        }
        .padding(2)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        // The no-teardown trick: a zoomed-away leaf stays MOUNTED but invisible + inert.
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        // W14 #10: wire the terminal right-click menu's "Split Right / Split Down" to the store for THIS
        // leaf (find self-wires in TerminalScreenView). A non-terminal / faked leaf has no model → no-op.
        .onAppear { wireContextMenu(for: id) }
    }

    /// Points the leaf's terminal model's context-menu split callback at the store (W14 #10). Captures only
    /// `store` + `id` (both stable). No-op for a leaf without a live terminal model.
    private func wireContextMenu(for id: PaneID) {
        guard let live = store.handle(for: id) as? LivePaneSession,
              let model = live.terminalModel else { return }
        model.onContextMenuSplit = { [weak store] horizontal in
            store?.splitPaneTree(id, axis: horizontal ? .horizontal : .vertical, kind: .terminal)
        }
    }

    // MARK: Geometry helpers

    /// The pixel length the divider's two siblings share along the split axis — used by
    /// `DividerHandleView` to convert a pixel drag into a proportional weight delta. The parent rect of a
    /// nested split is not carried on the handle, so we approximate it with the FULL bounds extent along
    /// the split axis (the parent is ≤ the bounds): for a top-level split this is exact, and for a nested
    /// one it under-scales the delta slightly (a marginally less sensitive drag) — harmless, since
    /// ``WorkspaceTreeOps/resizeDivider`` re-clamps + sum-preserves regardless.
    private func pairPixelLength(for divider: SplitTreeRenderModel.DividerHandle, in bounds: CGRect) -> CGFloat {
        switch divider.axis {
        case .horizontal: bounds.width
        case .vertical: bounds.height
        }
    }

    private func reportLayout(_ placement: [PaneID: CGRect]) {
        // Only the on-screen tab owns the store's solved layout (focus-resolver source of truth); a hidden
        // mounted tab must NOT overwrite it.
        guard isActive else { return }
        store.updateSolvedLayout(SolvedLayout(frames: placement))
    }
}
#endif
