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
        // A thin band sized to the seam and placed by `.position`. THE MODIFIER ORDER IS LOAD-BEARING:
        //   • `.contentShape(Rectangle())` is applied to the band FRAME *before* `.position` — so the hit
        //     shape is the 16pt band, and `.position` then relocates that hit shape together with the view.
        //   • `.gesture` is applied *after* `.position` — so it hit-tests the band at its FINAL on-screen
        //     location.
        // The two earlier wrong orders, for the record: `.contentShape` AFTER `.position` expands the hit
        // area to the whole tab (every drag resizes + the terminal never sees the mouse — the reported
        // "mọi thao tác chuột đều resize" bug); `.gesture` BEFORE `.position` leaves the gesture's hit
        // region at the pre-position origin, so dragging the visible seam does nothing.
        Rectangle()
            // A faint fill (NOT clear): an opaque-enough fill is independently hit-testable, so the drag
            // works without depending on contentShape edge-cases — and it makes the 16pt grab band faintly
            // visible (the seam's draggable zone), brightening on hover.
            // A visible, hittable fill (a clear/near-transparent fill is NOT reliably hit-tested in this
            // ZStack+position layout): the 16pt grab band reads as a real divider strip and brightens on
            // hover, so the seam is obviously draggable.
            .fill(hovering ? Color.accentColor.opacity(0.40) : Color.primary.opacity(0.18))
            .overlay {
                // The visible hairline at the band's centre (thin; the 16pt band is just the grab target).
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: isHorizontal ? 1.5 : nil, height: isHorizontal ? nil : 1.5)
            }
            .frame(width: handle.rect.width, height: handle.rect.height)
            .contentShape(Rectangle())
            .position(x: handle.rect.midX, y: handle.rect.midY)
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
