// RemoteWindowLeafView — the content of a remote-GUI (PATH 2 video) pane leaf (logic-api §4; L6). It is
// the video counterpart of `TerminalLeafView`. It composes the gated video view from the SEAM:
//
//   VideoWindowFactory.make(descriptor, context)   ← the app target injects the real Metal/VT-backed
//                                                     `VideoWindowView` (+ its existing VideoPaneControls
//                                                     overlay, W8 keep-as-is); a headless `swift build`
//                                                     registers no factory, so this library mounts the
//                                                     `RemoteWindowPlaceholderView` instead.
//
// This library NEVER imports VideoToolbox / Metal / ScreenCaptureKit / AislopdeskVideoClient — the only
// reference to the live pipeline is through the `VideoWindowFactory` / `RemoteWindowModel` seams in
// `AislopdeskWorkspaceCore`.
//
// Activation is STORE-GATED (not direct, logic-api §4.2): the leaf routes appear → `store.activateVideo`
// (admits to a `liveVideoCap` slot) and disappear → `store.deactivateVideo` (frees it). It observes
// `store.videoPromotionGeneration` to re-attempt admission when a sibling frees a slot. The leaf decides
// LIVE vs entry-form vs cap-gated via the PURE `RemoteGUIDisplay.resolve(...)` (no SwiftUI/Metal in the
// decision).
//
// The whole leaf is keyed `.id(PaneID)` by the caller (PaneContainer) so the video session is never reused
// across panes (identity hazard, logic-api §9).

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct RemoteWindowLeafView: View {
    @Environment(\.theme) private var theme

    /// The live session backing this pane (its ``RemoteWindowModel``). When `nil` (no live handle yet, or
    /// a non-video kind) the leaf shows the placeholder only.
    let live: LivePaneSession?
    /// The store — drives the cap-gated activate/deactivate + the slot re-attempt nudge.
    let store: WorkspaceStore
    /// This pane's id (the activation key).
    let paneID: PaneID
    /// Workspace focus → forwarded to the video view via ``RemotePaneContext`` (only the active pane
    /// consumes pointer/scroll + raises the host window).
    let isFocused: Bool
    /// `true` ⇒ a SecurityAgent / password dialog: the pane shows the "view-only — type on the host" hint.
    var isSecureDialog: Bool = false
    /// EAGER/STATIC render path for headless ImageRenderer snapshots (no activation, no `.task`).
    var staticMirror: Bool = false

    private var model: RemoteWindowModel? { live?.remoteWindow }

    /// The PURE display decision (live / entry-form / cap-gated) — reads only the model + the store's cap.
    private var display: RemoteGUIDisplay {
        RemoteGUIDisplay.resolve(
            admitted: live?.isVideoActive ?? false,
            configured: model?.canOpen ?? false,
            hasFreeSlot: store.hasFreeVideoSlot(for: paneID),
        )
    }

    var body: some View {
        ZStack {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        // STORE-GATED activation (logic-api §4.2): admit on appear, free the slot on disappear. Re-attempt
        // when a sibling frees a slot (observe `videoPromotionGeneration` via `.task(id:)`).
        .task(id: store.videoPromotionGeneration) { activateIfNeeded() }
        .onDisappear { if !staticMirror { store.deactivateVideo(paneID) } }
    }

    @ViewBuilder private var content: some View {
        switch display {
        case .live:
            // The live video view + its existing VideoPaneControls overlay come from the factory (W8). The
            // descriptor carries the full endpoint; `RemotePaneContext` threads focus + activate-on-click.
            if let descriptor = model?.active {
                VideoWindowFactory.make(descriptor, context: paneContext)
                    .overlay(alignment: .top) {
                        if isSecureDialog { secureHint }
                    }
            } else {
                RemoteWindowPlaceholderView(state: .connecting, title: model?.title ?? "Remote window")
            }
        case .entryForm:
            // Configured-but-not-yet-admitted (a free slot exists; admission is auto-attempted) OR
            // unconfigured. In the picker-first UX a pane is always pre-bound, so this is the brief
            // "connecting" beat; an unbound pane shows "no window" guidance.
            RemoteWindowPlaceholderView(
                state: (model?.canOpen ?? false) ? .connecting : .unbound,
                title: model?.title ?? "Remote window",
            )
        case .gated:
            RemoteWindowPlaceholderView(state: .gated, title: model?.title ?? "Remote window")
        }
    }

    private var secureHint: some View {
        Text("View-only — type on the host (secure field)")
            .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
            .foregroundStyle(theme.background)
            .padding(.horizontal, WarpSpace.m)
            .padding(.vertical, WarpSpace.xs)
            .background(
                Capsule(style: .continuous).fill(theme.uiWarning),
            )
            .padding(WarpSpace.m)
            .allowsHitTesting(false)
    }

    /// The per-render context handed through the seam: forward pointer/scroll only when this pane is the
    /// active one; a click activates it (workspace focus) + the live view raises the host window.
    private var paneContext: RemotePaneContext {
        RemotePaneContext(
            isActive: isFocused,
            onActivate: { store.focusPaneTree(paneID) },
            // The IDE shell has no canvas-pan; a scroll over a non-active pane is a no-op here.
            onCanvasScroll: { _ in },
            onKeyInjectorReady: { [weak model] sink in model?.keyInjector = sink },
        )
    }

    private func activateIfNeeded() {
        guard !staticMirror else { return }
        // `activateVideo` is a no-op `true` if already active and only admits a video kind with a free
        // slot; the model's `open()` runs inside `setVideoActive` (logic-api §4). A `false` return leaves
        // the gated placeholder up until a slot frees and the generation nudge re-runs this.
        store.activateVideo(paneID)
    }
}
