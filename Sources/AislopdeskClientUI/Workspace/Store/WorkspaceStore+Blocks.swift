import AislopdeskTerminal
import Foundation

// MARK: - WorkspaceStore × Command Blocks (WB2 — Warp-style per-command blocks)

/// The WB2 active-pane Block ops, split into their own extension so the (already large) ``WorkspaceStore``
/// body stays under the lint ceiling. They mirror ``WorkspaceStore/requestFindInActivePane()``: resolve the
/// active pane's live terminal model (in whichever live model is active), then route to its block hooks.
public extension WorkspaceStore {
    /// The active pane's live terminal model in WHICHEVER live model is active (W5): the tree's active pane
    /// on the IDE shell, the canvas focus on the retained-but-dead path. `nil` for a non-terminal active
    /// pane (`.remoteGUI` / `.systemDialog`) or an empty shell. Shared by the WB2 block ops so the
    /// navigator / jump work on both paths.
    private var activeTerminalModel: TerminalViewModel? {
        let activeID: PaneID? =
            switch liveModel {
            case .tree: tree.activeSession?.activeTab?.activePane
            case .canvas: focusedPane
            }
        guard let activeID, let live = handle(for: activeID) as? LivePaneSession else { return nil }
        return live.terminalModel
    }

    /// Opens the Command Navigator (WB2: ⌃⌘O / the chrome chip / a menu item) over the active pane — routes
    /// to its ``TerminalViewModel/onRequestBlockNavigator`` (set by ``TerminalScreenView``). A no-op for a
    /// non-terminal active pane or an empty shell. The navigator's recent-blocks list is the PURE
    /// ``TerminalBlockModel`` (unit-tested).
    func requestBlockNavigatorInActivePane() {
        activeTerminalModel?.onRequestBlockNavigator?()
    }

    /// Jumps the active pane's viewport to the previous (`delta < 0`) / next (`delta > 0`) shell prompt —
    /// WB2's ⌃⌘[ / ⌃⌘] (and the navigator's per-row jump). Routes to libghostty's `jump_to_prompt:<delta>`
    /// via the active surface's ``TerminalSurfaceActions`` seam (the same lever W14's jump-to-prompt uses).
    /// A no-op for a non-terminal pane, an empty shell, or a headless/placeholder surface (no seam).
    func jumpToBlockInActivePane(delta: Int) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        actions.performBindingAction("jump_to_prompt:\(delta)")
    }
}
