import Foundation
import CoreGraphics

// MARK: - Tab (one pane canvas + its focus/maximize presentation state)

/// One tab in the workspace: a name, the infinite ``Canvas`` of free-floating panes it owns, and the
/// small amount of presentation state that rides with it — which pane is focused, and whether one pane
/// is currently maximized (docs/30 §2).
///
/// `focusedPane` and `maximizedPane` are intentionally part of the value type (not the live layer):
/// they are pure, they persist with the canvas (docs/30 §4), and the focus/compact resolvers read
/// them. `maximizedPane` is a **presentation flag only** — it renders a single pane full-viewport
/// (ignoring the camera / other items) but performs no model surgery, so the registry is untouched on
/// maximize (the proven no-teardown property of the old `zoomedPane`).
///
/// `Identifiable` by ``TabID`` so SwiftUI lists / `ForEach` and the tab sidebar bind to a stable
/// key across reorder.
public struct Tab: Identifiable, Codable, Sendable, Equatable {
    public let id: TabID
    public var name: String
    /// The tab's infinite plane of free-floating panes (was the recursive `root: PaneNode` split tree).
    public var canvas: Canvas
    /// The pane that currently has focus. Always a valid item id in `canvas` (the store re-points it
    /// to a neighbour when the focused pane closes).
    public var focusedPane: PaneID
    /// `nil` = normal canvas; non-nil = that item is maximized to fill the viewport (a pure
    /// presentation flag — see the type doc). Was `zoomedPane`.
    public var maximizedPane: PaneID?

    public init(id: TabID = TabID(), name: String, canvas: Canvas, focusedPane: PaneID, maximizedPane: PaneID? = nil) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.focusedPane = focusedPane
        self.maximizedPane = maximizedPane
    }
}

// MARK: - Convenience construction

public extension Tab {
    /// Builds a single-pane tab for `kind`, minting the pane's ``PaneID`` and pointing focus at it.
    /// The convenience entry point for "new tab" and the default-workspace factory: the canvas starts
    /// as one item at the origin (default size, z = 0), focused, not maximized.
    ///
    /// - Parameter endpoint: pre-fill the pane's ``PaneSpec/endpoint`` (connect-once inheritance).
    ///   Only meaningful for `.terminal` / `.claudeCode` kinds; `nil` (the default) leaves the
    ///   pane in the unconfigured "show form" state. Existing callers that omit it are unaffected.
    static func make(kind: PaneKind, title: String, endpoint: Endpoint? = nil) -> Tab {
        let paneID = PaneID()
        let spec = PaneSpec(kind: kind, title: title, endpoint: endpoint)
        let item = CanvasItem(id: paneID, spec: spec,
                              frame: CGRect(origin: .zero, size: Canvas.defaultItemSize), z: 0)
        return Tab(
            name: title,
            canvas: Canvas(items: [item]),
            focusedPane: paneID,
            maximizedPane: nil
        )
    }
}
