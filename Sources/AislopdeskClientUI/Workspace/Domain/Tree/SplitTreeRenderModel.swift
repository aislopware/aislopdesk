import CoreGraphics
import Foundation

// MARK: - SplitTreeRenderModel (the pure render seam for the IDE split view — W5)

/// The **pure** placement model the `SplitTreeView` renders from (docs/42 §"W5 — First-test": the
/// "which pane → which rect, zoom → full rect, dividers between adjacent children" headless seam).
/// Given a ``Tab`` (or a ``SplitNode`` + its zoom state) and a bounding `CGRect`, it produces:
///
/// - **`leaves`** — every visible ``PaneID`` paired with its placed `CGRect` (the leaf rects come from
///   ``SplitLayoutSolver`` so the render and ``FocusResolver`` agree exactly), and
/// - **`dividers`** — a thin draggable handle rect between every pair of adjacent siblings of every
///   split, tagged with the owning `splitID`, the LEADING child index, and the split `axis` (so a
///   horizontal split yields a vertical divider the user drags left/right, and vice-versa).
///
/// ### Zoom
/// When the tab names a `zoomedPane` that is a live leaf, the model collapses to that ONE leaf filling
/// the whole bound and **no dividers** (WezTerm `TabInner.zoomed` — render-only; the tree is untouched).
/// The other leaves are NOT in `leaves` — the view keeps them mounted at `opacity 0` itself (the proven
/// no-teardown trick), so the model needs only the visible placement.
///
/// Free of SwiftUI; `CGRect`/`CGFloat` math only (the house float idiom: separate `*`+`+`, never
/// `addingProduct`/`fma`; NaN-faithful ordered `Double.maximum`/`Double.minimum`). Headless-unit-tested
/// by `SplitTreeRenderModelTests`.
public enum SplitTreeRenderModel {
    /// A placed leaf: a ``PaneID`` and the rect it occupies (already solver-clamped to `minLeaf`).
    public struct PlacedLeaf: Equatable, Sendable {
        public let id: PaneID
        public let rect: CGRect
        public init(id: PaneID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// A draggable divider between two adjacent siblings of a split. `childIndex` is the LEADING child
    /// (the divider sits between `childIndex` and `childIndex + 1`), matching
    /// ``WorkspaceTreeOps/resizeDivider(splitID:leadingChildIndex:delta:in:)``. `axis` is the split's
    /// axis: a `.horizontal` split (side-by-side columns) yields a divider the user drags horizontally;
    /// a `.vertical` split (stacked rows) yields one dragged vertically.
    public struct DividerHandle: Equatable, Sendable {
        public let splitID: SplitNodeID
        public let childIndex: Int
        public let axis: SplitAxis
        public let rect: CGRect
        public init(splitID: SplitNodeID, childIndex: Int, axis: SplitAxis, rect: CGRect) {
            self.splitID = splitID
            self.childIndex = childIndex
            self.axis = axis
            self.rect = rect
        }
    }

    /// The full render layout: the visible leaves + their dividers. `dividers` is empty for a single-leaf
    /// or zoomed tab.
    public struct Layout: Equatable, Sendable {
        public let leaves: [PlacedLeaf]
        public let dividers: [DividerHandle]
        public init(leaves: [PlacedLeaf], dividers: [DividerHandle]) {
            self.leaves = leaves
            self.dividers = dividers
        }

        public static let empty = Self(leaves: [], dividers: [])
    }

    /// The on-screen thickness of a divider handle's hit/draw band, centered on the seam between two
    /// siblings. A comfortable trackpad target; the visible hairline can be drawn thinner inside it.
    public static let dividerThickness: CGFloat = 8

    // MARK: - Entry points

    /// The layout for `tab` solved into `bounds` — honors `tab.zoomedPane` (zoom → one full-bounds leaf,
    /// no dividers) and the floating layer is ignored (MVP `floatingPanes` is always empty).
    public static func layout(
        for tab: Tab,
        in bounds: CGRect,
        minLeaf: CGSize = SplitLayoutSolver.defaultMinLeaf,
        dividerThickness: CGFloat = Self.dividerThickness,
    ) -> Layout {
        layout(
            root: tab.root,
            zoomedPane: tab.zoomedPane,
            in: bounds,
            minLeaf: minLeaf,
            dividerThickness: dividerThickness,
        )
    }

    /// The layout for a bare `root` + optional `zoomedPane` solved into `bounds`. Total: a finite bound
    /// yields finite rects for exactly the visible leaves.
    public static func layout(
        root: SplitNode,
        zoomedPane: PaneID?,
        in bounds: CGRect,
        minLeaf: CGSize = SplitLayoutSolver.defaultMinLeaf,
        dividerThickness: CGFloat = Self.dividerThickness,
    ) -> Layout {
        // Zoom: a single leaf fills the whole bound, no dividers. Only honor a zoom that names a leaf that
        // actually exists in the tree (a stale zoom id falls through to the normal tiled layout).
        if let zoomed = zoomedPane, root.contains(zoomed) {
            return Layout(leaves: [PlacedLeaf(id: zoomed, rect: bounds)], dividers: [])
        }

        // Leaves come from the SOLVER so the render and FocusResolver agree exactly. Ordered by the tree's
        // deterministic pre-order DFS so the mount order is stable.
        let solved = SplitLayoutSolver.solve(root, in: bounds, minLeaf: minLeaf)
        let placed = root.allPaneIDs().compactMap { id in
            solved[id].map { PlacedLeaf(id: id, rect: $0) }
        }

        // Dividers come from an UN-clamped partition descent (the seam between two siblings is where the
        // partition cut falls, regardless of the per-leaf min clamp) so a handle always sits on the visible
        // boundary.
        var dividers: [DividerHandle] = []
        collectDividers(root, in: bounds, thickness: dividerThickness, into: &dividers)
        return Layout(leaves: placed, dividers: dividers)
    }

    // MARK: - Divider descent (un-clamped partition → handle rects)

    private static func collectDividers(
        _ node: SplitNode,
        in rect: CGRect,
        thickness: CGFloat,
        into out: inout [DividerHandle],
    ) {
        switch node {
        case .leaf:
            return
        case let .split(id, axis, children):
            guard !children.isEmpty else { return }
            // Partition `rect` along `axis` by the children's weights — the SAME extents the solver uses
            // (un-clamped) so a divider sits exactly on a sibling seam.
            let extents = SplitLayoutSolver.extents(for: children, total: axisLength(of: rect, axis: axis))
            var cursor = axisOrigin(of: rect, axis: axis)
            var childRects: [CGRect] = []
            childRects.reserveCapacity(children.count)
            for (child, extent) in zip(children, extents) {
                let childRect = subRect(of: rect, axis: axis, origin: cursor, extent: extent)
                childRects.append(childRect)
                cursor += extent
            }
            // A handle band centered on each interior seam (between child i and i+1).
            for i in 0..<(children.count - 1) {
                let seam = trailingEdge(of: childRects[i], axis: axis)
                out.append(DividerHandle(
                    splitID: id,
                    childIndex: i,
                    axis: axis,
                    rect: handleRect(at: seam, axis: axis, span: rect, thickness: thickness),
                ))
            }
            // Recurse into the children for nested splits.
            for (child, childRect) in zip(children, childRects) {
                collectDividers(child.node, in: childRect, thickness: thickness, into: &out)
            }
        }
    }

    // MARK: - Axis-aware helpers (mirror the solver's geometry)

    private static func axisLength(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.width
        case .vertical: rect.height
        }
    }

