// AgentInputFooter — the Claude-Code bottom integration bar (warp-bottom-bar.md §1). It sits BELOW the
// InputBar inside a terminal pane, shown only when that pane has an active agent
// (`claudeStatus != .none`, W5). One `Wrap::row` with `space-between`:
//
//   left cluster  = [ brand ✳ icon (trailing pad 8) ] + [ optional green suggestion pill ] +
//                   [ "+" ] [ "/remote-control" ] [ "File explorer" ] [ "Rich Input" ]   (gap 4)
//   right cluster = [ Settings sliders ] [ cwd chip ]                                        (gap 4)
//
// Container: surface_1 bg, 16pt horizontal gutter, 4pt vertical padding. Pills are `FooterPill`s
// (geometry in §2); the green chip is `SuggestionPill`. Each pill `onClick` emits an
// `AgentInputFooterAction` via a single closure → the coordinator interprets it.
//
// Wrapping: we use a SwiftUI HStack with a leading-aligned left cluster and a trailing right cluster
// separated by a Spacer (space-between). The clusters themselves are HStacks at gap 4; on a very narrow
// pane SwiftUI will clip rather than wrap (acceptable at L4 — Warp's `Wrap` reflow is a polish item).

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct AgentInputFooter: View {
    @Environment(\.theme) private var theme

    /// The coordinator owns the toggle/notification view-state + the action handler.
    let coordinator: AgentInputFooterCoordinator
    /// The pane's last-known cwd → the right-cluster cwd chip.
    var cwd: String?
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    private func emit(_ action: AgentInputFooterAction) { coordinator.handle(action) }

    private var brandIconSize: CGFloat { WarpType.monospaceSize }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            leftCluster
            Spacer(minLength: WarpSpace.m) // space-between
            rightCluster
        }
        .padding(.horizontal, WarpSpace.xl) // 16pt gutter (matches the terminal text padding above)
        .padding(.vertical, WarpSpace.s) // 4pt top/bottom
        .frame(maxWidth: .infinity)
        .background(theme.surface1)
    }

    private var leftCluster: some View {
        HStack(alignment: .center, spacing: WarpSpace.s) {
            // Brand ✳ — decorative, tinted claudeOrange/footer-brand, with an 8pt trailing pad (spec §1).
            AgentBrandGlyph(color: theme.agentFooterBrand, size: brandIconSize)
                .padding(.trailing, WarpSpace.s)

            if coordinator.showsNotificationChip {
                SuggestionPill(
                    agentName: coordinator.agentName,
                    staticMirror: staticMirror,
                    onEnable: { emit(.installNotifications) },
                    onDismiss: { emit(.dismissNotifications) },
                )
            }

            FooterPill(
                systemIcon: "plus", help: "Add context", staticMirror: staticMirror,
                action: { emit(.addContext) },
            )
            FooterPill(
                systemIcon: "phone", label: "/remote-control",
                help: "Start remote control", staticMirror: staticMirror,
                action: { emit(.startRemoteControl) },
            )
            FooterPill(
                systemIcon: "sidebar.left", label: "File explorer",
                isActive: coordinator.fileExplorerActive,
                help: "Toggle file explorer", staticMirror: staticMirror,
                action: { emit(.toggleFileExplorer) },
            )
            FooterPill(
                systemIcon: "text.cursor", label: "Rich Input",
                isActive: coordinator.richInputActive,
                help: "Toggle rich input", staticMirror: staticMirror,
                action: { emit(.toggleRichInput) },
            )
        }
    }

    private var rightCluster: some View {
        HStack(alignment: .center, spacing: WarpSpace.s) {
            FooterPill(
                systemIcon: "slider.horizontal.3",
                help: "Open coding agent settings", staticMirror: staticMirror,
                action: { emit(.openAgentSettings) },
            )
            // cwd chip — reuse the L3 CwdPill (folder glyph + path), non-interactive inside an agent.
            CwdPill(cwd: cwd, interactive: false)
        }
    }
}

/// Pure W5 visibility predicate — the footer mounts only when the pane has an active agent.
/// `claudeStatus != .none`. Unit-tested without a view.
enum AgentInputFooterVisibility {
    static func isVisible(isNone: Bool) -> Bool { !isNone }
}
