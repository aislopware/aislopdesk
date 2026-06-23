// SuggestionPill — the green, dismissible "↓ Enable Claude Code notifications ✕" chip
// (warp-bottom-bar.md §4B, `InstallPluginButtonTheme`). It is TWO adjoined buttons sharing a seam:
//   1. the main half (leading ↓ download icon + "Enable {agent} notifications") → `installNotifications`
//   2. the trailing ✕ dismiss half                                              → `dismissNotifications`
//
// Styling (spec §4B): green fill = `surface_1` blended with green@15% (hover @30%); green text/icon =
// `ui_green`; green border @ ~a80. The two halves share an edge — the main half keeps only its LEFT
// corners rounded, the dismiss half only its RIGHT corners, and the inner border is dropped so it reads
// as a single divider. The label is dynamic: "Enable {agent.display_name} notifications".
//
// Dismissal persistence is the COORDINATOR's job (PreferencesStore, W4); this view only emits the two
// intents. Whether it appears at all is decided upstream by `PreferencesStore.shouldShowNotificationChip`.

import AislopdeskDesignSystem
import SwiftUI

struct SuggestionPill: View {
    @Environment(\.theme) private var theme

    /// The agent display name folded into the label (e.g. "Claude Code").
    var agentName: String = "Claude Code"
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false
    /// Main-half click → enable notifications (W4).
    let onEnable: () -> Void
    /// Trailing ✕ click → dismiss the chip (W4).
    let onDismiss: () -> Void

    @State private var mainHover = false
    @State private var dismissHover = false

    private var label: String { SuggestionPillCopy.label(agentName: agentName) }

    private var fontSize: CGFloat { WarpType.monospaceSize - 1 }
    private var iconSize: CGFloat { WarpType.monospaceSize }

    /// Green fill = surface_1 ⊕ green@{15,30}% (spec §4B). Resolved through the blend helpers so the bytes
    /// match the derivation, not a gray approximation.
    private func greenFill(hovered: Bool) -> Color {
        Color(GreenChip.fill(surface1: theme.resolved.surface1, hovered: hovered))
    }

    private var greenInk: Color { theme.uiGreen }
    private var greenBorder: Color { Color(GreenChip.borderGreen) }

    var body: some View {
        HStack(spacing: 0) {
            mainHalf
            dismissHalf
        }
    }

    private var mainHalf: some View {
        Button(action: onEnable) {
            HStack(spacing: WarpSpace.s) {
                Image(systemName: "arrow.down")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(greenInk)
                Text(label)
                    .font(WarpType.ui(fontSize))
                    .foregroundStyle(greenInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, WarpSpace.pillPad)
            .padding(.vertical, WarpSpace.chipPadVertical)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: WarpRadius.control,
                    bottomLeadingRadius: WarpRadius.control,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous,
                )
                .fill(greenFill(hovered: mainHover && !staticMirror)),
            )
            .overlay(
                // Border on the three OUTER edges only (drop the shared/inner right edge — single seam).
                UnevenRoundedRectangle(
                    topLeadingRadius: WarpRadius.control,
                    bottomLeadingRadius: WarpRadius.control,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous,
                )
                .strokeBorder(greenBorder, lineWidth: WarpBorder.width),
            )
        }
        .buttonStyle(.plain)
        .onHover { mainHover = $0 }
        .help("Enable \(agentName) notifications")
        #if os(macOS)
            .pointerStyle(.link)
        #endif
    }

    private var dismissHalf: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(greenInk)
                .padding(.horizontal, WarpSpace.pillPad)
                .padding(.vertical, WarpSpace.chipPadVertical)
                .frame(maxHeight: .infinity)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: WarpRadius.control,
                        topTrailingRadius: WarpRadius.control,
                        style: .continuous,
                    )
                    .fill(greenFill(hovered: dismissHover && !staticMirror)),
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: WarpRadius.control,
                        topTrailingRadius: WarpRadius.control,
                        style: .continuous,
                    )
                    .strokeBorder(greenBorder, lineWidth: WarpBorder.width),
                )
        }
        .buttonStyle(.plain)
        .onHover { dismissHover = $0 }
        .help("Dismiss")
        #if os(macOS)
            .pointerStyle(.link)
        #endif
    }
}

/// The dynamic label copy (spec §4B: "Enable {agent} notifications"). Pure → unit-tested.
enum SuggestionPillCopy {
    static func label(agentName: String) -> String {
        let name = agentName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Enable notifications" : "Enable \(name) notifications"
    }
}

/// The green chip palette constants (spec §8). The fill uses `ui_green` blended into surface_1; the
/// border is the same green at ~a80.
enum GreenChip {
    /// Warp's `ui_green` (#1CA05A) — the chip ink + the blend overlay (UIStatus.green in the DS).
    static let green = UIStatus.green
    /// The border green at alpha 80 (spec §4B: `ColorU{green.rgb, a:80}`).
    static let borderGreen = ColorU(r: green.r, g: green.g, b: green.b, a: 80)

    /// The fill = surface_1 ⊕ green@{15,30}% (rest/hover). Pure → unit-tested for the blend bytes.
    static func fill(surface1: ColorU, hovered: Bool) -> ColorU {
        surface1.blend(green.withOpacity(hovered ? 30 : 15))
    }
}
