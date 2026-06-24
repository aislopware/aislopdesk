// PaneDivider — the resize handle between two split panes (REBUILD-V2, L2). A thin separator hairline
// drawn inside a comfortable hit band; a resize cursor on hover (no hover COLOR change); drag previews the
// new seam position LOCALLY and only commits the split ratio to the store on release; double-click resets
// the split to even.
//
// REMOTE-APP RULE (why commit-on-release): every `store.resizeDividerTree` re-solves the layout and re-emits
// a terminal-grid / remote-window resize. Doing that on every drag frame floods the wire and (worse) moves
// THIS divider out from under the cursor mid-drag — the gesture then chases its own host view and the seam
// barely travels (the old "can't drag the divider more than a sliver" bug). So the drag holds a live,
// view-local translation in `@GestureState`, draws a ghost seam at that offset, and fires ONE
// `onResize(...)` from `.onEnded` — the exact idiom `WorkspaceStore.moveFloating` already uses.
//
// The drag→weight-delta conversion: the TOTAL pixel translation along the split axis is divided by the
// parent span (scaled by the flex-weight sum) to get a flex-weight delta (pure, tested in `PaneMath`).
//
// Hit-test guardrail (repo memory): the FAT transparent hit band gets `.contentShape(Rectangle())` over a
// thin visual hairline INSIDE the `.frame` that matches the handle rect — the SplitContainer applies
// `.position(...)` to this whole view, so the hit area travels WITH the handle. SYSTEM colours only (the
// accent ghost is a drag affordance, not a hover state).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneDivider: View {
    let handle: SplitTreeRenderModel.DividerHandle
    /// The owning split's span (points) along the split axis — divides a pixel drag into a weight delta.
    let axisSpan: CGFloat
    /// The owning split's flex-weight sum — scales the pixel→weight conversion so the seam tracks the
    /// cursor 1:1 (a 50/50 split has `flexSum == 2`). Defaults to the handle's own `flexSum`.
    var flexSum: CGFloat = 1
    /// Drag → weight delta (TOTAL, fired once on release). Wired to `store.resizeDividerTree`.
    var onResize: (_ delta: Double) -> Void = { _ in }
    /// Double-click → reset split to even. Wired to `store.balanceActivePaneSplits`.
    var onReset: () -> Void = {}

    /// The drawn hairline thickness (the hit band is the handle rect; the line is thinner + crisp).
    private let hairline: CGFloat = 1

    /// SwiftUI-owned transient drag translation along the split axis (points) — auto-resets to 0 on every
    /// gesture end/cancel/interrupt. Drives the ghost-seam preview; the store is untouched until `.onEnded`.
    @GestureState private var dragTranslation: CGFloat = 0

    private var isDragging: Bool { dragTranslation != 0 }

    var body: some View {
        ZStack {
            // Transparent hit band (the full handle rect) — grabbable.
            Color.clear.contentShape(Rectangle())
            // The crisp resting hairline centered in the band (hidden while a ghost is previewed).
            hairlineShape(color: NativePaneColor.separator, thickness: hairline)
                .opacity(isDragging ? 0 : 1)
            // The live ghost seam — accent-coloured, a touch thicker, offset by the (clamped) drag.
            hairlineShape(color: Otty.State.accent, thickness: Otty.Metric.dividerHoverWidth)
                .offset(
                    x: handle.axis == .horizontal ? previewOffset : 0,
                    y: handle.axis == .horizontal ? 0 : previewOffset,
                )
                .opacity(isDragging ? 1 : 0)
        }
        .frame(width: handle.rect.width, height: handle.rect.height)
        #if os(macOS)
            .pointerStyle(handle.axis == .horizontal ? .columnResize : .rowResize)
        #endif
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragTranslation) { value, state, _ in
                        state = handle.axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                    }
                    .onEnded { value in
                        let total = handle.axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        // Convert the TOTAL pixel translation → a flex-weight delta over the owning split's
                        // span (pure, tested in PaneMath; guards a zero/NaN span/flexSum). Commit once; the
                        // store clamps the weight at its min-weight floor.
                        let delta = PaneMath.weightDelta(
                            pixelIncrement: total,
                            axisSpan: axisSpan,
                            flexSum: flexSum,
                        )
                        guard delta != 0 else { return }
                        onResize(delta)
                    },
            )
            .onTapGesture(count: 2) { onReset() }
            .animation(Otty.Anim.dividerHover, value: isDragging)
    }

    /// The ghost seam's pixel offset along the split axis, clamped so the preview can't fly past the split
    /// (the commit is clamped independently at the store's min-weight floor). Ordered min/max (NaN-faithful).
    private var previewOffset: CGFloat {
        let bound = Double.maximum(Double(axisSpan) * 0.9, 0)
        return CGFloat(Double.minimum(Double.maximum(Double(dragTranslation), -bound), bound))
    }

    @ViewBuilder
    private func hairlineShape(color: Color, thickness: CGFloat) -> some View {
        if handle.axis == .horizontal {
            Rectangle().fill(color).frame(width: thickness)
        } else {
            Rectangle().fill(color).frame(height: thickness)
        }
    }
}
#endif
