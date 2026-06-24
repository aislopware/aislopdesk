// OttyTabRow — otty's sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// ported from /Volumes/Lacie/Workspace/oss/otty-reversed (`OttyReplica.swift`) onto the `Otty` tokens and
// wired to the live store via the navigator. The resting row is the tab name on the warm sidebar; ACTIVE is
// otty's signature WHITE CARD (radius-7 fill + 1px cardBorder + faint shadow), hover is a flat plate, and a
// close `×` reveals on hover. No native list selection / vibrancy — this is the flat otty silhouette.

#if canImport(SwiftUI)
import SwiftUI

/// One sidebar tab row. ACTIVE = white card (otty's active-tab treatment); hover = flat plate + close `×`.
struct OttyTabRow: View {
    let title: String
    let active: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: active ? .medium : .regular))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(rowBackground, in: .rect(cornerRadius: 7))
        .overlay { if active { RoundedRectangle(cornerRadius: 7).strokeBorder(Otty.Line.card, lineWidth: 1) } }
        .shadow(color: active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
        .animation(Otty.Anim.smallFade, value: active)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Otty.Text.icon)
                .frame(width: 18, height: 18)
                .background(closeHover ? Otty.State.selected : .clear, in: .rect(cornerRadius: 4))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
    }

    private var rowBackground: Color {
        if active { Otty.Surface.selectedCard }
        else if hovering { Otty.State.hover }
        else { .clear }
    }
}

/// otty's sidebar hamburger — a sort/group popover (`SortMenuButton`). Grouping/order are presentational for
/// now (otty's own affordance); the row is the flat-icon button beside the "TABS" header.
struct OttySortMenuButton: View {
    @State private var show = false
    @State private var group = 0 // 0 No Grouping · 1 By Project · 2 By Date
    @State private var order = 0 // 0 Created · 1 Updated

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Otty.Text.icon)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SortSection("GROUP")
            SortRow("No Grouping", icon: "list.bullet", on: group == 0) { group = 0 }
            SortRow("By Project", icon: "folder", on: group == 1) { group = 1 }
            SortRow("By Date", icon: "calendar", on: group == 2) { group = 2 }
            SortDivider()
            SortSection("ORDER")
            SortRow("Created Time", icon: "clock", on: order == 0) { order = 0 }
            SortRow("Updated Time", icon: "clock.arrow.circlepath", on: order == 1) { order = 1 }
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }
}

private struct SortSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Otty.State.header)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SortDivider: View {
    var body: some View {
        Rectangle().fill(Otty.Line.divider).frame(height: 1)
            .padding(.vertical, 5).padding(.horizontal, 10)
    }
}

private struct SortRow: View {
    let title: String
    let icon: String
    let on: Bool
    var action: () -> Void

    init(_ title: String, icon: String, on: Bool, _ action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.on = on
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Otty.Text.secondary).frame(width: 16)
                Text(title).font(.system(size: 12)).foregroundStyle(Otty.Text.primary)
                Spacer()
                if on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Otty.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(hovering ? Otty.State.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
