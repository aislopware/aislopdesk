// PaneHeader — the 34pt pane title bar (warp-panes-blocks.md §2). A three-column row with the title
// optically centered (matched edge widths), a hover-revealed ⋮ overflow + × close on the right (× only
// when the pane is in a split), and a transparent background over the terminal bg. Active vs inactive is
// conveyed by the hover-reveal + the corner triangle (drawn by PaneContainer), NOT a header color swap.
//
// The control-visibility rules live in `PaneHeaderControls` (pure) so they are unit-testable without a
// view (header hover-reveal + close-only-in-split rules).

import AislopdeskDesignSystem
import SwiftUI

/// Pure visibility rules for the header's right-side controls (testable, spec §2.3).
enum PaneHeaderControls {
    /// The close `×` is shown only when the pane is IN A SPLIT and the controls are revealed (hover/active).
    static func showsClose(isInSplit: Bool, controlsRevealed: Bool) -> Bool {
        isInSplit && controlsRevealed
    }

    /// The overflow `⋮` is shown whenever the controls are revealed (it always has menu items).
    static func showsOverflow(controlsRevealed: Bool) -> Bool { controlsRevealed }

    /// Controls are revealed when the header is hovered OR the pane is the active pane.
    static func controlsRevealed(isHovered: Bool, isActive: Bool) -> Bool { isHovered || isActive }
}

struct PaneHeader<OverflowMenu: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    /// Whether this pane is the active (focused) pane — keeps the controls visible at rest.
    let isActive: Bool
    /// Whether the pane lives in a split (gates the × close button).
    let isInSplit: Bool

    let onClose: () -> Void
    let onOverflow: () -> Void
    /// Whether the ⋮ overflow context menu is presented (bound by the parent — L5).
    let overflowMenuShown: Binding<Bool>
    /// The themed context-menu content shown in a popover anchored on the ⋮ button.
    @ViewBuilder let overflowMenu: () -> OverflowMenu

    @State private var hovering = false

    init(
        title: String,
        isActive: Bool,
        isInSplit: Bool,
        onClose: @escaping () -> Void = {},
        onOverflow: @escaping () -> Void = {},
        overflowMenuShown: Binding<Bool> = .constant(false),
        @ViewBuilder overflowMenu: @escaping () -> OverflowMenu,
    ) {
        self.title = title
        self.isActive = isActive
        self.isInSplit = isInSplit
        self.onClose = onClose
        self.onOverflow = onOverflow
        self.overflowMenuShown = overflowMenuShown
        self.overflowMenu = overflowMenu
    }

    /// Matched edge-column width so the title stays optically centered (spec §2.1; 2 icons ⋮+× = 52pt,
    /// clamped to the terminal-pane max of 200 / a sensible min).
    private let edgeWidth: CGFloat = 56

    private var revealed: Bool {
        PaneHeaderControls.controlsRevealed(isHovered: hovering, isActive: isActive)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left edge column (matched width, keeps the title centered).
            Color.clear.frame(width: edgeWidth)
            // Center title.
            Text(title.isEmpty ? "Terminal" : title)
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textSub)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity)
            // Right controls column (matched width).
            HStack(spacing: WarpSpace.xxs) {
                Spacer(minLength: 0)
                if PaneHeaderControls.showsOverflow(controlsRevealed: revealed) {
                    IconButton(systemName: "ellipsis", help: "Pane menu", action: onOverflow)
                        .popover(isPresented: overflowMenuShown, arrowEdge: .top) {
                            overflowMenu()
                                .environment(\.theme, theme)
                        }
                }
                if PaneHeaderControls.showsClose(isInSplit: isInSplit, controlsRevealed: revealed) {
                    IconButton(systemName: "xmark", help: "Close pane", action: onClose)
                }
            }
            .frame(width: edgeWidth)
        }
        .padding(.horizontal, WarpSpace.s)
        .frame(height: WarpSize.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension PaneHeader where OverflowMenu == EmptyView {
    /// Convenience init with no overflow menu (snapshots / previews).
    init(
        title: String,
        isActive: Bool,
        isInSplit: Bool,
        onClose: @escaping () -> Void = {},
        onOverflow: @escaping () -> Void = {},
    ) {
        self.init(
            title: title, isActive: isActive, isInSplit: isInSplit,
            onClose: onClose, onOverflow: onOverflow,
            overflowMenuShown: .constant(false), overflowMenu: { EmptyView() },
        )
    }
}
