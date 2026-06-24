// InspectorColumn — the right inspector (REBUILD-V2, L3): the first-class Command Navigator. Resolves the
// ACTIVE pane → its `LivePaneSession` → `terminalModel.blocks` (the pure `TerminalBlockModel` folded from
// wire types 28/29) and renders `BlockHistoryView`. A non-terminal / unmaterialized active pane shows a
// neutral empty state. The output-request flow is the pane's `TerminalViewModel.copyBlockOutput` (wire type
// 15 → 29, VT-stripped to plain text). SYSTEM material background, SYSTEM colours/fonts only.
//
// Resolution mirrors L2's `PaneContainer`: `store.handle(for: paneID) as? LivePaneSession` keyed by the
// active tab's active pane — no new store API.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct InspectorColumn: View {
    let store: WorkspaceStore

    /// The active tab's active pane id (same path L2's NavigatorColumn selection uses).
    private var activePaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// The active pane's live session (terminal model), if materialized and a terminal kind.
    private var activeLive: LivePaneSession? {
        guard let id = activePaneID else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's terminal view-model — carries both the block store and the output-request flow.
    private var terminalModel: TerminalViewModel? { activeLive?.terminalModel }

    var body: some View {
        Group {
            if let terminalModel {
                BlockHistoryView(
                    model: terminalModel.blocks,
                    requestOutput: { index, completion in
                        terminalModel.copyBlockOutput(index: index, onResult: completion)
                    },
                )
            } else {
                ContentUnavailableView(
                    "No Commands",
                    systemImage: "terminal",
                    description: Text("Select a terminal pane to see its command history"),
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
    }
}
#endif
