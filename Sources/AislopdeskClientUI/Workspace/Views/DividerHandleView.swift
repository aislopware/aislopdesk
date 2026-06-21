// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - DividerHandleView (the draggable split divider — W5, Muxy ResizeHandle look)

/// A draggable divider between two adjacent siblings of a split (docs/42 W5). It is positioned by
/// ``SplitTreeView`` from a ``SplitTreeRenderModel/DividerHandle`` and converts a pixel drag along the
/// split's axis into a sum-preserving flex-weight `delta`, committing through
/// ``WorkspaceStore/resizeDividerTree(splitID:leadingChildIndex:delta:)``.
///
/// ### Muxy ResizeHandle visual
/// A 1px-thin VISIBLE line on the seam (``AislopdeskTheme/border`` at rest, ``AislopdeskTheme/accent``
/// while hovering or dragging) with a TRANSPARENT ``UIMetrics/resizeHandleHitArea`` (18pt) hit overlay on
/// the cross-axis carrying the gesture + the resize cursor. No fat fill band — the seam reads as a hairline.
///
/// ### Pixel → weight conversion
/// The op shifts FLEX WEIGHT between the two children; a drag is in points. We drive the op with the
/// *normalized* delta `Δpixels / pairPixelLength`; ``WorkspaceTreeOps/resizeDivider`` re-clamps and
/// re-normalizes, so a small per-event delta tracks the cursor closely and the cumulative drag stays
/// stable. The committed delta is applied INCREMENTALLY per `.onChanged` translation step (the previous
/// translation is subtracted) so the op's sum-preserving shift follows the finger.
struct DividerHandleView: View {
    let handle: SplitTreeRenderModel.DividerHandle
    /// The full pixel length the two siblings share along the split axis (the parent extent), used to
    /// convert a pixel drag into a proportional weight delta.
    let pairPixelLength: CGFloat
    let store: WorkspaceStore

    /// The translation already applied this drag (so each `.onChanged` applies only the new increment).
    @State private var appliedTranslation: CGFloat = 0
    @State private var hovering = false
    @GestureState private var dragging = false

    /// Reduce-Motion gate: the at-rest↔accent seam fade is tokenized motion, so it honours the system
    /// preference (via ``DSMotion/resolve(_:reduceMotion:)`` → a near-instant crossfade) per the spec's
    /// Motion section, rather than hardcoding the 0.13s ease.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Active = hovered OR mid-drag → the seam line washes to accent (Muxy `active`).
    private var active: Bool { hovering || dragging }

    /// The seam line colour, a PURE function of `active` (P3b). At REST the seam is
    /// ``DSColor/borderComponent`` (white·0.11) — discoverable over the sunken gutter but recessive (the
    /// legacy `AislopdeskTheme.border` = white·0.07 was invisible dark-on-dark, the "can't find the seam"
    /// bug). Hover/drag washes to ``DSColor/focusRing`` (== accentSolid). Extracted so the at-rest-discoverable
    /// vs active-accent mapping is unit-testable headlessly.
    @MainActor
    static func lineColor(active: Bool) -> Color {
        active ? DSColor.focusRing : DSColor.borderComponent
    }

    var body: some View {
        let isHorizontal = handle.axis == .horizontal
        // A thin band sized to the seam and placed by `.position`. THE MODIFIER ORDER IS LOAD-BEARING:
        //   • `.contentShape(Rectangle())` is applied to the band FRAME *before* `.position` — so the hit
        //     shape is the band, and `.position` then relocates that hit shape together with the view.
        //   • `.gesture` is applied *after* `.position` — so it hit-tests the band at its FINAL on-screen
        //     location.
        // The two earlier wrong orders, for the record: `.contentShape` AFTER `.position` expands the hit
        // area to the whole tab (every drag resizes + the terminal never sees the mouse — the reported
        // "mọi thao tác chuột đều resize" bug); `.gesture` BEFORE `.position` leaves the gesture's hit
        // region at the pre-position origin, so dragging the visible seam does nothing.
        //
        // Muxy ResizeHandle: a 1px VISIBLE line (border → accent on hover/drag) is the seam; a transparent
        // 18pt `resizeHandleHitArea` cross-axis strip OVERLAYS it to carry the grab. The transparent strip
        // is the band frame that gets `.contentShape` (so the 18pt zone is hittable), keeping the seam a
        // crisp hairline rather than the old fat fill band.
        Color.clear
            .overlay {
                // The crisp 1px hairline at the band's centre. P3b: `DSColor.borderComponent` (white·0.11) at
                // REST — discoverable over the sunken gutter, vs the old invisible `AislopdeskTheme.border`
                // (white·0.07) — washing to `DSColor.focusRing` (accent) when active, via `Self.lineColor`.
                // The colour swap eases with `DSMotion.hover` (0.13s easeOut), collapsed to a near-instant
                // crossfade under Reduce Motion via `DSMotion.resolve`. The animation is STRICTLY
                // `value:`-scoped to `active` so it ONLY animates the at-rest↔accent colour fade — it must NOT
                // animate the `.position` relocations during a SplitTreeView relayout (an unscoped
                // `.animation` here would make the divider slide on resize).
                Rectangle()
                    .fill(Self.lineColor(active: active))
                    .frame(width: isHorizontal ? 1 : nil, height: isHorizontal ? nil : 1)
                    .animation(DSMotion.resolve(DSMotion.hover, reduceMotion: reduceMotion), value: active)
            }
            .frame(
                width: isHorizontal ? UIMetrics.resizeHandleHitArea : handle.rect.width,
                height: isHorizontal ? handle.rect.height : UIMetrics.resizeHandleHitArea,
            )
            .contentShape(Rectangle())
            .position(x: handle.rect.midX, y: handle.rect.midY)
        #if os(macOS)
            // The native resize cursor while hovering the strip (wrap NSCursor for the AppKit gate).
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hovering = true
                    (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                case .ended:
                    hovering = false
                    if !dragging { NSCursor.arrow.set() }
                }
            }
        #endif
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragging) { _, state, _ in state = true }
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
