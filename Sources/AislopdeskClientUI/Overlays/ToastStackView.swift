// ToastStackView — the transient notification stack (warp-overlays-actions.md §3.2). A non-blocking,
// no-scrim column of `ToastCard`s pinned bottom-trailing. Each card is 464pt wide, 4pt radius, 1pt
// flavor-tinted border over a `neutral_4` (default) / success / error fill, with a leading flavor icon and
// a trailing X close. Cards auto-dismiss after their `autoDismiss` delay (the Motion token governs the
// fade) and on X tap; the lifecycle (push / de-dupe / cap) lives in `OverlayCoordinator`.

import AislopdeskDesignSystem
import SwiftUI

struct ToastStackView: View {
    let coordinator: OverlayCoordinator

    var body: some View {
        VStack(alignment: .trailing, spacing: WarpSpace.m) {
            ForEach(coordinator.toasts) { toast in
                ToastCard(
                    toast: toast,
                    onDismiss: { coordinator.dismissToast(toast.id) },
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(WarpSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!coordinator.toasts.isEmpty)
        .animation(.easeInOut(duration: 0.12), value: coordinator.toasts.map(\.id))
    }
}

struct ToastCard: View {
    @Environment(\.theme) private var theme

    let toast: Toast
    var staticMirror: Bool = false
    let onDismiss: () -> Void

    @State private var hovering = false

    private static let width: CGFloat = 464

    var body: some View {
        HStack(alignment: .top, spacing: WarpSpace.m) {
            Image(systemName: toast.flavor.icon)
                .font(.system(size: WarpSize.iconGlyph))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: WarpSpace.xxs) {
                Text(toast.title)
                    .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                    .lineLimit(2)
                if let body = toast.body, !body.isEmpty {
                    Text(body)
                        .font(WarpType.ui(WarpType.uiSize))
                        .foregroundStyle(theme.textSub)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: WarpSpace.m)
            if hovering || staticMirror {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: WarpType.overlineSize, weight: .semibold))
                        .foregroundStyle(theme.textSub)
                        .frame(width: WarpSize.iconGlyph, height: WarpSize.iconGlyph)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
                .help("Dismiss")
            }
        }
        .padding(.horizontal, WarpSpace.xl)
        .padding(.vertical, WarpSpace.m)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.neutral4),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .strokeBorder(tint.opacity(0.5), lineWidth: WarpBorder.width),
        )
        .onHover { hovering = $0 }
        // Keyed on the WHOLE `toast` value (not just its id) so a same-id REPLACEMENT — which keeps this
        // SwiftUI view identity because the `ForEach` is id-keyed — re-evaluates the timer whenever
        // `autoDismiss` (or content) changes. A needsInput→finished replacement now restarts and schedules
        // the dismiss; a finished→needsInput one cancels the stale timer and the `guard` keeps the sticky
        // toast. `Toast: Equatable`, so this is well-defined; a harmless restart on a title-only change is OK.
        .task(id: toast) {
            guard !staticMirror, let delay = toast.autoDismiss else { return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { onDismiss() }
        }
    }

    private var tint: Color {
        switch toast.flavor {
        case .default: theme.textSub
        case .success: theme.success
        case .error: theme.uiError
        case .attention: theme.claudeOrange
        }
    }
}
