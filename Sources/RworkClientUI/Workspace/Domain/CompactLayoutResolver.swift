import Foundation

// MARK: - Compact projection types

/// One page of the compact (phone) carousel: a leaf projected into the swipeable page list
/// (docs/22 §2.2, §4). It carries just enough to render the page header without re-walking the
/// tree — the pane's id (which page), its kind (glyph), and its title.
public struct CompactPage: Sendable, Equatable {
    public let id: PaneID
    public let kind: PaneKind
    public let title: String
    public init(id: PaneID, kind: PaneKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

// MARK: - Compact projection

/// The pure **compact projection** (docs/22 §1.3, §2.2, §4): it flattens the SAME tree of intent
/// into an ordered page list and resolves swipe → next focus. The phone layout is therefore a
/// *view of the same model* — a 3-pane Mac split opens on iPhone as 3 swipeable pages, losslessly,
/// and a size-class flip is view-only (it must NOT reconcile, drop focus, or tear sessions down,
/// docs/22 §4). Free of UIKit; unit-tested on macOS (docs/22 §8 `CompactLayoutResolverTests`).
public enum CompactLayoutResolver {
    /// The carousel pages, in **pre-order leaf order** — identical to `tab.root.allLeafIDs()`, so
    /// page order matches the desktop tree's reading order exactly.
    public static func pages(for tab: Tab) -> [CompactPage] {
        tab.root.allLeafIDs().compactMap { id in
            guard let spec = tab.root.spec(for: id) else { return nil }
            return CompactPage(id: id, kind: spec.kind, title: spec.title)
        }
    }

    /// The index of the currently focused page (the page bound as the carousel's selection).
    /// Returns `0` if the focused pane is somehow absent (defensive — keeps the carousel on a
    /// valid page rather than out of bounds).
    public static func selectedIndex(for tab: Tab) -> Int {
        let ids = tab.root.allLeafIDs()
        return ids.firstIndex(of: tab.focusedPane) ?? 0
    }

    /// The leaf to focus after a swipe from `current`. `.next`/`.right`/`.down` advance one page;
    /// `.previous`/`.left`/`.up` go back one — **without wrap** (a carousel stops at its ends),
    /// returning `nil` at the boundary so the caller can leave focus where it is. Returns `nil`
    /// too if `current` is not a leaf in the tab.
    ///
    /// All four cardinal directions are accepted (a vertical swipe on a phone is as natural as a
    /// horizontal one); they collapse to forward/back over the linear page list since the compact
    /// layout is one-dimensional by construction.
    public static func focus(after current: PaneID, swipe dir: FocusDirection, in tab: Tab) -> PaneID? {
        let ids = tab.root.allLeafIDs()
        guard let i = ids.firstIndex(of: current) else { return nil }

        let forward: Bool
        switch dir {
        case .next, .right, .down:
            forward = true
        case .previous, .left, .up:
            forward = false
        }

        let target = forward ? i + 1 : i - 1
        guard ids.indices.contains(target) else { return nil } // no wrap at the ends
        return ids[target]
    }
}
