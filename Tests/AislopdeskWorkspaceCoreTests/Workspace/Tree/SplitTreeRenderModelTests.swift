import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the pure ``SplitTreeRenderModel`` (W5, docs/42 §"W5 — First-test"): the headless seam the
/// `SplitTreeView` renders from. These assert: leaf placement matches ``SplitLayoutSolver`` exactly,
/// `zoomedPane` collapses to one full-bounds leaf with no dividers, divider rects lie ON the seam
/// BETWEEN adjacent siblings (tagged with the right `splitID` / leading `childIndex` / `axis`), and the
/// degenerate empty / single-leaf cases.
///
/// GUI views are compiled + code-reviewed only (hang-safety — no SCStream/VT/Metal/libghostty in tests);
/// this render model is the headless proof of the split-view geometry.
final class SplitTreeRenderModelTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    // MARK: - Placement matches the solver

    func testSingleLeafFillsBoundsNoDividers() {
        let a = PaneID()
        let bounds = CGRect(x: 5, y: 7, width: 800, height: 600)
        let layout = SplitTreeRenderModel.layout(root: .leaf(a), zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertEqual(layout.leaves.first?.id, a)
        assertRectEqual(layout.leaves.first?.rect, bounds)
        XCTAssertTrue(layout.dividers.isEmpty, "a single leaf has no divider")
    }

    func testLeafPlacementMatchesSolverExactly() {
        // A nested tree: horizontal split of [a | (b over c)] so both axes + nesting are exercised.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let innerID = SplitNodeID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(2), node: .split(id: innerID, axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)
        let solved = SplitLayoutSolver.solve(root, in: bounds)

        // Every solver leaf appears EXACTLY once with the solver's rect.
        XCTAssertEqual(Set(layout.leaves.map(\.id)), Set(solved.keys))
        XCTAssertEqual(layout.leaves.count, solved.count)
        for placed in layout.leaves {
            assertRectEqual(placed.rect, solved[placed.id])
        }
        // Order is the tree's deterministic pre-order DFS.
        XCTAssertEqual(layout.leaves.map(\.id), root.allPaneIDs())
    }

    // MARK: - Zoom → one full-bounds leaf

    func testZoomYieldsOneFullBoundsLeafNoDividers() {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 10, y: 20, width: 1000, height: 700)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: b, in: bounds)

        XCTAssertEqual(layout.leaves.count, 1, "zoom renders exactly the zoomed leaf")
        XCTAssertEqual(layout.leaves.first?.id, b)
        assertRectEqual(layout.leaves.first?.rect, bounds, "the zoomed leaf fills the whole bound")
        XCTAssertTrue(layout.dividers.isEmpty, "a zoomed tab shows no dividers")
    }

    func testStaleZoomFallsThroughToTiledLayout() {
        // A zoom naming a pane NOT in the tree is ignored (the tiled layout renders).
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: PaneID(), in: bounds)

        XCTAssertEqual(layout.leaves.count, 2, "a stale zoom id does not collapse the layout")
        XCTAssertEqual(layout.dividers.count, 1)
    }

    // MARK: - Dividers lie between siblings

    func testHorizontalSplitDividerSitsOnTheSeam() {
        // weights 1:3 over width 800 → seam at x = 200; the divider is a vertical band centered there.
        let a = PaneID(), b = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(3), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let thickness: CGFloat = 8

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds, dividerThickness: thickness)

        XCTAssertEqual(layout.dividers.count, 1)
        let d = layout.dividers[0]
        XCTAssertEqual(d.splitID, splitID)
        XCTAssertEqual(d.childIndex, 0, "the divider's leading child is index 0")
        XCTAssertEqual(d.axis, .horizontal)
        // The band is centered on the seam x = 200, full parent height.
        XCTAssertEqual(d.rect.midX, 200, accuracy: eps)
        XCTAssertEqual(d.rect.width, thickness, accuracy: eps)
        XCTAssertEqual(d.rect.minY, bounds.minY, accuracy: eps)
        XCTAssertEqual(d.rect.height, bounds.height, accuracy: eps)
        // The seam is exactly where leaf a ends and leaf b begins.
        let solved = SplitLayoutSolver.solve(root, in: bounds)
        XCTAssertEqual(solved[a]?.maxX ?? .nan, d.rect.midX, accuracy: eps)
        XCTAssertEqual(solved[b]?.minX ?? .nan, d.rect.midX, accuracy: eps)
    }

    func testVerticalSplitDividerIsHorizontalBand() {
        // weights 1:1 over height 600 → seam at y = 300; the divider is a horizontal band centered there.
        let a = PaneID(), b = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .vertical, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 1)
        let d = layout.dividers[0]
        XCTAssertEqual(d.axis, .vertical)
        XCTAssertEqual(d.rect.midY, 300, accuracy: eps)
        XCTAssertEqual(d.rect.minX, bounds.minX, accuracy: eps)
        XCTAssertEqual(d.rect.width, bounds.width, accuracy: eps, "a vertical split's divider spans the full width")
    }

    func testThreeWaySplitYieldsTwoDividersAtSeams() {
        // weights 1:1:2 over width 800 → seams at x = 200 and x = 400.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let splitID = SplitNodeID()
        let root = SplitNode.split(id: splitID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
            WeightedChild(weight: .flex(2), node: .leaf(c)),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 2, "n children → n-1 dividers")
        let byIndex = layout.dividers.sorted { $0.childIndex < $1.childIndex }
        XCTAssertEqual(byIndex[0].childIndex, 0)
        XCTAssertEqual(byIndex[0].rect.midX, 200, accuracy: eps)
        XCTAssertEqual(byIndex[1].childIndex, 1)
        XCTAssertEqual(byIndex[1].rect.midX, 400, accuracy: eps)
        XCTAssertTrue(byIndex.allSatisfy { $0.splitID == splitID })
    }

    func testNestedSplitsEmitDividersForBothLevels() {
        // [a | (b / c)] → one outer (horizontal) divider + one inner (vertical) divider, distinct splitIDs.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let outerID = SplitNodeID(), innerID = SplitNodeID()
        let root = SplitNode.split(id: outerID, axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .split(id: innerID, axis: .vertical, children: [
                WeightedChild(weight: .flex(1), node: .leaf(b)),
                WeightedChild(weight: .flex(1), node: .leaf(c)),
            ])),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

        let layout = SplitTreeRenderModel.layout(root: root, zoomedPane: nil, in: bounds)

        XCTAssertEqual(layout.dividers.count, 2)
        let outer = layout.dividers.first { $0.splitID == outerID }
        let inner = layout.dividers.first { $0.splitID == innerID }
        XCTAssertNotNil(outer)
        XCTAssertNotNil(inner)
        XCTAssertEqual(outer?.axis, .horizontal)
        XCTAssertEqual(inner?.axis, .vertical)
        // The inner (vertical) divider lives in the right half (x ≥ 500) and is centered at its mid-height.
        XCTAssertGreaterThanOrEqual(inner?.rect.minX ?? -1, 500 - eps)
        XCTAssertEqual(inner?.rect.midY ?? .nan, 300, accuracy: eps)
    }

    // MARK: - Tab entry point + degenerate cases

    func testTabEntryPointHonorsZoom() {
        let a = PaneID(), b = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let tab = Tab(root: root, activePane: a, zoomedPane: a)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)

        XCTAssertEqual(layout.leaves.map(\.id), [a])
        assertRectEqual(layout.leaves.first?.rect, bounds)
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    func testOneLeafTabHasNoDividers() {
        let a = PaneID()
        let tab = Tab(root: .leaf(a), activePane: a)
        let layout = SplitTreeRenderModel.layout(for: tab, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    // MARK: - Helpers

    private func assertRectEqual(
        _ lhs: CGRect?,
        _ rhs: CGRect?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        guard let lhs, let rhs else {
            XCTFail("nil rect \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: eps, "minX \(message)", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: eps, "minY \(message)", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: eps, "width \(message)", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: eps, "height \(message)", file: file, line: line)
    }
}
