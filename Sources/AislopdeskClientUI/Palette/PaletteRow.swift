// PaletteRow — one result row in the command palette (warp-overlays-actions.md §1.3). Layout:
//   [ 16pt icon ][ title (14pt) over optional subtitle (sub-text) ][ Spacer ][ right-aligned shortcut chip ]
// Selected state = an `fg_overlay_2` rounded fill (4pt radius) with a small outer gutter so the highlight
// isn't full-bleed. A SEPARATOR row renders just a dim overline label (no highlight, no hover, no run).
//
// Mouse-down must NOT bubble to the backdrop's dismiss handler (warp `result_renderer.rs:159`) — the row's
// Button + the backdrop's contentShape/onTapGesture ordering handles this in SwiftUI (the Button consumes
// the tap), and the palette card itself stops propagation in CommandPaletteView.

import AislopdeskDesignSystem
import SwiftUI

struct PaletteRow: View {
    @Environment(\.theme) private var theme

    let item: PaletteItem
    let isSelected: Bool
    var staticMirror: Bool = false
    let onRun: () -> Void

    @State private var hovering = false

    var body: some View {
        if item.isSeparator {
            separator
        } else {
            row
        }
    }

    // MARK: Separator (section header)

    private var separator: some View {
        Text(item.title.uppercased())
            .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
            .foregroundStyle(theme.textDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarpSpace.dialogHorizontal)
            .padding(.top, WarpSpace.m)
            .padding(.bottom, WarpSpace.s)
    }

    // MARK: Interactive result row

    private var row: some View {
        Button(action: onRun) {
            HStack(spacing: WarpSpace.xl) {
                Image(systemName: item.icon.isEmpty ? "circle" : item.icon)
                    .font(.system(size: WarpSize.iconGlyph))
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                    .foregroundStyle(isSelected ? theme.textMain : theme.textSub)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(WarpType.ui(WarpType.paletteSize))
                        .foregroundStyle(theme.textMain)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(WarpType.ui(WarpType.overlineSize))
                            .foregroundStyle(theme.textSub)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: WarpSpace.m)
                if let shortcut = item.shortcut, !shortcut.isEmpty {
                    ShortcutHintChip(text: shortcut)
                }
            }
            .padding(.horizontal, WarpSpace.dialogHorizontal)
            .padding(.vertical, WarpSpace.basePadVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var rowBackground: some View {
        let highlighted = isSelected || (hovering && !staticMirror)
        if highlighted {
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .fill(theme.fgOverlay2)
                .padding(.horizontal, WarpSpace.s) // outer gutter so the highlight isn't full-bleed (§1.3)
        } else {
            Color.clear
        }
    }
}

/// The right-aligned keyboard-shortcut hint chip (e.g. "⌘T") — a 3pt-radius pill at the kb-shortcut tokens.
struct ShortcutHintChip: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
            .foregroundStyle(theme.textSub)
            .padding(.horizontal, WarpSpace.m)
            .padding(.vertical, WarpSpace.xxs)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.pill, style: .continuous)
                    .fill(theme.fgOverlay1)
                    .overlay(
                        RoundedRectangle(cornerRadius: WarpRadius.pill, style: .continuous)
                            .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
                    ),
            )
    }
}
