// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the `Slate` tokens and wired to the live store via the navigator. The resting row is the tab
// name on the warm sidebar; ACTIVE is a WHITE CARD (radius-7 fill + 1px cardBorder + faint shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// One sidebar tab row. ACTIVE = white card treatment; hover = flat plate + close `×`.
///
/// E6 WI-4 grew the row from a name-only plate to its full chrome: an optional second-line cwd subtitle
/// and a trailing cluster of the fused status `badge`, the monospaced light-gray `⌘N` SWITCH-SHORTCUT badge,
/// and — on the ACTIVE row — the foreground-process label ("zsh"). Name-only rows stay ~34pt; a subtitle grows
/// the row to ~44pt (`docs/ui-shell/screenshots/tab-badge.png`). The trailing cluster fades under hover `×`.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The 1-based tab shortcut number — the live ⌘1…⌘9 select-tab target = tab index + 1. Rendered as the
    /// trailing `⌘N` badge for the first nine tabs (see ``shortcutBadge(for:)``); `0` / overflow ⇒ no badge.
    var number: Int = 0
    /// The pane's last-known cwd, shown as a muted truncating-middle second line. `nil`/empty ⇒ single-line.
    var subtitle: String?
    /// The host's coarse foreground-process label ("zsh"), shown trailing on the ACTIVE row only.
    var processLabel: String?
    /// The single fused status badge (spinner / check / dot / error / hand / coffee / shield). `nil` ⇒ none.
    var badge: TabBadgeKind?
    /// E17 ES-E17-1 / WI-3: whether this pane's input gate is READ-ONLY — renders a small trailing lock glyph
    /// (the sidebar's read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill). Default `false` keeps
    /// existing call sites source-compatible.
    var readOnly: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false
    @State private var closeHover = false

    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    /// The trailing SWITCH-SHORTCUT badge text for a tab's 1-based `number`: `⌘N` for the first nine tabs (the
    /// live ⌘1…⌘9 select-tab chords), `nil` for overflow (10+) which has NO ⌘-shortcut — so the row shows no
    /// misleading number there. Renders this exact `⌘N` badge as the persistent trailing chip in the
    /// sidebar (ground truth: `find.png`, `workspace-tabs.png` — `myproj ⌘1` / `OC | Reviewing todos ⌘2` / …).
    /// The badge is shown PERSISTENTLY rather than gated behind a ⌘-hold reveal (the hold-to-hint keycaps
    /// were tried and rejected — see DECISIONS Batch-5). Pure + static so the badge string is unit-pinnable
    /// without rendering a SwiftUI view.
    static func shortcutBadge(for number: Int) -> String? {
        (1...9).contains(number) ? "⌘\(number)" : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                if hasSubtitle {
                    Text(subtitle ?? "")
                        .font(.system(size: Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            trailingMeta
                .opacity(hovering ? 0 : 1)
        }
        .overlay(alignment: .trailing) {
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 14)
        .frame(height: hasSubtitle ? 44 : 34)
        .background(rowBackground, in: .rect(cornerRadius: Slate.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Slate.Metric.radiusTab).strokeBorder(
            Slate.Line.card,
            lineWidth: 1,
        ) } }
        .shadow(color: active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: active)
    }

    /// The trailing status cluster: the read-only lock (if locked), the fused `badge` (if any), then the
    /// monospaced light-gray `⌘N` switch-shortcut badge, then the foreground-process label on the ACTIVE row —
    /// all muted, right-aligned (`find.png` / `workspace-tabs.png` / `tab-badge.png`). Fades under the hover `×`.
    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if let badge {
                TabBadgeView(kind: badge)
            }
            if let shortcut = Self.shortcutBadge(for: number) {
                Text(shortcut)
                    .font(.system(size: Slate.Typeface.small, design: .monospaced))
                    .foregroundStyle(Slate.Text.secondary)
            }
            if active, let processLabel, !processLabel.isEmpty {
                Text(processLabel)
                    .font(.system(size: Slate.Typeface.small, design: .monospaced))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: 18, height: 18)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
    }

    private var rowBackground: Color {
        if active { Slate.Surface.selectedCard }
        else if hovering { Slate.State.hover }
        else { .clear }
    }
}

/// The sidebar hamburger — a sort/group popover (`SortMenuButton`). E6 WI-5 made it write the STORE (the
/// single source of truth for row order, persisted) instead of local `@State`: each GROUP row sets
/// ``WorkspaceStore/setTabGrouping(_:)`` and each ORDER row ``WorkspaceStore/setTabSort(_:)``; the checkmarks
/// READ the store. (Carryover binding constraint: "mutate the store order, not local `@State`.") The row is
/// the flat-icon button beside the "TABS" header.
struct SlateSortMenuButton: View {
    /// The live store — owns ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` (the persisted row
    /// order). Read in the popover (so the `@Observable` store ticks the checkmarks) and written by the rows.
    let store: WorkspaceStore

    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemSymbol: .line3Horizontal)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SortSection("GROUP")
            groupRow("No Grouping", "list.bullet", .none)
            groupRow("By Project", "folder", .byProject)
            groupRow("By Date", "calendar", .byDate)
            SortDivider()
            SortSection("ORDER")
            orderRow("Created Time", "clock", .created)
            orderRow("Updated Time", "clock.arrow.circlepath", .updated)
            orderRow("Manual", "arrow.up.arrow.down", .manual)
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }

    /// A GROUP row whose checkmark READS ``WorkspaceStore/tabGrouping`` and whose tap WRITES it (persisted).
    private func groupRow(_ title: String, _ icon: String, _ value: TabGrouping) -> some View {
        SortRow(title, icon: icon, on: store.tabGrouping == value) { store.setTabGrouping(value) }
    }

    /// An ORDER row whose checkmark READS ``WorkspaceStore/tabSort`` and whose tap WRITES it (persisted).
    private func orderRow(_ title: String, _ icon: String, _ value: TabSort) -> some View {
        SortRow(title, icon: icon, on: store.tabSort == value) { store.setTabSort(value) }
    }
}

private struct SortSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: Slate.Typeface.small, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Slate.State.header)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SortDivider: View {
    var body: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: 1)
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
                Image(systemName: icon).font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: Slate.Typeface.base)).foregroundStyle(Slate.Text.primary)
                Spacer()
                if on {
                    Image(systemSymbol: .checkmark).font(.system(size: Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(hovering ? Slate.State.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
