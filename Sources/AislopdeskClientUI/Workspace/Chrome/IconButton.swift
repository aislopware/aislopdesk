// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var color: Color = AislopdeskTheme.fgMuted
    var hoverColor: Color = AislopdeskTheme.fg
    var showsBadge = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        IconButtonChrome(
            color: color,
            hoverColor: hoverColor,
            accessibilityLabel: accessibilityLabel,
            action: action,
        ) {
            Image(systemName: symbol)
                .font(.system(size: UIMetrics.scaled(size), weight: .semibold))
                .overlay(alignment: .topTrailing) {
                    if showsBadge {
                        IconButtonBadge()
                    }
                }
        }
    }
}

private struct IconButtonBadge: View {
    var body: some View {
        Circle()
            .fill(AislopdeskTheme.accent)
            .frame(width: UIMetrics.scaled(6), height: UIMetrics.scaled(6))
            .overlay(
                Circle().stroke(AislopdeskTheme.bg, lineWidth: UIMetrics.scaled(1.5)),
            )
            .offset(x: UIMetrics.scaled(4), y: UIMetrics.scaled(-4))
    }
}

struct IconButtonChrome<Label: View>: View {
    var color: Color = AislopdeskTheme.fgMuted
    var hoverColor: Color = AislopdeskTheme.fg
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(hovered ? hoverColor : color)
                .frame(width: UIMetrics.controlMedium, height: UIMetrics.controlMedium)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif
