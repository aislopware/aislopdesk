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
    /// The active session + tab to render. Passed by ``SplitWorkspaceView`` so this view stays a pure
    /// function of (tab, bounds) — it does not re-derive the active tab itself.
    let session: Session
    let tab: Tab

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
        store.updateSolvedLayout(SolvedLayout(frames: placement))
    }
}
#endif
