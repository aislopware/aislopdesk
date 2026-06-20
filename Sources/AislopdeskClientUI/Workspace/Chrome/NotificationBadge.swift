// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

struct NotificationBadge: View {
    let count: Int

    var body: some View {
        Circle()
            .fill(AislopdeskTheme.accent)
            .frame(width: UIMetrics.scaled(8), height: UIMetrics.scaled(8))
            .accessibilityLabel("\(count) unread notification\(count == 1 ? "" : "s")")
    }
}
#endif
