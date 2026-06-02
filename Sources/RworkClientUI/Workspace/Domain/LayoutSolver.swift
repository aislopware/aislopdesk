import Foundation
import CoreGraphics

// MARK: - Solved geometry types

/// One draggable divider between two adjacent siblings of a split.
///
/// `path` addresses the split node from the root (the sequence of child indices), and `index` is
/// *which gap* within that split — the divider sits between `children[index]` and
/// `children[index + 1]`. That `(path, index)` pair is exactly what the view forwards to
/// ``PaneNode/settingFractions(at:to:)`` after a drag, so the geometry the user grabs maps
/// straight back to the model with no ambiguity (docs/22 §2.1, §3).
public struct DividerHandle: Sendable, Equatable {
    /// Child-index path from the root to the owning split node (empty = the root is the split).
    public let path: [Int]
    /// Which gap in that split: between `children[index]` and `children[index + 1]`.
    public let index: Int
    /// The split's axis — i.e. the orientation the divider resizes along.
    public let axis: SplitAxis
    /// The divider's hit rect in the same coordinate space as the pane frames.
    public let rect: CGRect
    public init(path: [Int], index: Int, axis: SplitAxis, rect: CGRect) {
        self.path = path
        self.index = index
        self.axis = axis
        self.rect = rect
    }
}

/// The fully solved layout for a tree at a given size: every leaf's exact rect, plus every
/// divider's rect. This is the **single geometry source of truth** (docs/22 §1.3, §2.1) consumed
/// by BOTH the rendered split layout AND ``FocusResolver`` — so "move focus left" can never
/// disagree with the pane the user actually sees to the left.
public struct SolvedLayout: Sendable, Equatable {
    public let frames: [PaneID: CGRect]
    public let dividers: [DividerHandle]
    public init(frames: [PaneID: CGRect], dividers: [DividerHandle]) {
        self.frames = frames
        self.dividers = dividers
    }

    /// Empty layout (no panes) — the degenerate base case.
    public static let empty = SolvedLayout(frames: [:], dividers: [])
}

// MARK: - The solver

/// Pure geometry: resolve a ``PaneNode`` tree + a container size into exact rects and divider
/// rects, with min-leaf clamping (docs/22 §2.1). Free of SwiftUI — `CGRect` math is the geometry
/// source of truth, fully unit-testable on macOS with no view.
public enum LayoutSolver {
    /// The on-screen thickness (points) reserved for / hit-tested on each divider. The divider is
    /// drawn centered on the gap between two siblings; this is its grab width.
    public static let dividerThickness: CGFloat = 8

    /// Solves `root` into a ``SolvedLayout`` filling `size`, clamping each leaf to at least
    /// `minLeaf`.
    ///
    /// Fractions allocate the available axis length proportionally; the divider thickness is
    /// **subtracted from the available length first** (so N children share `length − (N−1)·t`),
    /// keeping panes from overlapping the dividers. Each child is then clamped so neither its
    /// width nor height drops below `minLeaf` — clamping is a floor, not a re-solve, so a window
    /// smaller than the min footprint produces overlapping-but-floored rects rather than crashing
    /// (the responsive layer collapses to compact before that point, docs/22 §3).
    public static func solve(_ root: PaneNode, in size: CGSize, minLeaf: CGSize) -> SolvedLayout {
        var frames: [PaneID: CGRect] = [:]
        var dividers: [DividerHandle] = []
        let bounds = CGRect(origin: .zero, size: size)
        place(root, in: bounds, path: [], minLeaf: minLeaf, frames: &frames, dividers: &dividers)
        return SolvedLayout(frames: frames, dividers: dividers)
    }

    // MARK: Recursion

    /// Places `node` within `rect`, accumulating leaf frames and divider handles.
    private static func place(
        _ node: PaneNode,
        in rect: CGRect,
        path: [Int],
        minLeaf: CGSize,
        frames: inout [PaneID: CGRect],
        dividers: inout [DividerHandle]
    ) {
        switch node {
        case let .leaf(id, _):
            frames[id] = rect

        case let .split(axis, children, fractions):
            let normalized = normalize(fractions, count: children.count)
            let segments = segmentLengths(
                total: axis == .horizontal ? rect.width : rect.height,
                fractions: normalized,
                minLeaf: axis == .horizontal ? minLeaf.width : minLeaf.height
            )

            // Walk children along the axis, emitting child rects and the dividers between them.
            var cursor: CGFloat = axis == .horizontal ? rect.minX : rect.minY
            for (i, child) in children.enumerated() {
                let childRect: CGRect
                if axis == .horizontal {
                    childRect = CGRect(x: cursor, y: rect.minY, width: segments[i], height: rect.height)
                } else {
                    childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: segments[i])
                }
                place(child, in: childRect, path: path + [i], minLeaf: minLeaf, frames: &frames, dividers: &dividers)
                cursor += segments[i]

                // A divider sits in the gap AFTER each child except the last.
                if i < children.count - 1 {
                    let dividerRect: CGRect
                    if axis == .horizontal {
                        dividerRect = CGRect(
                            x: cursor - dividerThickness / 2,
                            y: rect.minY,
                            width: dividerThickness,
                            height: rect.height
                        )
                    } else {
                        dividerRect = CGRect(
                            x: rect.minX,
                            y: cursor - dividerThickness / 2,
                            width: rect.width,
                            height: dividerThickness
                        )
                    }
                    dividers.append(DividerHandle(path: path, index: i, axis: axis, rect: dividerRect))
                }
            }
        }
    }

    // MARK: Allocation math

    /// Normalizes `fractions` to sum to 1, falling back to even when degenerate or arity-mismatched
    /// (defensive: the tree invariant guarantees a valid array, but the solver must never divide by
    /// a zero total).
    private static func normalize(_ fractions: [Double], count: Int) -> [Double] {
        guard fractions.count == count, count > 0 else {
            return Array(repeating: 1.0 / Double(max(count, 1)), count: count)
        }
        // On this path arity matches (count > 0), so delegate to the model's canonical normalizer —
        // one source of truth for the epsilon + even-fallback kernel (PaneNode.normalized).
        return PaneNode.normalized(fractions)
    }

    /// Computes each child's length along the split axis: the divider gaps are reserved first,
    /// the remaining length is distributed by `fractions`, then each segment is floored to
    /// `minLeaf`. The floor is a clamp (it can make the total exceed the container when the window
    /// is too small) rather than a re-solve, matching the documented "collapse to compact before
    /// crushing" policy.
    private static func segmentLengths(total: CGFloat, fractions: [Double], minLeaf: CGFloat) -> [CGFloat] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let reservedForDividers = dividerThickness * CGFloat(max(count - 1, 0))
        let available = max(total - reservedForDividers, 0)
        return fractions.map { max(available * CGFloat($0), minLeaf) }
    }
}
