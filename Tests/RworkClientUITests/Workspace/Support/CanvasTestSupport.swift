import Foundation
import CoreGraphics
@testable import RworkClientUI

// MARK: - Canvas test helpers

extension Tab {
    /// Builds a canvas tab from `(id, spec)` pairs, laid out in a non-overlapping row with incrementing
    /// z, focused on the first (or `focused`). The convenience the store/persistence/compact tests use
    /// to construct a multi-pane tab now that the layout model is a flat ``Canvas`` (was `Tab(root:
    /// .split(...))`).
    static func canvasTab(
        id: TabID = TabID(),
        name: String,
        panes: [(PaneID, PaneSpec)],
        focused: PaneID? = nil,
        maximized: PaneID? = nil
    ) -> Tab {
        precondition(!panes.isEmpty, "a canvas tab needs at least one pane")
        let items = panes.enumerated().map { index, pane in
            CanvasItem(
                id: pane.0,
                spec: pane.1,
                frame: CGRect(x: CGFloat(index) * 700, y: 0, width: 640, height: 420),
                z: index
            )
        }
        return Tab(
            id: id,
            name: name,
            canvas: Canvas(items: items),
            focusedPane: focused ?? panes[0].0,
            maximizedPane: maximized
        )
    }
}
