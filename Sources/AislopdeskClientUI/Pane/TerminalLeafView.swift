// TerminalLeafView — the content of a terminal pane leaf (REBUILD-V2, L2 MINIMAL). Composes, top→bottom:
//   [ terminal surface seam (TerminalRendererFactory.make — the SEAM, else BuildStatusPlaceholderView) ]
// otty shows NO persistent cwd chrome in the resting window — the working-directory chip only appears in
// menus/overlays — so there is no bottom cwd pill here. The bottom command `InputBar` is likewise NOT
// mounted: otty has no persistent composer in the resting window (it toggles one with ⌘⇧E). `InputBar` /
// `InputBarModel` stay in the tree for that future composer — re-mount it below the surface to restore a
// persistent bar.
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
//   - TODO(L5): the `AgentInputFooter` (Claude bottom bar) at the pane bottom.
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
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// E5 ES-E5-1..4: the in-pane ⌘F find bar's view-model (pure ``TerminalSearchController`` + the libghostty
    /// `search:` passthrough). Owned per-leaf and wired to the pane's `onRequestFind*` callbacks in `.task`;
    /// the leaf is `.id(PaneID)`-keyed by `PaneContainer`, so this `@State` is per-pane (no cross-pane bleed).
    @State private var findBar = TerminalFindBarModel()

    var body: some View {
        VStack(spacing: 0) {
            // TODO(L5): mount `FileExplorerPanel` beside the surface when the per-pane explorer is open.
            terminalSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Bottom command `InputBar` intentionally NOT mounted — otty has no persistent composer in the
            // resting window (toggled with ⌘⇧E). Re-add `InputBar(model:staticMirror:)` here to restore it.
            // TODO(L5): mount `AgentInputFooter` at the pane bottom (agent-gated).
        }
        .background(NativePaneColor.terminalBackground)
        .task(id: live?.id) { await connectIfNeeded() }
        // Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks on appear AND on every live-session swap (`initial: true`
        // fires once up-front, then on each `live?.id` change). A synchronous `@MainActor` closure — no actor
        // hop, unlike the `@Sendable async` `.task` action above.
        .onChange(of: live?.id, initial: true) { wireFindCallbacks() }
        // Clear the callbacks when the leaf is torn down so a dead `@State` holder can't be driven by a
        // surviving model (the model is owned by the live session, which can outlive this `.id(PaneID)` leaf).
        .onDisappear { clearFindCallbacks() }
    }

    /// The terminal pixels (the seam) — production renderer if the app registered one, else the headless
    /// placeholder. This library NEVER imports libghostty/Metal: it only calls the factory seam. The ⌘F find
    /// bar floats top-trailing OVER the surface (it does not reflow the buffer) — never in the static-mirror
    /// snapshot path.
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
        .overlay(alignment: .topTrailing) {
            if !staticMirror, findBar.visible, live?.terminalModel != nil {
                TerminalFindBar(model: findBar)
                    .padding(Otty.Metric.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Otty.Anim.reveal, value: findBar.visible)
    }

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel == nil`);
    /// `terminalModel` is non-nil from session creation for a terminal pane, so this lands on first `.task`.
    private func wireFindCallbacks() {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's `@State`.
    private func clearFindCallbacks() {
        findBar.attach(nil)
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    private func connectIfNeeded() async {
        guard !staticMirror else { return }
        await live?.connection?.connect()
    }
}
#endif
