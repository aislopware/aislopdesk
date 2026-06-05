import Foundation

// MARK: - Tab (one pane tree + its focus/zoom presentation state)

/// One tab in the workspace: a name, the recursive ``PaneNode`` tree it owns, and the small
/// amount of presentation state that rides with the tree — which leaf is focused, and whether one
/// leaf is currently zoomed (maximized) (docs/22 §2).
///
/// `focusedPane` and `zoomedPane` are intentionally part of the value type (not the live layer):
/// they are pure, they persist with the tree (docs/22 §6), and the focus/compact resolvers read
/// them. `zoomedPane` is a **presentation flag only** — zoom renders a single leaf full-bleed but
/// performs no tree surgery, so the registry is untouched on zoom (docs/22 §3).
///
/// `Identifiable` by ``TabID`` so SwiftUI lists / `ForEach` and the tab sidebar bind to a stable
/// key across reorder.
public struct Tab: Identifiable, Codable, Sendable, Equatable {
    public let id: TabID
    public var name: String
    public var root: PaneNode
    /// The leaf that currently has focus. Always a valid leaf in `root` (the store re-points it
    /// to a neighbour when the focused pane closes).
    public var focusedPane: PaneID
    /// `nil` = normal split layout; non-nil = that leaf is maximized (an explicit zoom). A pure
    /// presentation flag — see the type doc.
    public var zoomedPane: PaneID?

    public init(id: TabID = TabID(), name: String, root: PaneNode, focusedPane: PaneID, zoomedPane: PaneID? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.focusedPane = focusedPane
        self.zoomedPane = zoomedPane
    }
}

// MARK: - Convenience construction

public extension Tab {
    /// Builds a single-leaf tab for `kind`, minting the leaf's ``PaneID`` and pointing focus at
    /// it. The convenience entry point for "new tab" and the default-workspace factory: the tree
    /// starts as one leaf, focused, not zoomed.
    ///
    /// - Parameter endpoint: pre-fill the leaf's ``PaneSpec/endpoint`` (connect-once inheritance).
    ///   Only meaningful for `.terminal` / `.claudeCode` kinds; `nil` (the default) leaves the
    ///   pane in the unconfigured "show form" state. Existing callers that omit it are unaffected.
    static func make(kind: PaneKind, title: String, endpoint: Endpoint? = nil) -> Tab {
        let paneID = PaneID()
        let spec = PaneSpec(kind: kind, title: title, endpoint: endpoint)
        return Tab(
            name: title,
            root: .leaf(paneID, spec),
            focusedPane: paneID,
            zoomedPane: nil
        )
    }
}
