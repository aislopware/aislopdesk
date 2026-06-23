// RailControlBar — the pinned top control bar of the vertical-tab rail (warp-vertical-tabs.md §3).
// 24pt tall, container padding L/R 8 + T/B 4, inter-item spacing 4: a bare "Search tabs…" text field
// (leading 12pt search glyph, no chrome) that grows to fill, then a view-options/filter IconButton,
// then the "+" new-tab IconButton.

import AislopdeskDesignSystem
import SwiftUI

struct RailControlBar: View {
    @Environment(\.theme) private var theme

    @Binding var searchText: String
    var onNewTab: () -> Void

    var body: some View {
        HStack(spacing: WarpSpace.s) {
            HStack(spacing: WarpSpace.xs + WarpSpace.xs) { // 6pt gap (keyCapGap*2)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: WarpType.uiSize * 0.85))
                    .foregroundStyle(theme.textSub)
                    .frame(width: 12, height: 12)
                TextField("Search tabs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(WarpType.ui(WarpType.uiSize))
                    .foregroundStyle(theme.textMain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // View options / filter — a real Menu (was a no-op). "Clear filter" resets the search; the
            // pane-vs-tab granularity toggle lands once WorkspaceCore grows a tabs mode (RailRowsBuilder).
            Menu {
                Button("Clear filter") { searchText = "" }
                    .disabled(searchText.isEmpty)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: WarpSize.iconGlyph * 0.78, weight: .regular))
                    .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                    .padding(WarpSize.iconButtonPadding)
                    .foregroundStyle(theme.textSub)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View options")
            .accessibilityLabel("View options")
            .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
            IconButton(systemName: "plus", help: "New tab", action: onNewTab)
                .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
        }
        .padding(.horizontal, WarpSpace.m)
        .padding(.vertical, WarpSpace.s)
    }
}
