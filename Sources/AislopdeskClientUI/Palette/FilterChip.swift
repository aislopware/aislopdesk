// FilterChip — a zero-state filter pill (warp-overlays-actions.md §1.5 `filter_chip_renderer.rs`). A
// fully-rounded pill: idle = `surface_2` bg + 1pt `sub_text` border; hover = 2pt accent border (paddings
// shrink by 1 so the pill doesn't jump); selected = accent-tinted. Label = UI font at palette−2 + a leading
// SF Symbol. Clicking emits the chip's `QueryFilter` to the coordinator.

import AislopdeskDesignSystem
import SwiftUI

struct FilterChip: View {
    @Environment(\.theme) private var theme

    let filter: QueryFilter
    let isSelected: Bool
    var staticMirror: Bool = false
    let onSelect: () -> Void

    @State private var hovering = false

    private var active: Bool { isSelected || (hovering && !staticMirror) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: WarpSpace.s) {
                Image(systemName: filter.icon)
                    .font(.system(size: WarpType.overlineSize))
                Text(filter.label)
                    .font(WarpType.ui(WarpType.paletteSize - 2))
            }
            .foregroundStyle(isSelected ? theme.accent : theme.textSub)
            // Hover grows the border to 2pt; shrink padding by 1 so the pill doesn't jump (§1.5).
            .padding(.horizontal, active ? WarpSpace.xxl - 1 : WarpSpace.xxl)
            .padding(.vertical, active ? WarpSpace.m - 1 : WarpSpace.m)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? theme.accentOverlay1 : theme.surface2),
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        active ? theme.accent : theme.textSub,
                        lineWidth: active ? 2 : WarpBorder.width,
                    ),
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
