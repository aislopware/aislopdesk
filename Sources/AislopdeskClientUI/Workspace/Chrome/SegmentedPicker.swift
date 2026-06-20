// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(
                            size: UIMetrics.fontFootnote,
                            weight: selection == option.value ? .semibold : .regular,
                        ))
                        .foregroundStyle(selection == option.value ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIMetrics.scaled(5))
                        .background(
                            selection == option.value
                                ? AislopdeskTheme.surface
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: UIMetrics.radiusSM),
                        )
                }
                .buttonStyle(.plain)

                if index < options.count - 1, selection != option.value,
                   selection != options[index + 1].value
                {
                    Divider()
                        .frame(height: UIMetrics.scaled(14))
                        .opacity(0.4)
                }
            }
        }
        .padding(UIMetrics.spacing1)
        .background(AislopdeskTheme.hover, in: RoundedRectangle(cornerRadius: UIMetrics.radiusMD))
        .accessibilityRepresentation {
            Picker(selection: $selection, label: EmptyView()) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }
}
#endif
