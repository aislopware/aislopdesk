// ThemedContextMenu — the token-consistent dropdown for the PaneHeader ⋮ overflow and the rail TabRow
// kebab (warp-overlays-actions.md §3.3 `Menu`). A `surface_2` card at 5pt radius with the opt-in heavier
// menu shadow, 9pt content V-padding, item rows at 5pt V / 14pt H. Hover highlights the row; a destructive
// row tints its label red; separators are a 1pt `disabled` hairline with 4pt V-margin.
//
// It is presented as a SwiftUI `.popover` anchored on the ⋮/kebab button so it tracks the anchor and
// auto-flips at the window edge (Warp's `should_reverse_layout`). Selecting a row runs its store closure
// then dismisses (the binding `isPresented` is flipped false).

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct ThemedContextMenu: View {
    @Environment(\.theme) private var theme

    let items: [ContextMenuItem]
    let store: WorkspaceStore
    let onDismiss: () -> Void

    /// Menu-shadow tint = black @ 48/255 (heavier than the palette's 32), per §3.3.
    private static let menuShadowColor = ColorU(r: 0, g: 0, b: 0, a: 48)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.isSeparator {
                    Rectangle()
                        .fill(theme.textDisabled)
                        .frame(height: WarpBorder.width)
                        .padding(.vertical, WarpSpace.s)
                } else {
                    MenuItemRow(item: item, store: store, onDismiss: onDismiss)
                }
            }
        }
        .padding(.vertical, 9) // MENU_VERTICAL_PADDING
        .frame(minWidth: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.surface2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
        .shadow(color: Color(Self.menuShadowColor), radius: WarpShadow.blur, x: 0, y: WarpShadow.offset.height)
    }
}

private struct MenuItemRow: View {
    @Environment(\.theme) private var theme

    let item: ContextMenuItem
    let store: WorkspaceStore
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            item.run?(store)
            onDismiss()
        } label: {
            HStack(spacing: WarpSpace.m) {
                Image(systemName: item.icon)
                    .font(.system(size: WarpType.uiSize))
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                    .foregroundStyle(labelColor)
                Text(item.title)
                    .font(WarpType.ui(WarpType.uiSize))
                    .foregroundStyle(labelColor)
                Spacer(minLength: WarpSpace.xl)
                if let shortcut = item.shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
                        .foregroundStyle(theme.textDisabled)
                }
            }
            .padding(.horizontal, 14) // MENU_ITEM_HORIZONTAL_PADDING
            .padding(.vertical, WarpSpace.basePadVertical) // 5pt
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovering ? theme.fgOverlay2 : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var labelColor: Color {
        if item.role == .destructive { return theme.uiError }
        return theme.textMain
    }
}
