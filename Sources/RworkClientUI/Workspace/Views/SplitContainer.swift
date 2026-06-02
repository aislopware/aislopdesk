#if canImport(SwiftUI)
import SwiftUI

// MARK: - SplitContainer (the one hand-rolled resizable splitter)

/// A single split level: N children laid out side-by-side (`.horizontal`) or stacked
/// (`.vertical`) along `axis`, sized by `fractions`, with a draggable handle in each gap
/// (docs/22 §3).
///
/// There is no native cross-platform N-way resizable splitter (`NSSplitView`/`HSplitView` is
/// AppKit-only and forbidden here), so this is the ONE hand-rolled layout view in the app — kept
/// minimal, with all geometry math pushed into the pure `LayoutSolver` / `PaneNode.settingFractions`
/// upstream. This view only converts a drag translation into a fraction delta and forwards the
/// **committed** result via ``onResize`` (docs/22 §3 "ratios live in the model").
///
/// ### The resize gesture model (docs/22 §3 the resize-storm guard)
/// During a drag we show a LIVE preview by perturbing a `@GestureState` delta — the parent store is
/// **not** mutated per frame (no `setFractions` storm down to `sendResize`/`TIOCSWINSZ`). Only on
/// `.onEnded` do we compute the final fractions and call ``onResize`` exactly once. `@GestureState`
/// auto-resets to the identity delta when the gesture ends, so the view snaps to the model's new
/// (committed) fractions with no flicker. `.geometryGroup()` (applied by the caller) isolates child
/// re-layout so a mid-drag preview never cascades into descendant splits.
struct SplitContainer<Content: View>: View {
    /// The split's orientation: `.horizontal` lays children left-to-right, `.vertical` top-to-bottom.
    let axis: SplitAxis
    /// The committed, normalized fractions from the model (one per child, summing to ≈ 1).
    let fractions: [Double]
    /// The minimum share any single child may shrink to during a drag (a fraction of the total).
    /// Clamps both the dragged edge and its neighbour so neither pane is crushed below the floor.
    let minFraction: Double
    /// Commit hook: called ONCE on drag-end with the new full fractions array. The store maps this
    /// straight to `PaneNode.settingFractions(at:to:)` (docs/22 §3).
    let onResize: ([Double]) -> Void
    /// Builds child `i` (the recursive `PaneTreeView` for `children[i]`).
    @ViewBuilder let content: (Int) -> Content

    /// The live drag delta for the divider currently being dragged, as a fraction of the total
    /// length — `nil` when no drag is in flight. `@GestureState` so it auto-resets to `nil` the
    /// instant the gesture ends (the model then owns the committed value). The tuple is
    /// `(gapIndex, fractionDelta)`: which divider, and how much length moves from `children[i]` to
    /// `children[i+1]` (negative = the other way).
    @GestureState private var liveDrag: (gap: Int, delta: Double)?

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            // The previewed fractions = committed fractions + the in-flight drag delta applied to
            // the dragged gap's two adjacent children (everyone else is untouched).
            let shown = previewFractions(in: total)
            let lengths = childLengths(shown, total: total)

