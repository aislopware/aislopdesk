// TerminalBlocksView — the OVERLAY decoration layer for terminal blocks (warp-panes-blocks.md §3).
//
// IMPORTANT (repo guardrail): block chrome is an OVERLAY over the terminal content, NOT a content branch.
// The rounded box in the Warp screenshot is the CLI's own box-drawing output (terminal content), not block
// chrome — Warp's own block chrome is the selection highlight + the hover toolbelt only. The actual block
// GRID is rendered by libghostty (the seam); this view only draws:
//   - the selection highlight (accent@25%) + accent border on the selected block, and
//   - a hover toolbelt (overflow ⋮ / collapse / AI / bookmark) over the hovered block,
//   - a faint fg@15% separator above each block (offset 20pt from the left).
//
// Because the headless build renders no real grid, this overlay binds to the model's `blocks` only for
// EAGER/STATIC composition (snapshot-safe). The pure selection→band mapping lives in
// `BlockSelectionMapping` so it can be unit-tested without a view.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

/// Pure mapping helpers for the block overlay (testable without a view).
enum BlockSelectionMapping {
    /// The selection band fill for a block: accent@25% when selected, else clear.
    /// Returned as an opacity so the test can assert the rule without a `Color`.
    static func selectionOpacity(isSelected: Bool) -> Double { isSelected ? 1.0 : 0.0 }

    /// The toolbelt is shown only for the hovered block.
    static func showsToolbelt(hoveredIndex: UInt32?, blockIndex: UInt32) -> Bool {
        hoveredIndex == blockIndex
    }

    /// Whether a faint separator is drawn above a block (every block except the first).
    static func showsSeparatorAbove(blockIndex: UInt32, firstIndex: UInt32?) -> Bool {
        guard let firstIndex else { return false }
        return blockIndex != firstIndex
    }
}

/// A minimal block-decoration overlay. Rendered EAGERLY (a plain VStack, no lazy ScrollView) so a
/// headless ImageRenderer can materialize it for snapshots. In the live app it sits over the libghostty
/// grid as a thin decoration; the grid scroll position is owned by the renderer.
struct TerminalBlocksView: View {
    @Environment(\.theme) private var theme

    let model: TerminalBlockModel
    /// The selected block index (if any) — drives the accent@25% highlight band.
    var selectedIndex: UInt32?
    /// EAGER/STATIC render path for snapshots.
    var staticMirror: Bool = false

    @State private var hoveredIndex: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.blocks) { block in
                blockRow(block)
            }
        }
        .allowsHitTesting(!staticMirror)
    }

    @ViewBuilder
    private func blockRow(_ block: CommandBlock) -> some View {
        let isSelected = selectedIndex == block.index
        let showsSep = BlockSelectionMapping.showsSeparatorAbove(
            blockIndex: block.index, firstIndex: model.blocks.first?.index,
        )
        VStack(alignment: .leading, spacing: 0) {
            if showsSep {
                Rectangle()
                    .fill(theme.splitPaneBorder)
                    .frame(height: WarpBorder.width)
                    .padding(.leading, 20) // SEPARATOR_LEFT_OFFSET
            }
            HStack(spacing: WarpSpace.m) {
                Text(block.statusSymbol)
                    .font(WarpType.mono(WarpType.monospaceSize))
                    .foregroundStyle(block.isFailed ? theme.uiError : theme.textSub)
                Text(block.commandText)
                    .font(WarpType.mono(WarpType.monospaceSize))
                    .foregroundStyle(theme.textMain)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if BlockSelectionMapping.showsToolbelt(
                    hoveredIndex: staticMirror ? nil : hoveredIndex,
                    blockIndex: block.index,
                ) {
                    toolbelt(block)
                }
            }
            .padding(.vertical, WarpSpace.xxs)
            .padding(.horizontal, WarpSpace.m)
        }
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .fill(isSelected ? theme.accentOverlay2 : Color.clear),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: isSelected ? 2 : 0),
        )
        .onHover { hoveredIndex = $0 ? block.index : nil }
    }

    /// The hover toolbelt cluster (overflow / collapse / AI / bookmark) — 28pt tall (spec §3.4).
    private func toolbelt(_ block: CommandBlock) -> some View {
        HStack(spacing: WarpSpace.xxs) {
            toolButton("ellipsis")
            toolButton("chevron.up")
            toolButton("sparkles")
            toolButton(model.isBookmarked(block.index) ? "bookmark.fill" : "bookmark")
        }
        .frame(height: 28)
        .padding(.horizontal, WarpSpace.s)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.surface2),
        )
    }

    private func toolButton(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: WarpType.monospaceSize, weight: .regular))
            .foregroundStyle(theme.textSub)
            .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
    }
}
