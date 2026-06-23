// RemoteWindowPlaceholderView — the HEADLESS remote-GUI-pane fallback (logic-api §4.3, A2 SEAM SPLIT).
//
// The cross-platform `AislopdeskClientUI` library must NOT import VideoToolbox / Metal / ScreenCaptureKit
// (they HANG without a window-server + TCC session). The production `VideoWindowView` is injected by the
// Xcode app target via `VideoWindowFactory`. When no factory is registered (a headless `swift build`,
// previews, this library without the app target) — or while the video cap is saturated, or a binding is
// stale — the remote-window leaf renders THIS panel instead.
//
// It reads only value state (a title + a coarse state enum), so it is safe in tests and previews.

import AislopdeskDesignSystem
import SwiftUI

struct RemoteWindowPlaceholderView: View {
    @Environment(\.theme) private var theme

    /// Why the live video view is not (yet) shown.
    enum State: Equatable {
        /// Admitted to a cap slot; the live pipeline is coming up (or no factory in a headless build).
        case connecting
        /// Configured + admission refused because ``WorkspaceStore/liveVideoCap`` is saturated.
        case gated
        /// No window bound (the picker found nothing / the bound window is gone host-side).
        case unbound
    }

    let state: State
    var title: String = "Remote window"

    private var glyph: String {
        switch state {
        case .connecting: "rectangle.on.rectangle"
        case .gated: "rectangle.slash"
        case .unbound: "questionmark.square.dashed"
        }
    }

    private var headline: String {
        switch state {
        case .connecting: "Connecting to the host window…"
        case .gated: "Video paused — another window is using the live slot"
        case .unbound: "No host window bound"
        }
    }

    private var detail: String {
        switch state {
        case .connecting:
            "Streaming \"\(title)\". The live view appears when the host begins capturing."
        case .gated:
            "The live-video cap is saturated. This pane resumes when another remote window closes."
        case .unbound:
            "Pick a host window from the Remote Window picker to start streaming."
        }
    }

    var body: some View {
        VStack(spacing: WarpSpace.m) {
            Image(systemName: glyph)
                .font(.system(size: WarpType.headerSize + WarpSpace.l, weight: .regular))
                .foregroundStyle(theme.textSub)
            Text(headline)
                .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                .foregroundStyle(theme.textMain)
            Text(detail)
                .font(WarpType.ui(WarpType.overlineSize))
                .foregroundStyle(theme.textSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WarpSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