            stack {
                ForEach(Array(fractions.indices), id: \.self) { i in
                    content(i)
                        .frame(
                            width: axis == .horizontal ? lengths[i] : nil,
                            height: axis == .vertical ? lengths[i] : nil
                        )
                    // A divider after every child except the last.
                    if i < fractions.count - 1 {
                        DividerHandleView(
                            axis: axis,
                            gesture: dragGesture(gap: i, total: total)
                        )
                    }
                }
            }
        }
    }

    // MARK: Layout helpers

    /// The stack that arranges children along the axis (no inter-child spacing — the divider IS the
    /// gap). `HStack` for `.horizontal`, `VStack` for `.vertical`.
    @ViewBuilder
    private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) { content() }
        } else {
            VStack(spacing: 0) { content() }
        }
    }

    /// The fractions to render this frame: the committed `fractions`, plus — if a drag is in flight —
    /// the delta moved between the dragged gap's two adjacent children, clamped so neither drops
    /// below ``minFraction``.
    private func previewFractions(in total: CGFloat) -> [Double] {
        guard let drag = liveDrag, fractions.indices.contains(drag.gap),
              fractions.indices.contains(drag.gap + 1) else {
            return fractions
        }
        return Self.applyingDelta(fractions, gap: drag.gap, delta: drag.delta, minFraction: minFraction)
    }

    /// Splits the available length (after reserving the divider thicknesses) across children by
    /// `fractions`. Mirrors `LayoutSolver`'s allocation so the rendered widths match the solved
    /// layout the store uses for geometric focus.
    private func childLengths(_ fractions: [Double], total: CGFloat) -> [CGFloat] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let reserved = LayoutSolver.dividerThickness * CGFloat(max(count - 1, 0))
        let available = max(total - reserved, 0)
        return fractions.map { max(available * CGFloat($0), 0) }
    }

    // MARK: Drag

    /// The divider drag for gap `i`: live-previews via `@GestureState` (no store mutation), commits
    /// the final fractions once on `.onEnded`.
    private func dragGesture(gap: Int, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($liveDrag) { value, state, _ in
                guard total > 0 else { return }
                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                state = (gap, Double(translation / total))
            }
            .onEnded { value in
                guard total > 0 else { return }
                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                let committed = Self.applyingDelta(
                    fractions, gap: gap, delta: Double(translation / total), minFraction: minFraction
                )
                onResize(committed)
            }
    }

    // MARK: Pure fraction math (static so it is trivially correct + reused by preview AND commit)

    /// Moves `delta` of the total from `children[gap]` to `children[gap + 1]` (negative = the other
    /// direction), clamping so neither falls below `minFraction`. Only the two adjacent children
    /// change; the rest keep their share, so the array still sums to ≈ 1.
    static func applyingDelta(_ fractions: [Double], gap: Int, delta: Double, minFraction: Double) -> [Double] {
        guard fractions.indices.contains(gap), fractions.indices.contains(gap + 1) else { return fractions }
        var result = fractions
        let pairTotal = result[gap] + result[gap + 1]
        // Clamp the moved amount so both ends stay ≥ minFraction within their shared budget.
        let lo = minFraction - result[gap]                  // most we can take from `gap`
        let hi = result[gap + 1] - minFraction              // most we can give to `gap`
        let clamped = min(max(delta, lo), max(hi, lo))      // keep the interval well-ordered
        result[gap] += clamped
        result[gap + 1] = pairTotal - result[gap]
        return result
    }
}

// MARK: - DividerHandleView (the thin native grab handle)

/// The thin, hover-aware grab handle drawn in a split gap. Visually a hairline; hit-tested over the
/// full ``LayoutSolver/dividerThickness`` so it is comfortable to grab. On macOS it shows the
/// resize cursor on hover; on iOS the wide `contentShape` is the touch affordance (docs/22 §3).
private struct DividerHandleView<G: Gesture>: View {
    let axis: SplitAxis
    let gesture: G

    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(
                width: axis == .horizontal ? LayoutSolver.dividerThickness : nil,
                height: axis == .vertical ? LayoutSolver.dividerThickness : nil
            )
            .overlay {
                // A hairline down the centre of the gap; brightens while hovering for affordance.
                Rectangle()
                    .fill(hovering ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12))
                    .frame(
                        width: axis == .horizontal ? (hovering ? 2 : 1) : nil,
                        height: axis == .vertical ? (hovering ? 2 : 1) : nil
                    )
            }
            .contentShape(Rectangle())
            .gesture(gesture)
            #if os(macOS)
            .onHover { inside in
                hovering = inside
                // The native column/row resize cursor while hovering the handle.
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }
}
#endif
