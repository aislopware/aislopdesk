// TerminalLeafView — the content of a terminal pane leaf (logic-api §3.4). Composes, top→bottom:
//   [ terminal pixels (TerminalRendererFactory.make — the SEAM) over an optional block-decoration overlay ]
//   [ InputBar (over InputBarModel) ]
//   [ CwdPill row (bound to the pane's last-known cwd) ]
//
// SEAM usage: the terminal pixels come from `TerminalRendererFactory.make(model:isFocused:)`. The Xcode
// app target injects the production `GhosttyTerminalView`; a headless `swift build` registers no factory,
// so we mount `BuildStatusPlaceholderView` instead — this library NEVER imports libghostty/Metal.
//
// Lazy connect: `live.connection?.connect()` is called in a `.task` on appear (so restoring N panes does
// not slam N sockets). The whole leaf is keyed `.id(PaneID)` by the caller (PaneContainer) so the surface
// / connection is never reused across panes (identity hazard, logic-api §9).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct TerminalLeafView: View {
    @Environment(\.theme) private var theme

    /// The live session backing this pane (terminal model + input bar + claude status). When `nil`
    /// (no live handle yet, or a non-terminal kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// Workspace focus → drives the production renderer's first responder (only the focused pane types).
    let isFocused: Bool
    /// The pane's last-known cwd (from its spec) bound to the cwd pill. `nil`/empty ⇒ pill hidden.
    var cwd: String?
    /// The Claude-Code bottom integration bar coordinator. The footer mounts BELOW the InputBar only
    /// when the pane has an active agent (`claudeStatus != .none`, W5). `nil` ⇒ no footer (no agent).
    var footerCoordinator: AgentInputFooterCoordinator?
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// W5: the footer is shown only when the pane has an active agent. In a static snapshot a supplied
    /// coordinator forces it on (so the bar can be rendered headlessly).
    private var showsFooter: Bool {
        guard footerCoordinator != nil else { return false }
        if staticMirror { return true }
        return AgentInputFooterVisibility.isVisible(isNone: (live?.claudeStatus ?? ClaudeStatus.none) == .none)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let footerCoordinator, footerCoordinator.fileExplorer.isOpen {
                FileExplorerPanel(
                    model: footerCoordinator.fileExplorer,
                    onSelect: { footerCoordinator.handle(.selectFile($0)) },
                )
            }
            VStack(spacing: 0) {
                terminalSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let inputBar = live?.inputBar {
                    InputBar(model: inputBar, staticMirror: staticMirror)
                    cwdRow
                }
                // The Claude-Code bottom integration bar — under the InputBar, agent-gated (W5).
                if showsFooter, let footerCoordinator {
                    AgentInputFooter(coordinator: footerCoordinator, cwd: cwd, staticMirror: staticMirror)
                }
            }
        }
        .background(theme.background)
        .task(id: live?.id) { await connectIfNeeded() }
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. Block decoration is layered as an OVERLAY (never a content branch — libghostty-freeze
    /// guardrail).
    private var terminalSurface: some View {
        ZStack(alignment: .topLeading) {
            if let model = live?.terminalModel {
                if TerminalRendererFactory.shared != nil {
                    TerminalRendererFactory.make(model: model, isFocused: isFocused)
                } else {
                    BuildStatusPlaceholderView(model: model)
                }
                // Block decoration overlay (selection + hover toolbelt + separators). Kept an overlay.
                TerminalBlocksView(model: model.blocks, staticMirror: staticMirror)
                    .allowsHitTesting(false)
                    .opacity(staticMirror ? 1 : 0) // live grid owns block chrome; overlay is decoration-only
            } else {
                Color.clear
            }
        }
    }

    private var cwdRow: some View {
        HStack(spacing: WarpSpace.m) {
            CwdPill(
                cwd: cwd,
                interactive: live?.claudeStatus == ClaudeStatus.none,
                onChangeDirectory: {}, // stubbed menu hook (L3)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarpSpace.xl)
        .padding(.bottom, WarpSpace.m)
        .background(theme.background)
    }

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        await live?.connection?.connect()
    }
}
