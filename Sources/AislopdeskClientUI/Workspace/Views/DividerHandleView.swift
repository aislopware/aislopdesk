#if canImport(SwiftUI)
import SwiftUI

// MARK: - DividerHandleView (the draggable split divider — W5)

/// A draggable divider between two adjacent siblings of a split (docs/42 W5). It is positioned by
/// ``SplitTreeView`` from a ``SplitTreeRenderModel/DividerHandle`` and converts a pixel drag along the
/// split's axis into a sum-preserving flex-weight `delta`, committing through
/// ``WorkspaceStore/resizeDividerTree(splitID:leadingChildIndex:delta:)``.
///
/// ### Pixel → weight conversion
/// The op shifts FLEX WEIGHT between the two children; a drag is in points. The render model gives the
/// handle's span (the parent rect's extent along the split axis) and the two siblings' current pixel
/// extents — but the simplest robust conversion the view can do without re-solving is: `Δweight ≈
/// Δpixels / axisLength × pairFlexSum`. The pair's flex sum is not known to the view, so we approximate it
/// from the two siblings' *pixel* extents (their share of the axis IS their share of the flex sum, since
/// the cross-axis is shared) — i.e. `Δweight ≈ Δpixels / pairPixelLength × pairWeightSum`, and with the
/// weight sum unknown we drive the op with the *normalized* delta `Δpixels / pairPixelLength` scaled by a
/// nominal pair-sum. Because ``WorkspaceTreeOps/resizeDivider`` re-clamps and re-normalizes, a small
/// per-event delta tracks the cursor closely; the cumulative drag stays stable. The committed delta is
/// applied INCREMENTALLY per `.onChanged` translation step (the previous translation is subtracted) so
/// the op's sum-preserving shift follows the finger.
struct DividerHandleView: View {
    let handle: SplitTreeRenderModel.DividerHandle
    /// The full pixel length the two siblings share along the split axis (the parent extent), used to
    /// convert a pixel drag into a proportional weight delta.
    let pairPixelLength: CGFloat
    let store: WorkspaceStore

    /// The translation already applied this drag (so each `.onChanged` applies only the new increment).
    @State private var appliedTranslation: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        let isHorizontal = handle.axis == .horizontal
        Rectangle()
            .fill(Color.clear) // the whole band is the hit target; the visible hairline is the overlay
            .overlay {
                // A thin centered hairline that brightens on hover/drag — the affordance.
                let line = RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.18))
                if isHorizontal {
                    line.frame(width: 1.5)
                } else {
                    line.frame(height: 1.5)
                }
            }
            .frame(width: handle.rect.width, height: handle.rect.height)
            .position(x: handle.rect.midX, y: handle.rect.midY)
            .contentShape(Rectangle())
        #if os(macOS)
            .onHover { hovering = $0 }
            // The native resize cursor while hovering the band.
            .pointerStyle(isHorizontal ? .columnResize : .rowResize)
        #endif
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let raw = isHorizontal ? value.translation.width : value.translation.height
                        let increment = raw - appliedTranslation
                        appliedTranslation = raw
                        guard pairPixelLength > 0 else { return }
                        // Proportional weight delta for this increment (the op clamps + sum-preserves).
                        let delta = Double(increment) / Double(pairPixelLength)
                        store.resizeDividerTree(
                            splitID: handle.splitID,
                            leadingChildIndex: handle.childIndex,
                            delta: delta,
                        )
                    }
                    .onEnded { _ in appliedTranslation = 0 },
            )
    }
}
#endif
