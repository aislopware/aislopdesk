import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the floating-overlay slice of ``SplitTreeRenderModel`` (P5a): `Layout.floatingLeaves` is
/// populated from a tab's `floatingPanes` + per-pane `floatingFrame`, clamped into the bounds, ordered
/// by z-order, and SUPPRESSED while zoomed. Headless geometry only — no view.
final class SplitTreeRenderModelFloatingTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func tab(root: SplitNode, floating: [PaneID], active: PaneID? = nil, zoomed: PaneID? = nil) -> Tab {
        Tab(root: root, activePane: active, zoomedPane: zoomed, floatingPanes: floating)
    }

    func testNoFloatingPanesProducesEmptyFloatingLeaves() {
        let a = PaneID()
        let layout = SplitTreeRenderModel.layout(for: tab(root: .leaf(a), floating: []), in: bounds)
        XCTAssertTrue(layout.floatingLeaves.isEmpty)
        XCTAssertEqual(layout.leaves.count, 1, "the tiled leaf still places")
    }

    func testFloatingFramePlacesAndClampsIntoBounds() {
        let a = PaneID(), f = PaneID()
        let frame = CGRect(x: 800, y: 600, width: 600, height: 500) // overflows bottom-right
        let layout = SplitTreeRenderModel.layout(
            for: tab(root: .leaf(a), floating: [f]),
            in: bounds,
            floating: [(id: f, frame: frame)],
        )
        XCTAssertEqual(layout.floatingLeaves.count, 1)
        let placed = layout.floatingLeaves[0]
        XCTAssertEqual(placed.id, f)
        XCTAssertLessThanOrEqual(placed.rect.maxX, bounds.maxX + 1e-6, "clamped inside bounds horizontally")
        XCTAssertLessThanOrEqual(placed.rect.maxY, bounds.maxY + 1e-6, "clamped inside bounds vertically")
    }

    func testNilFrameCentersADefault() {
        let a = PaneID(), f = PaneID()
        let layout = SplitTreeRenderModel.layout(
            for: tab(root: .leaf(a), floating: [f]),
            in: bounds,
            floating: [(id: f, frame: nil)],
        )
        let placed = try? XCTUnwrap(layout.floatingLeaves.first)
        XCTAssertEqual(placed?.rect.midX ?? -1, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(placed?.rect.midY ?? -1, bounds.midY, accuracy: 0.001)
    }

    func testFloatingLeavesPreserveZOrder() {
        let a = PaneID(), f1 = PaneID(), f2 = PaneID()
        let layout = SplitTreeRenderModel.layout(
            for: tab(root: .leaf(a), floating: [f1, f2]),
            in: bounds,
            floating: [(id: f1, frame: nil), (id: f2, frame: nil)],
        )
        XCTAssertEqual(layout.floatingLeaves.map(\.id), [f1, f2], "order = floatingPanes order (last = top)")
    }

    func testRaisedFloatIsLastInFloatingLeaves() throws {
        // After raiseFloating, the raised pane is at the END of tab.floatingPanes; the render model emits
        // floatingLeaves in that order, so the raised (topmost) float is the LAST placed leaf.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let base = ws0.allPaneIDs()[0]
        // Two tiled leaves so floating one never empties the tree.
        let (ws1, _) = WorkspaceTreeOps.splitPane(
            base, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        // Spawn two floats (fa then fb → fb topmost), then raise fa → it becomes last.
        let (wsA, fa) = WorkspaceTreeOps.spawnFloating(
            PaneSpec(kind: .terminal, title: "fa"), defaultFrame: frame, bounds: bounds, in: ws1,
        )
        let (wsB, fb) = WorkspaceTreeOps.spawnFloating(
            PaneSpec(kind: .terminal, title: "fb"), defaultFrame: frame, bounds: bounds, in: wsA,
        )
        let raised = WorkspaceTreeOps.raiseFloating(fa, in: wsB)
        let tab = try XCTUnwrap(raised.activeSession?.activeTab)
        let floating = tab.floatingPanes.map { (id: $0, frame: raised.spec(for: $0)?.floatingFrame) }
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds, floating: floating)
        XCTAssertEqual(
            layout.floatingLeaves.map(\.id), [fb, fa],
            "the raised float is last (topmost) in the render order",
        )
    }

    func testZoomSuppressesFloatingLeaves() {
        let a = PaneID(), b = PaneID(), f = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let layout = SplitTreeRenderModel.layout(
            for: tab(root: root, floating: [f], zoomed: a),
            in: bounds,
            floating: [(id: f, frame: nil)],
        )
        XCTAssertTrue(layout.floatingLeaves.isEmpty, "a zoomed tab hides floats")
        XCTAssertEqual(layout.leaves.count, 1, "zoom collapses to the one zoomed leaf")
    }
}
