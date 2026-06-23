// BuildStatusPlaceholderView — the HEADLESS terminal-renderer fallback (logic-api §3.1, A2 SEAM SPLIT).
//
// The cross-platform `AislopdeskClientUI` library must NOT import libghostty/Metal. The production
// renderer (`GhosttyTerminalView`) is injected by the Xcode app target via `TerminalRendererFactory`.
// When no factory is registered (a headless `swift build`, previews, or this library running without the
// app target) the terminal leaf renders THIS panel instead — build-status telemetry over the pane bg, not
// an emulated terminal (libghostty IS the renderer per DECISIONS / doc 17).
//
// It reads only `TerminalViewModel` connection state + bytes-received (no surface attach), so it is safe
// in tests and previews.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

/// The headless build-status placeholder for a terminal pane. Conforms to the seam's
/// ``TerminalRenderingView`` so the app target could register it as a debug factory if desired; the
/// library mounts it directly when `TerminalRendererFactory.shared == nil`.
struct BuildStatusPlaceholderView: TerminalRenderingView {
    @Environment(\.theme) private var theme

    private let model: TerminalViewModel

    init(model: TerminalViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: WarpSpace.m) {
            Image(systemName: "terminal")
                .font(.system(size: WarpType.headerSize + WarpSpace.l, weight: .regular))
                .foregroundStyle(theme.textSub)
            Text("libghostty renderer not built")
                .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                .foregroundStyle(theme.textMain)
            Text("Run ThirdParty/ghostty/build-libghostty.sh — the headless build renders this panel.")
                .font(WarpType.ui(WarpType.overlineSize))
                .foregroundStyle(theme.textSub)
                .multilineTextAlignment(.center)
            statusLine
        }
        .padding(WarpSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    @ViewBuilder private var statusLine: some View {
        let status = model.connectionStatus
        HStack(spacing: WarpSpace.s) {
            Circle()
                .fill(status.isLive ? theme.uiGreen : theme.textDisabled)
                .frame(width: WarpSize.badge, height: WarpSize.badge)
            Text("\(status.label) · \(model.bytesReceived) bytes")
                .font(WarpType.mono(WarpType.overlineSize))
                .foregroundStyle(theme.textSub)
        }
    }
}
