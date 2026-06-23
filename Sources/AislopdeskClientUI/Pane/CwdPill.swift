// CwdPill — the cwd context chip (warp-panes-blocks.md §5). A folder glyph (cyan) + the active block's
// pwd in a rounded surface_1 pill with a 1px neutral_3 (fg@15%) border and 4pt radius. Click opens a
// "Change working directory" menu hook (stubbed action at L3). Bound to the pane's last-known cwd.
//
// Non-interactive (no menu, no hover swap) inside an active CLI-agent session per spec §5.1 — we expose
// that as `interactive: Bool`.

import AislopdeskDesignSystem
import SwiftUI

struct CwdPill: View {
    @Environment(\.theme) private var theme

    /// The working-directory path to display (already the pane's last-known cwd). `nil`/empty ⇒ hidden.
    let cwd: String?
    /// Whether the chip is interactive (false inside a CLI-agent session — spec §5.1).
    var interactive: Bool = true
    /// Click hook → "Change working directory" (stubbed at L3).
    var onChangeDirectory: () -> Void = {}

    @State private var hovering = false

    /// Cyan from the terminal ANSI palette (spec: folder icon + text = `ansi_fg_cyan()`).
    private var cyan: Color { Color(theme.ansiNormal.cyan) }

    /// Truncate from the beginning so the leaf directory stays visible (spec: `truncate_from_beginning`,
    /// max 40 chars).
    private var displayPath: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return PaneMath.truncatedCwd(cwd)
    }

    var body: some View {
        if let cwd, !cwd.isEmpty {
            content(cwd)
        }
    }

    @ViewBuilder
    private func content(_: String) -> some View {
        let pill = HStack(spacing: WarpSpace.s) {
            Image(systemName: "folder")
                .font(.system(size: WarpType.monospaceSize - 1, weight: .regular))
                .foregroundStyle(cyan)
            Text(displayPath)
                .font(WarpType.mono(WarpType.monospaceSize - 1, weight: .semibold))
                .foregroundStyle(cyan)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, WarpSpace.chipPadHorizontal)
        .padding(.vertical, WarpSpace.chipPadVertical)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .fill(interactive && hovering ? theme.surface2 : theme.surface1),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .strokeBorder(theme.surface3, lineWidth: WarpBorder.width),
        )

        if interactive {
            Button(action: onChangeDirectory) { pill }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Change working directory")
            #if os(macOS)
                .pointerStyle(.link)
            #endif
        } else {
            pill.help("Working directory")
        }
    }
}
