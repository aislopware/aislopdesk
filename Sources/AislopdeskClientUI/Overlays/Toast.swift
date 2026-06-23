// Toast — one transient notification card (warp-overlays-actions.md §3.2 `DismissibleToast`). A value
// type so the lifecycle (push / de-dupe by id / auto-dismiss) is pure + unit-testable without a view.
//
// Flavors map to the Warp set (Default / Success / Error) → an SF Symbol + a tint role; the view resolves
// the actual colors from the theme. `autoDismiss` is the timeout the toast view schedules (nil ⇒ sticky,
// dismissed only by the X button).

import Foundation

public struct Toast: Identifiable, Sendable, Equatable {
    /// Stable id — a newer toast with the same id replaces the older (warp `object_id` discipline).
    public let id: String
    public let flavor: Flavor
    public let title: String
    public let body: String?
    /// Auto-dismiss delay; nil ⇒ sticky (only the X closes it). Default 4s.
    public let autoDismiss: Duration?

    public enum Flavor: String, Sendable, Equatable {
        case `default`
        case success
        case error
        case attention

        /// The leading SF Symbol for this flavor.
        public var icon: String {
            switch self {
            case .default: "bell"
            case .success: "checkmark.circle"
            case .error: "exclamationmark.triangle"
            case .attention: "asterisk"
            }
        }
    }

    public init(
        id: String,
        flavor: Flavor = .default,
        title: String,
        body: String? = nil,
        autoDismiss: Duration? = .seconds(4),
    ) {
        self.id = id
        self.flavor = flavor
        self.title = title
        self.body = body
        self.autoDismiss = autoDismiss
    }
}
