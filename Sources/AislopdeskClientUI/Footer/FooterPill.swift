// FooterPill — the generic Warp `ActionButton` pill at `ButtonSize::AgentInputButton`
// (warp-bottom-bar.md §2 / §4A). Every standard footer pill (+, /remote-control, File explorer,
// Rich Input, Settings, cwd chip) is one of these.
//
// Geometry (spec §2): 4pt corner radius, 1px hairline border = `neutral_3` (= fg@15% over bg, exposed
// as `theme.surface3`), fill `surface_1` at rest → `surface_2` on hover, muted `sub_text` label/icon,
// 4pt horizontal padding (only when NOT icon-only — an icon-only pill is square, no hpad), icon sized to
// the line height, font = UI font at `monospace−1`, icon→label gap 4, label→keybind gap 4.
//
// States (spec §2 hover/active): a TOGGLED-ON pill (Rich Input / File explorer ON) renders with the
// hover fill permanently (Warp shows "on" by forcing `theme.background(true)` == surface_2) — so we set
// the active fill to `surface_2`. An icon-only pill drops horizontal padding and becomes square.

import AislopdeskDesignSystem
import SwiftUI

struct FooterPill: View {
    @Environment(\.theme) private var theme

    /// Optional leading icon (SF Symbol). `nil` ⇒ label-only.
    var systemIcon: String?
    /// Optional label. `nil`/empty + an icon ⇒ icon-only (square, no horizontal padding).
    var label: String?
    /// Optional trailing keybind hint (e.g. "⌃G") — plain dim text after the label (spec §2 compact).
    var keybind: String?
    /// Toggled-on state — paints the hover/active fill permanently (spec §2 / §4D).
    var isActive: Bool = false
    /// Tint override for the icon (e.g. red stop glyph). `nil` ⇒ the muted sub-text color.
    var iconTint: Color?
    /// Accessibility/tooltip text.
    var help: String?
    /// EAGER/STATIC render path for headless ImageRenderer snapshots (no hover first-responder).
    var staticMirror: Bool = false
    let action: () -> Void

    @State private var hovering = false

    /// Icon-only when there is an icon but no visible label.
    private var isIconOnly: Bool { (label?.isEmpty ?? true) && systemIcon != nil }

    /// Rest vs hover/active fill. The live REST footer pills sit at ≈ #262A2C (`footerPillFill` =
    /// neutral4); the FILLED/highlighted pill (e.g. /remote-control) reads ≈ #44494C
    /// (`footerPillFillActive` = neutral18). Re-sampled from the live ref crops — the old neutral25
    /// (#565859) rest tier was ~3 tiers too bright.
    private var fill: Color {
        (isActive || (hovering && !staticMirror)) ? theme.footerPillFillActive : theme.footerPillFill
    }

    private var iconSize: CGFloat { WarpType.monospaceSize }
    private var fontSize: CGFloat { WarpType.monospaceSize - 1 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WarpSpace.s) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(iconTint ?? theme.textSub)
                }
                if let label, !label.isEmpty {
                    Text(label)
                        .font(WarpType.ui(fontSize))
                        .foregroundStyle(theme.textSub)
                        .lineLimit(1)
                }
                if let keybind, !keybind.isEmpty {
                    Text(keybind)
                        .font(WarpType.ui(fontSize))
                        // Dim/muted gray (Warp uses `disabled_text_color` for the compact keybind).
                        .foregroundStyle(theme.textDisabled)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isIconOnly ? 0 : WarpSpace.pillPad)
            .padding(.vertical, WarpSpace.chipPadVertical)
            .frame(minWidth: isIconOnly ? iconSize + WarpSpace.m : nil)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(fill),
            )
            .overlay(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                    .strokeBorder(theme.surface3, lineWidth: WarpBorder.width),
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? label ?? "")
        #if os(macOS)
            .pointerStyle(.link)
        #endif
    }
}

/// Pure styling/state predicates for ``FooterPill`` — unit-tested without a view (L4 test rules).
enum FooterPillState {
    /// The effective fill role: `.surface2` when toggled-on OR hovered, else `.surface1` (spec §4A).
    enum Fill: Equatable { case surface1, surface2 }

    static func fill(isActive: Bool, isHovering: Bool, staticMirror: Bool = false) -> Fill {
        if isActive { return .surface2 }
        if isHovering, !staticMirror { return .surface2 }
        return .surface1
    }

    /// Icon-only (square, no horizontal padding) when there is an icon and no visible label (spec §2).
    static func isIconOnly(label: String?, hasIcon: Bool) -> Bool {
        (label?.isEmpty ?? true) && hasIcon
    }
}
