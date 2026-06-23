// ConfirmModal — the centered confirmation modal (warp-overlays-actions.md §3.1 `Modal`). Unlike the
// palette, the modal paints a REAL 70%-black backdrop scrim, a 440pt `surface_2` card at 8pt radius with a
// 1pt `outline` border, centered in the window. Esc → cancel; the scrim tap → cancel.
//
// Wired by `WorkspaceRootView` to the store's busy-shell close guard: when `store.pendingCloseSpec != nil`
// (a pane with a running command awaits confirmation), this presents "Close pane with a running process?";
// Confirm → `store.confirmPendingClose()`, Cancel → `store.cancelPendingClose()`.

import AislopdeskDesignSystem
import SwiftUI

struct ConfirmModal: View {
    @Environment(\.theme) private var theme

    let title: String
    let message: String
    var confirmLabel: String = "Close"
    var cancelLabel: String = "Cancel"
    var destructive: Bool = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private static let width: CGFloat = 440

    var body: some View {
        ZStack {
            // Real 70%-black backdrop (§3.1). Tap → cancel.
            Color(WarpShadow.modalBackdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS) || os(iOS)
            .modifier(ModalEscHandler(onCancel: onCancel))
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WarpSpace.xl) {
            Text(title)
                .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                .foregroundStyle(theme.textMain)
            Text(message)
                .font(WarpType.ui(WarpType.paletteSize))
                .foregroundStyle(theme.textSub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WarpSpace.m) {
                Spacer(minLength: 0)
                ModalButton(label: cancelLabel, kind: .secondary, action: onCancel)
                ModalButton(label: confirmLabel, kind: destructive ? .destructive : .primary, action: onConfirm)
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
        // Stop the card's own tap from reaching the backdrop dismiss.
        .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
        .onTapGesture {}
    }
}

/// A modal action button (primary / secondary / destructive).
struct ModalButton: View {
    @Environment(\.theme) private var theme

    enum Kind { case primary, secondary, destructive }

    let label: String
    let kind: Kind
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, WarpSpace.basePadHorizontal)
                .padding(.vertical, WarpSpace.basePadVertical)
                .frame(height: WarpSize.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(background),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                        .strokeBorder(border, lineWidth: WarpBorder.width),
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.background
        case .destructive: hovering ? theme.background : theme.uiError
        case .secondary: theme.textMain
        }
    }

    private var background: Color {
        switch kind {
        case .primary: hovering ? theme.accentOverlay4 : theme.accent
        case .destructive: hovering ? theme.uiError : .clear
        case .secondary: hovering ? theme.surface3 : theme.surface1
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .destructive: theme.uiError
        case .secondary: theme.outline
        }
    }
}

#if os(macOS) || os(iOS)
private struct ModalEscHandler: ViewModifier {
    let onCancel: () -> Void
    func body(content: Content) -> some View {
        content.onKeyPress(.escape) { onCancel()
            return .handled
        }
    }
}
#endif
