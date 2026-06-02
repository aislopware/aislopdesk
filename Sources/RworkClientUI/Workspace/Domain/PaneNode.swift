import Foundation

// MARK: - The tree of intent

/// The recursive, value-typed layout tree of one ``Tab`` (docs/22 §1.1, §2).
///
/// This is the **tree of intent**: a pure tree whose leaves carry a ``PaneID`` + a value-typed
/// ``PaneSpec``, and whose internal nodes are N-ary splits (parallel children + their
/// `fractions`). It holds *no* live object — never a `RworkClient`, never a view — only the
/// shape and the intent. Every mutation below is a **pure function returning a new tree**, which
/// is what makes ~85% of the workspace logic deterministically unit-testable with no client and
/// no async (docs/22 §1.2, §8).
///
/// ### Invariants (held by every op here)
/// - A `.split` always has `fractions.count == children.count`.
/// - `fractions` sum to ≈ 1.0 (renormalized after any structural change).
/// - A `.split` always has **≥ 2 children**: ``closing(_:)`` collapses a split that would drop
///   to one child into that child (no singleton splits ever exist), and ``splitting`` never
///   creates one.
///
/// Because it is `Codable` the tree *is* the persistence format; its Codable conformance is
/// hand-written and discriminated (see `PaneNode+Codable.swift`) so the wire shape is stable.
public indirect enum PaneNode: Sendable, Equatable {
    /// A single pane: stable identity + its value-typed spec.
    case leaf(PaneID, PaneSpec)
    /// An N-ary split: an axis, the parallel `children`, and their normalized `fractions`
    /// (parallel array: `fractions[i]` is the share of `children[i]` along `axis`).
    case split(SplitAxis, children: [PaneNode], fractions: [Double])
}

// MARK: - Queries

public extension PaneNode {
    /// All leaf ids in **pre-order** (depth-first, children left-to-right).
    ///
    /// Pre-order is the canonical leaf ordering used everywhere downstream: it drives the
    /// compact carousel page order (``CompactLayoutResolver/pages(for:)``), the focus cycle
    /// (``FocusResolver/cycle(_:from:forward:)``), and the store's reconcile diff. Defining it
    /// once here keeps all three consistent.
    func allLeafIDs() -> [PaneID] {
        switch self {
        case let .leaf(id, _):
            return [id]
        case let .split(_, children, _):
            return children.flatMap { $0.allLeafIDs() }
        }
    }

    /// The spec for `id`, or `nil` if no such leaf exists in this tree.
    func spec(for id: PaneID) -> PaneSpec? {
        switch self {
        case let .leaf(leafID, spec):
            return leafID == id ? spec : nil
        case let .split(_, children, _):
            for child in children {
                if let found = child.spec(for: id) { return found }
            }
            return nil
        }
    }

    /// Whether `id` names a leaf anywhere in this tree.
    func contains(_ id: PaneID) -> Bool {
        spec(for: id) != nil
    }

    /// The total number of leaves (diagnostics / tests; equals `allLeafIDs().count`).
    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case let .split(_, children, _):
            return children.reduce(0) { $0 + $1.leafCount }
        }
    }
}

// MARK: - Structural mutations (all pure — return a NEW tree)

public extension PaneNode {
    /// Splits the leaf `target` along `axis`, adding `newLeaf` as a sibling with **even
    /// fractions**, and returns the new tree. If `target` is not a leaf in this tree, returns
    /// `self` unchanged.
    ///
    /// ### The flatten rule (docs/22 §2 op contract)
    /// If `target` already lives inside a split whose axis **equals** the requested `axis`, the
    /// new leaf is **inserted as a sibling** of `target` in that existing split (the split goes
    /// from N to N+1 children, re-evened) — it is NOT wrapped in a fresh nested split. This is
    /// the tmux-style "split again in the same direction widens the row" behaviour and keeps the
    /// tree flat (a `⌘D ⌘D ⌘D` produces a single 4-way horizontal split, not a right-leaning
    /// staircase of binary splits). Splitting across the *other* axis nests as expected.
    func splitting(_ target: PaneID, axis: SplitAxis, newLeaf: (PaneID, PaneSpec)) -> PaneNode {
        switch self {
        case let .leaf(id, spec):
            // Splitting a bare leaf: wrap it + the new leaf in a fresh, evenly-divided split.
            guard id == target else { return self }
            return .split(
                axis,
                children: [.leaf(id, spec), .leaf(newLeaf.0, newLeaf.1)],
                fractions: Self.even(2)
            )

        case let .split(myAxis, children, _):
            // Is `target` a DIRECT leaf child of this split, AND does this split's axis match
            // the requested axis? Then flatten: insert the sibling right after `target`.
            if myAxis == axis,
               let directIndex = children.firstIndex(where: { $0.isLeaf(target) }) {
                var newChildren = children
                newChildren.insert(.leaf(newLeaf.0, newLeaf.1), at: directIndex + 1)
                return .split(myAxis, children: newChildren, fractions: Self.even(newChildren.count))
            }
            // Otherwise recurse into whichever child contains the target. Fractions of THIS
            // split are unchanged (the structural change happens deeper or wraps a child).
            guard let recurseIndex = children.firstIndex(where: { $0.contains(target) }) else {
                return self
            }
            var newChildren = children
            newChildren[recurseIndex] = children[recurseIndex].splitting(target, axis: axis, newLeaf: newLeaf)
            return .split(myAxis, children: newChildren, fractions: Self.evenedKeepingCount(self))
        }
    }

