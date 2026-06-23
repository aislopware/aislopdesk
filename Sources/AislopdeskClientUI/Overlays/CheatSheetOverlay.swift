// CheatSheetOverlay — the keyboard cheat sheet (⌘/), restoring the previously-dead `view.cheatSheet`
// chord. A centered modal card over the modal backdrop, listing every workspace chord grouped by
// category. Its rows are generated DIRECTLY from `WorkspaceBindingRegistry.groupedForDisplay` — the SAME
// single source of truth the keyboard bank registers and the palette derives its hints from — so the
// displayed glyph can never drift from the real binding. Esc / scrim-tap / Done closes.
//
// Pure value rendering (no store coupling, no Ghostty/VT/Metal) — hang-safe.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct CheatSheetOverlay: View {
    @Environment(\.theme) private var theme

    var staticMirror: Bool = false
    let onClose: () -> Void

    private static let width: CGFloat = 560
    private static let maxHeight: CGFloat = 620

    var body: some View {
        ZStack {
            Color(WarpShadow.modalBackdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS) || os(iOS)
            .modifier(CheatSheetEscHandler(enabled: !staticMirror, onClose: onClose))
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WarpSpace.l) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: WarpType.uiSize, weight: .semibold))
                        .foregroundStyle(theme.textSub)
                        .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: WarpSpace.xl) {
                    ForEach(WorkspaceBindingRegistry.groupedForDisplay, id: \.category) { group in
                        section(group.category, bindings: group.bindings)
                    }
                }
            }
            .frame(maxHeight: Self.maxHeight)

            HStack {
                Spacer()
                ModalButton(label: "Done", kind: .primary, action: onClose)
            }
        }
        .padding(WarpSpace.dialogHorizontal)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous).fill(theme.surface2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
        .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
        .onTapGesture {}
    }

    private func section(_ category: WorkspaceAction.Category, bindings: [WorkspaceBinding]) -> some View {
        VStack(alignment: .leading, spacing: WarpSpace.s) {
            Text(category.rawValue)
                .font(WarpType.ui(WarpType.overlineSize, weight: .semibold))
                .foregroundStyle(theme.textSub)
            ForEach(bindings, id: \.id) { binding in
                row(binding)
            }
        }
    }

    private func row(_ binding: WorkspaceBinding) -> some View {
        HStack(spacing: WarpSpace.m) {
            Image(systemName: binding.symbol)
                .font(.system(size: WarpType.uiSize))
                .foregroundStyle(theme.textSub)
                .frame(width: WarpSize.iconGlyph)
            Text(binding.title)
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textMain)
            Spacer(minLength: WarpSpace.m)
            if let chord = binding.chord {
                ShortcutHintChip(text: WorkspaceBindingRegistry.glyph(chord))
            }
        }
    }
}

#if os(macOS) || os(iOS)
private struct CheatSheetEscHandler: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onKeyPress(.escape) { onClose()
                return .handled
            }
        } else {
            content
        }
    }
}
#endif
