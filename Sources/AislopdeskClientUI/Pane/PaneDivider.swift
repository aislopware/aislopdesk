// PaneDivider — the resize handle between two split panes (REBUILD-V2, L2). A thin separator hairline
// drawn inside a comfortable hit band; a resize cursor on hover (no hover COLOR change); drag updates the
// split ratio in the store (sum-preserving `resizeDividerTree`); double-click resets the split to even.
//
// The drag→weight-delta conversion: a pixel drag along the split axis is divided by the parent span to get
// a flex-weight delta (pure, tested in `PaneMath`). We accumulate the last reported translation and send
// only the incremental delta so repeated `onChanged` callbacks compose correctly.
//
// Hit-test guardrail (repo memory): the FAT transparent hit band gets `.contentShape(Rectangle())` over a
// thin visual hairline INSIDE the `.frame` that matches the handle rect — the SplitContainer applies
// `.position(...)` to this whole view, so the hit area travels WITH the handle. SYSTEM colours only.

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
    /// Drag → weight delta (incremental). Wired to `store.resizeDividerTree`.
    var onResize: (_ delta: Double) -> Void = { _ in }
    /// Double-click → reset split to even. Wired to `store.balanceActivePaneSplits`.
    var onReset: () -> Void = {}

    /// The drawn hairline thickness (the hit band is the handle rect; the line is thinner + crisp).
    private let hairline: CGFloat = 1

    /// SwiftUI-owned transient drag baseline — auto-resets to 0 on every gesture end/cancel/interrupt, so
    /// the next drag always starts from a clean baseline even if `onEnded` never fired (a relayout mid-drag
    /// removes the host view, so an interrupted drag is a realistic trigger).
    @GestureState private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            // Transparent hit band (the full handle rect) — grabbable.
            Color.clear.contentShape(Rectangle())
            // The crisp hairline centered in the band (no hover color change).
            hairlineShape
        }
        .frame(width: handle.rect.width, height: handle.rect.height)
        #if os(macOS)
            .pointerStyle(handle.axis == .horizontal ? .columnResize : .rowResize)
        #endif
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($lastTranslation) { value, lastTranslation, _ in
                        let translation = handle.axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let increment = translation - lastTranslation
                        lastTranslation = translation
                        // Convert the pixel increment → a flex-weight delta over the owning split's span
                        // (pure, tested in PaneMath; guards a zero/NaN span/flexSum via ordered compares).
                        let delta = PaneMath.weightDelta(
                            pixelIncrement: increment,
                            axisSpan: axisSpan,
                            flexSum: flexSum,
                        )
                        guard delta != 0 else { return }
                        onResize(delta)
                    },
            )
            .onTapGesture(count: 2) { onReset() }
    }

    @ViewBuilder private var hairlineShape: some View {
        if handle.axis == .horizontal {
            Rectangle().fill(NativePaneColor.separator).frame(width: hairline)
        } else {
            Rectangle().fill(NativePaneColor.separator).frame(height: hairline)
        }
    }
}
#endif
