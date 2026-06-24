// PaneContainer — one placed leaf = a PaneHeader over the pane content (REBUILD-V2, L2).
//
// Resolves the pane's `LivePaneSession` handle + `PaneSpec` from the store, routes by pane kind to the
// content view (terminal → `TerminalLeafView`; `.remoteGUI`/`.systemDialog` → the `VideoWindowFactory`
// seam, else a native placeholder), and composes the header over the content. A native focus ring
// (accent stroke when focused, else separator hairline). Tap anywhere focuses the pane via the store.
//
// The whole pane is keyed `.id(PaneID)` by the SplitContainer so the surface/connection are never reused
// across panes (identity hazard). SYSTEM colours/fonts only.
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L5): the per-pane agent footer coordinator + overflow context menu.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneContainer: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// Whether this pane is the active tab's active (focused) pane.
    let isFocused: Bool
    /// Whether this pane lives in a split (≥2 panes in the tab) — gates the header close button.
    let isInSplit: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// The live session for this pane (terminal model / input bar), if materialized.
    private var live: LivePaneSession? { store.handle(for: paneID) as? LivePaneSession }

    private var spec: PaneSpec? { store.tree.activeSession?.specs[paneID] }

    /// The pane's kind drives which leaf view renders. Reads the live handle's kind (falls back to spec).
    private var kind: PaneKind { live?.kind ?? spec?.kind ?? .terminal }

    /// Whether this is a video (PATH 2) pane. `PaneKind.isVideo` is internal to WorkspaceCore, so the
    /// equivalent check is inlined here (the case set matches `PaneKind.isVideo`).
    private var isVideo: Bool { kind == .remoteGUI || kind == .systemDialog }

    private var title: String {
        let t = spec?.lastKnownTitle ?? live?.terminalModel?.title ?? spec?.title ?? ""
        if t.isEmpty { return isVideo ? "Remote window" : "Terminal" }
        return t
    }

    /// The leaf content, routed by pane kind. A terminal pane renders the `TerminalLeafView` over the
    /// terminal-renderer seam; a video pane shows a native placeholder for now.
    @ViewBuilder private var paneContent: some View {
        if isVideo {
            // TODO(L5): mount the `VideoWindowFactory` seam (descriptor/context, host-window picker, key
            // injection) for real remote-window streaming. L2 shows a native placeholder.
            remotePlaceholder
        } else {
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                cwd: spec?.lastKnownCwd,
                staticMirror: staticMirror,
            )
        }
    }

    private var remotePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: kind == .systemDialog ? "lock.shield" : "display")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text(kind == .systemDialog ? "system dialog" : "remote window")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: title,
                isActive: isFocused,
                isInSplit: isInSplit,
                onSplitRight: { store.splitPaneTree(paneID, axis: .horizontal, kind: .terminal) },
                onSplitDown: { store.splitPaneTree(paneID, axis: .vertical, kind: .terminal) },
                onClose: { store.requestClosePaneTree(paneID) },
            )
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.window)
        // Native focus ring: accent stroke when focused, else a separator hairline.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor : NativePaneColor.separator, lineWidth: 1),
        )
        .contentShape(Rectangle())
        .onTapGesture { store.focusPaneTree(paneID) }
    }
}
#endif
