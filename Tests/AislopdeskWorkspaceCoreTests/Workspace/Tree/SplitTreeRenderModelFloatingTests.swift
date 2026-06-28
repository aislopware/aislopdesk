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

    func testFloatingRemoteGUIPaneEmitsAClampedLeafAtItsFrame() throws {
        // E21 WI-6 / ES-E21-3: a `.remoteGUI` (streamed host window) pane floats exactly like a terminal —
        // the render model is kind-AGNOSTIC, so once `WorkspaceTreeOps.toggleFloating` floats it (no kind
        // guard) the floating leaf places at its clamped `floatingFrame`. This pins the end-to-end
        // float → render path for a remote window ("`.remoteGUI` floats for free").
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "term"))
        let term = ws0.allPaneIDs()[0]
        // Two tiled leaves so floating one never empties the tree; the floated one is the remote window.
        let (ws1, gui) = WorkspaceTreeOps.splitPane(
            term, axis: .horizontal, newSpec: PaneSpec(kind: .remoteGUI, title: "Remote window"), in: ws0,
        )
        let frame = CGRect(x: 120, y: 90, width: 500, height: 360)
        let floated = WorkspaceTreeOps.toggleFloating(gui, defaultFrame: frame, bounds: bounds, in: ws1)
        let activeTab = try XCTUnwrap(floated.activeSession?.activeTab)
        let pairs = activeTab.floatingPanes.map { (id: $0, frame: floated.spec(for: $0)?.floatingFrame) }
        let layout = SplitTreeRenderModel.layout(for: activeTab, in: bounds, floating: pairs)
        XCTAssertEqual(layout.floatingLeaves.count, 1, "the floated remote window is the one floating leaf")
        let placed = try XCTUnwrap(layout.floatingLeaves.first { $0.id == gui })
        XCTAssertEqual(
            placed.rect, WorkspaceTreeOps.clampFloatingFrame(frame, in: bounds),
            "the remote-window float places at its clamped frame (kind-agnostic)",
        )
        XCTAssertTrue(activeTab.root.contains(term), "the tiled sibling stays tiled")
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

    // MARK: - F4 / WI-6 — float↔embed stays within ONE keyed compositor collection (identity preserved)

    /// The compositor list union pin: `Layout.compositorLeaves` merges the tiled `leaves` and the
    /// `floatingLeaves` into ONE `PaneID`-keyed sequence (tiled first, floating last for z-order), with each
    /// pane appearing EXACTLY once. This is the single `ForEach` source `SplitContainer` iterates so a
    /// float↔embed move never hands a pane a new SwiftUI identity (which would tear down + rebuild its hosted
    /// terminal / `.remoteGUI` video surface). Headless: pure model, no view / no Metal / no socket.
    func testCompositorLeavesMergeTiledThenFloatingEachPaneOnce() {
        let a = PaneID(), b = PaneID(), f = PaneID()
        let root = SplitNode.split(id: SplitNodeID(), axis: .horizontal, children: [
            WeightedChild(weight: .flex(1), node: .leaf(a)),
            WeightedChild(weight: .flex(1), node: .leaf(b)),
        ])
        let layout = SplitTreeRenderModel.layout(
            for: tab(root: root, floating: [f]),
            in: bounds,
            floating: [(id: f, frame: nil)],
        )
        let merged = layout.compositorLeaves
        XCTAssertEqual(
            merged.map(\.id), layout.leaves.map(\.id) + layout.floatingLeaves.map(\.id),
            "tiled leaves first, floating last (z-order) — one ForEach source",
        )
        XCTAssertEqual(merged.filter { !$0.isFloating }.map(\.id), [a, b], "the tiled pair carries isFloating=false")
        XCTAssertEqual(merged.filter(\.isFloating).map(\.id), [f], "the float carries isFloating=true")
        // Each pane appears EXACTLY once across the whole compositor list (never in both layers → never mounted
        // twice → never one ForEach tears it down while the other rebuilds it).
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "no PaneID is duplicated in the merged list")
    }

    /// The actual F4 regression driver: a pane that EMBEDS (floating → tiled) must stay in the SAME single
    /// `compositorLeaves` collection across the transition, keyed by the SAME `PaneID`, flipping ONLY its
    /// `isFloating` flag. That is exactly what lets one `.id`-keyed `ForEach` preserve the pane's identity (and
    /// its live surface) instead of the old two-sibling-`ForEach` layout that re-minted it on every float/embed.
    /// Drives the transition through the real `WorkspaceTreeOps.toggleFloating` so it is not hand-rigged.
    func testEmbedKeepsThePaneInOneKeyedCompositorCollection() throws {
        // Two tiled siblings A|B in one tab; B starts FLOATING.
        let aSpec = PaneSpec(kind: .terminal, title: "A")
        let bSpec = PaneSpec(kind: .terminal, title: "B")
        let ws0 = TreeWorkspace.singlePane(spec: aSpec)
        let a = ws0.allPaneIDs()[0]
        let (tiled, b) = WorkspaceTreeOps.splitPane(a, axis: .horizontal, newSpec: bSpec, in: ws0)
        let floatFrame = CGRect(x: 120, y: 120, width: 400, height: 300)
        let floated = WorkspaceTreeOps.toggleFloating(b, defaultFrame: floatFrame, bounds: bounds, in: tiled)

        // While FLOATING: B is in compositorLeaves once, flagged floating; A stays tiled.
        let floatTab = try XCTUnwrap(floated.activeSession?.activeTab)
        let floatPairs = floatTab.floatingPanes.map { (id: $0, frame: floated.spec(for: $0)?.floatingFrame) }
        let floatLayout = SplitTreeRenderModel.layout(for: floatTab, in: bounds, floating: floatPairs)
        let floatEntry = try XCTUnwrap(floatLayout.compositorLeaves.first { $0.id == b })
        XCTAssertTrue(floatEntry.isFloating, "B floats before the embed")
        XCTAssertEqual(floatLayout.compositorLeaves.count(where: { $0.id == b }), 1, "B is in the merged list once")

        // EMBED B back: floating → tiled.
        let embedded = WorkspaceTreeOps.toggleFloating(b, defaultFrame: floatFrame, bounds: bounds, in: floated)
        let embedTab = try XCTUnwrap(embedded.activeSession?.activeTab)
        let embedLayout = SplitTreeRenderModel.layout(for: embedTab, in: bounds, floating: [])
        let embedEntry = try XCTUnwrap(embedLayout.compositorLeaves.first { $0.id == b })

        // The pane is STILL in the single compositorLeaves collection, keyed by the SAME PaneID — only
        // isFloating flipped true→false. One `.id(PaneID)`-keyed ForEach therefore matches it across the
        // transition and never reconstructs the hosted surface.
        XCTAssertEqual(embedEntry.id, floatEntry.id, "same PaneID identity key across float→embed")
        XCTAssertFalse(embedEntry.isFloating, "after embed B is tiled")
        XCTAssertEqual(embedLayout.compositorLeaves.count(where: { $0.id == b }), 1, "still exactly one entry")
        XCTAssertTrue(embedLayout.floatingLeaves.isEmpty, "no floats remain after embed")
        XCTAssertEqual(Set(embedLayout.compositorLeaves.map(\.id)), [a, b], "both panes tiled in one collection")
    }
}
