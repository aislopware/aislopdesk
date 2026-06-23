// L3PaneLogicTests — view-LOGIC tests for the L3 pane layer. View-model / pure-helper level only; NEVER
// instantiates Ghostty/VT/Metal/SCStream (hang-safety rule). Covers:
//   - PaneHeaderControls visibility rules (hover-reveal + close-only-in-split),
//   - BlockSelectionMapping (selection highlight + toolbelt + separator rules),
//   - PaneMath (divider drag→weight-delta + cwd truncate-from-beginning),
//   - SplitContainer's store-driven placement (split count, divider count) via the pure render model.

import AislopdeskAgentDetect
import CoreGraphics
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

final class PaneHeaderControlsTests: XCTestCase {
    func testControlsRevealedOnHoverOrActive() {
        XCTAssertTrue(PaneHeaderControls.controlsRevealed(isHovered: true, isActive: false))
        XCTAssertTrue(PaneHeaderControls.controlsRevealed(isHovered: false, isActive: true))
        XCTAssertFalse(PaneHeaderControls.controlsRevealed(isHovered: false, isActive: false))
    }

    func testOverflowFollowsRevealed() {
        XCTAssertTrue(PaneHeaderControls.showsOverflow(controlsRevealed: true))
        XCTAssertFalse(PaneHeaderControls.showsOverflow(controlsRevealed: false))
    }

    func testCloseOnlyShownInSplitAndRevealed() {
        // Spec §2.3: × is shown ONLY when the pane is in a split AND the controls are revealed.
        XCTAssertTrue(PaneHeaderControls.showsClose(isInSplit: true, controlsRevealed: true))
        XCTAssertFalse(
            PaneHeaderControls.showsClose(isInSplit: false, controlsRevealed: true),
            "single-pane tab has no ×",
        )
        XCTAssertFalse(
            PaneHeaderControls.showsClose(isInSplit: true, controlsRevealed: false),
            "× is hover-revealed, not shown at rest",
        )
    }
}

final class BlockSelectionMappingTests: XCTestCase {
    func testSelectionOpacity() {
        XCTAssertEqual(BlockSelectionMapping.selectionOpacity(isSelected: true), 1.0)
        XCTAssertEqual(BlockSelectionMapping.selectionOpacity(isSelected: false), 0.0)
    }

    func testToolbeltOnlyOnHoveredBlock() {
        XCTAssertTrue(BlockSelectionMapping.showsToolbelt(hoveredIndex: 3, blockIndex: 3))
        XCTAssertFalse(BlockSelectionMapping.showsToolbelt(hoveredIndex: 2, blockIndex: 3))
        XCTAssertFalse(BlockSelectionMapping.showsToolbelt(hoveredIndex: nil, blockIndex: 3))
    }

    func testSeparatorAboveEveryBlockButTheFirst() {
        XCTAssertFalse(BlockSelectionMapping.showsSeparatorAbove(blockIndex: 0, firstIndex: 0))
        XCTAssertTrue(BlockSelectionMapping.showsSeparatorAbove(blockIndex: 1, firstIndex: 0))
        XCTAssertFalse(
            BlockSelectionMapping.showsSeparatorAbove(blockIndex: 5, firstIndex: nil),
            "no blocks ⇒ no separator",
        )
    }
}

final class PaneMathTests: XCTestCase {
    func testWeightDeltaIsPixelIncrementOverSpan() {
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: 50, axisSpan: 500), 0.1, accuracy: 1e-9)
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: -25, axisSpan: 500), -0.05, accuracy: 1e-9)
    }

    func testWeightDeltaGuardsNonPositiveOrNonFiniteSpan() {
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: 50, axisSpan: 0), 0)
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: 50, axisSpan: -10), 0)
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: 50, axisSpan: .nan), 0)
        XCTAssertEqual(PaneMath.weightDelta(pixelIncrement: .infinity, axisSpan: 500), 0)
    }

    func testCwdTruncatesFromBeginning() {
        XCTAssertEqual(PaneMath.truncatedCwd("~/.config"), "~/.config", "short path unchanged")
        let long = "/Users/example/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Pane"
        let out = PaneMath.truncatedCwd(long, maxChars: 20)
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(out.hasPrefix("…"))
        XCTAssertTrue(long.hasSuffix(String(out.dropFirst())), "keeps the trailing leaf dirs")
    }
}

@MainActor
final class SplitContainerPlacementTests: XCTestCase {
    /// A dummy session factory (no sockets/PTY) — same hang-safe pattern as the rail tests.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { spec in DummyPaneSession(spec: spec) },
        )
    }

    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testSingleLeafHasNoDividers() throws {
        let store = makeStore()
        let tab = try? XCTUnwrap(store.tree.activeSession?.activeTab)
        let layout = try SplitTreeRenderModel.layout(for: XCTUnwrap(tab), in: bounds)
        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertTrue(layout.dividers.isEmpty, "a single-pane tab has no divider")
    }

    func testHorizontalSplitYieldsTwoLeavesAndOneVerticalDivider() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let tab = try? XCTUnwrap(store.tree.activeSession?.activeTab)
        let layout = try SplitTreeRenderModel.layout(for: XCTUnwrap(tab), in: bounds)
        XCTAssertEqual(layout.leaves.count, 2)
        XCTAssertEqual(layout.dividers.count, 1)
        XCTAssertEqual(
            layout.dividers.first?.axis,
            .horizontal,
            "a horizontal split's divider is dragged horizontally",
        )
        // The two columns split the width (side-by-side); both rects span the full height.
        for leaf in layout.leaves {
            XCTAssertEqual(leaf.rect.height, bounds.height, accuracy: 0.5)
            XCTAssertLessThan(leaf.rect.width, bounds.width)
        }
    }

    func testFocusTracksActivePaneAfterSplit() throws {
        let store = makeStore()
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let tab = try? XCTUnwrap(store.tree.activeSession?.activeTab)
        let active = tab?.activePane
        XCTAssertNotNil(active)
        let layout = try SplitTreeRenderModel.layout(for: XCTUnwrap(tab), in: bounds)
        XCTAssertTrue(layout.leaves.contains { $0.id == active }, "the focused pane is a placed leaf")
    }

    func testCloseSplitPaneFallsBackToSingleLeaf() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let tab = try? XCTUnwrap(store.tree.activeSession?.activeTab)
        let firstPane = try? XCTUnwrap(tab?.root.allPaneIDs().first)
        try store.closePaneTree(XCTUnwrap(firstPane))
        let after = try? XCTUnwrap(store.tree.activeSession?.activeTab)
        let layout = try SplitTreeRenderModel.layout(for: XCTUnwrap(after), in: bounds)
        XCTAssertEqual(layout.leaves.count, 1, "closing one of two split panes returns a single leaf")
        XCTAssertTrue(layout.dividers.isEmpty)
    }
}
