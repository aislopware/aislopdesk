// SplitContainer — renders the active tab's pane tree (warp-panes-blocks.md §1.1; logic-api §1.5).
//
// It reads the PURE render model `SplitTreeRenderModel.layout(for: tab, in: bounds)` (the same solver the
// FocusResolver uses) which turns the tab's `SplitNode` tree into placed leaf rects + divider handle rects.
// Branch nodes are NOT walked into nested HStacks/VStacks here — the solver already produced absolute rects,
// so we place every leaf + divider ABSOLUTELY in ONE ZStack keyed `.id(PaneID)`. This honors the repo
// guardrail "drive geometry in one structure, never tree-relocate a pane on a mode change" (a zoom, a split
// add/remove, a resize all just re-emit rects — the leaf views keep their identity and are repositioned).
//
// Dividers drag → `store.resizeDividerTree`; double-click → `store.balanceActivePaneSplits` (even reset).

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct SplitContainer: View {
    @Environment(\.theme) private var theme

    let store: WorkspaceStore
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    private var tab: AislopdeskWorkspaceCore.Tab? { store.tree.activeSession?.activeTab }

    /// The active tab's focused pane (drives focus dim / triangle / renderer first-responder).
    private var focusedPane: PaneID? { tab?.activePane }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            content(in: bounds)
        }
        .background(theme.background)
    }

    @ViewBuilder
    private func content(in bounds: CGRect) -> some View {
        if let tab {
            let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
            let isSplit = layout.leaves.count > 1
            ZStack(alignment: .topLeading) {
                ForEach(layout.leaves, id: \.id) { leaf in
                    PaneContainer(
                        store: store,
                        paneID: leaf.id,
                        isFocused: leaf.id == focusedPane,
                        isInSplit: isSplit,
                        staticMirror: staticMirror,
                    )
                    .id(leaf.id) // identity hazard: never reuse a surface across panes (logic-api §9)
                    .frame(width: leaf.rect.width, height: leaf.rect.height)
                    .position(x: leaf.rect.midX, y: leaf.rect.midY)
                }
                ForEach(layout.dividers, id: \.self) { handle in
                    PaneDivider(
                        handle: handle,
                        axisSpan: handle.parentSpan,
                        flexSum: handle.flexSum,
                        onResize: { delta in
                            store.resizeDividerTree(
                                splitID: handle.splitID,
                                leadingChildIndex: handle.childIndex,
                                delta: delta,
                            )
                        },
                        onReset: { store.balanceActivePaneSplits() },
                    )
                    .position(x: handle.rect.midX, y: handle.rect.midY)
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        } else {
            Color.clear
        }
    }
}

// `DividerHandle` needs to be `Hashable` to key the `ForEach`. It is `Equatable + Sendable`; derive a
// stable id from its split + index + axis (a tab has at most one divider per (split, leading-index)).
extension SplitTreeRenderModel.DividerHandle: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(splitID)
        hasher.combine(childIndex)
        hasher.combine(axis)
    }
}