    /// Closes the leaf `target`, returning the new tree — or `nil` if closing it would empty the
    /// whole tree (i.e. `target` is the last remaining leaf). Callers treat `nil` as "this tab
    /// has no panes left" (the tab itself is then closed).
    ///
    /// ### Collapse + renormalize (docs/22 §2 op contract)
    /// Removing a child from a split renormalizes the surviving siblings' fractions to sum to 1
    /// (the closed pane's share is redistributed proportionally). If a split drops to a **single**
    /// surviving child, the split node is **collapsed** into that child — no singleton splits are
    /// ever left in the tree (which keeps `splitting`'s flatten rule and the layout solver
    /// simple).
    func closing(_ target: PaneID) -> PaneNode? {
        switch self {
        case let .leaf(id, _):
            // Closing the only leaf empties the tree.
            return id == target ? nil : self

        case let .split(axis, children, fractions):
            // Find the child that owns `target` (directly or deeper).
            guard let index = children.firstIndex(where: { $0.contains(target) }) else {
                return self // target not here — unchanged
            }

            var newChildren = children
            var newFractions = fractions

            if case let .leaf(leafID, _) = children[index], leafID == target {
                // Direct leaf child: drop it.
                newChildren.remove(at: index)
                newFractions.remove(at: index)
            } else {
                // Deeper: recurse. The child cannot fully empty (it contains target but also,
                // by tree invariant, may collapse to a single leaf — handled by the recursive
                // call returning a non-nil collapsed node).
                guard let rewritten = children[index].closing(target) else {
                    // The subtree emptied (it was a lone leaf equal to target — but that path is
                    // the direct-leaf branch above, so this is defensive). Drop the slot.
                    newChildren.remove(at: index)
                    newFractions.remove(at: index)
                    return Self.collapsing(axis: axis, children: newChildren, fractions: newFractions)
                }
                newChildren[index] = rewritten
                return .split(axis, children: newChildren, fractions: newFractions)
            }

            return Self.collapsing(axis: axis, children: newChildren, fractions: newFractions)
        }
    }

    /// Returns a new tree with the spec of leaf `id` transformed in place by `transform`. Used
    /// for rename, filling in an endpoint, etc. If `id` is absent the tree is unchanged.
    func updatingSpec(_ id: PaneID, _ transform: (inout PaneSpec) -> Void) -> PaneNode {
        switch self {
        case let .leaf(leafID, spec):
            guard leafID == id else { return self }
            var copy = spec
            transform(&copy)
            return .leaf(leafID, copy)
        case let .split(axis, children, fractions):
            let newChildren = children.map { $0.updatingSpec(id, transform) }
            return .split(axis, children: newChildren, fractions: fractions)
        }
    }

    /// Returns a new tree with the `fractions` of the split addressed by `path` replaced by the
    /// given values (e.g. after a divider drag). `path` is the sequence of child indices from the
    /// root to the target split (an empty path addresses the root). The caller is responsible for
    /// clamping/normalizing `fractions` (the store does this via min-leaf clamping); this op
    /// applies them verbatim so a divider drag is exactly representable. No-ops (returns `self`)
    /// if the path does not address a split, or if the arity does not match.
    func settingFractions(at path: [Int], to fractions: [Double]) -> PaneNode {
        guard let first = path.first else {
            // Empty path → this node is the target split.
            guard case let .split(axis, children, oldFractions) = self,
                  fractions.count == children.count,
                  fractions.count == oldFractions.count else { return self }
            return .split(axis, children: children, fractions: fractions)
        }
        guard case let .split(axis, children, myFractions) = self,
              children.indices.contains(first) else { return self }
        var newChildren = children
        newChildren[first] = children[first].settingFractions(at: Array(path.dropFirst()), to: fractions)
        return .split(axis, children: newChildren, fractions: myFractions)
    }
}

// MARK: - Internal helpers

extension PaneNode {
    /// Whether this node is exactly the leaf with the given id (a direct, non-recursive check —
    /// used by `splitting` to decide direct-child membership for the flatten rule).
    func isLeaf(_ id: PaneID) -> Bool {
        if case let .leaf(leafID, _) = self { return leafID == id }
        return false
    }

    /// Even fractions for `count` siblings (`1/count` each), summing to exactly 1 modulo FP.
    static func even(_ count: Int) -> [Double] {
        precondition(count > 0)
        return Array(repeating: 1.0 / Double(count), count: count)
    }

    /// The current fractions of a split, used unchanged when only a descendant changed. (A split
    /// keeps its own fractions when a recursion rewrote a child; this surfaces them so callers
    /// don't re-even a row that did not change arity.)
    static func evenedKeepingCount(_ node: PaneNode) -> [Double] {
        if case let .split(_, _, fractions) = node { return fractions }
        return []
    }

    /// Builds a split from the surviving `children`/`fractions` after a removal, applying the
    /// two cleanup invariants: **collapse** a single-child split into its child, and
    /// **renormalize** the fractions to sum to 1.
    static func collapsing(axis: SplitAxis, children: [PaneNode], fractions: [Double]) -> PaneNode {
        precondition(!children.isEmpty, "collapsing must be called with at least one surviving child")
        if children.count == 1 {
            return children[0] // collapse singleton split
        }
        return .split(axis, children: children, fractions: normalized(fractions))
    }

    /// Renormalizes `fractions` to sum to 1. If the input sums to ~0 (degenerate), falls back to
    /// even fractions so the layout solver always gets a valid distribution.
    static func normalized(_ fractions: [Double]) -> [Double] {
        let total = fractions.reduce(0, +)
        guard total > 1e-9 else { return even(fractions.count) }
        return fractions.map { $0 / total }
    }
}