    private static func axisOrigin(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.minX
        case .vertical: rect.minY
        }
    }

    private static func subRect(of rect: CGRect, axis: SplitAxis, origin: CGFloat, extent: CGFloat) -> CGRect {
        switch axis {
        case .horizontal:
            CGRect(x: origin, y: rect.minY, width: extent, height: rect.height)
        case .vertical:
            CGRect(x: rect.minX, y: origin, width: rect.width, height: extent)
        }
    }

    /// The coordinate of `rect`'s trailing edge along `axis` (`horizontal` → maxX, `vertical` → maxY) —
    /// the seam shared with the next sibling.
    private static func trailingEdge(of rect: CGRect, axis: SplitAxis) -> CGFloat {
        switch axis {
        case .horizontal: rect.maxX
        case .vertical: rect.maxY
        }
    }

    /// A divider handle rect of `thickness` centered on the seam coordinate `seam`, spanning the cross-axis
    /// of `span` (the parent rect). A horizontal split's seam is a vertical band (full height of the
    /// parent); a vertical split's seam is a horizontal band (full width).
    private static func handleRect(at seam: CGFloat, axis: SplitAxis, span: CGRect, thickness: CGFloat) -> CGRect {
        let half = thickness / 2
        switch axis {
        case .horizontal:
            return CGRect(x: seam - half, y: span.minY, width: thickness, height: span.height)
        case .vertical:
            return CGRect(x: span.minX, y: seam - half, width: span.width, height: thickness)
        }
    }
}
