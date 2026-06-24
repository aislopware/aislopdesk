// TerminalLeafView — the content of a terminal pane leaf (REBUILD-V2, L2 MINIMAL). Composes, top→bottom:
//   [ terminal surface seam (TerminalRendererFactory.make — the SEAM, else BuildStatusPlaceholderView) ]
//   [ InputBar (over InputBarModel) ]
//   [ cwd label row (CwdPill bound to the pane's last-known cwd) ]
//
// SEAM usage: the terminal pixels come from `TerminalRendererFactory.make(model:isFocused:)`. The Xcode
// app target injects the production `GhosttyTerminalView`; a headless `swift build` registers no factory,
// so we mount `BuildStatusPlaceholderView` instead — this library NEVER imports libghostty/Metal.
//
// Lazy connect: `live.connection?.connect()` is called in a `.task` on appear (so restoring N panes does
// not slam N sockets). The whole leaf is keyed `.id(PaneID)` by the caller (PaneContainer) so the surface
// / connection is never reused across panes (identity hazard). SYSTEM colours only.
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L3): the `TerminalBlocksView` command-block decoration overlay.
//   - TODO(L5): the `AgentInputFooter` (Claude bottom bar) below the InputBar.
//   - TODO(L5): the `FileExplorerPanel` side panel.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct TerminalLeafView: View {
    /// The live session backing this pane (terminal model + input bar). When `nil` (no live handle yet, or
    /// a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool
    /// The pane's last-known cwd (from its spec) bound to the cwd row. `nil`/empty ⇒ row hidden.
    var cwd: String?
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // TODO(L5): mount `FileExplorerPanel` beside the surface when the per-pane explorer is open.
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let inputBar = live?.inputBar {
                InputBar(model: inputBar, staticMirror: staticMirror)
                cwdRow
            }
            // TODO(L5): mount `AgentInputFooter` here (under the InputBar, agent-gated).
        }
        .background(NativePaneColor.terminalBackground)
        .task(id: live?.id) { await connectIfNeeded() }
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam.
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                if TerminalRendererFactory.shared != nil {
                    TerminalRendererFactory.make(model: model, isFocused: isFocused)
                } else {
                    BuildStatusPlaceholderView(model: model)
                }
                // TODO(L3): layer `TerminalBlocksView` here as a decoration OVERLAY (never a content
                // branch — libghostty-freeze guardrail).
            } else {
                Color.clear
            }
        }
    }

    private var cwdRow: some View {
        HStack(spacing: 8) {
            CwdPill(cwd: cwd)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background(NativePaneColor.terminalBackground)
    }

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        await live?.connection?.connect()
    }
}
#endif
