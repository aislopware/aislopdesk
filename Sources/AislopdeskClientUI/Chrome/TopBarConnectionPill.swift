// TopBarConnectionPill — the PURE derivation of the WindowTopBar connection status pill from a
// `ConnectionStatus`. Factored out of the view so the label / colour-role / "show a Retry?" policy is
// unit-testable with no SwiftUI view and no live `AppConnection` (the view maps `colorRole` → a theme
// token, the only view-side step). Surfaces a down / reconnecting / unreachable host in the chrome —
// previously `AppConnection.status` was never read by any chrome view.

import AislopdeskWorkspaceCore
import Foundation

enum TopBarConnectionPill {
    /// The theme colour role for the status dot — mapped to a concrete token by the view (so this stays
    /// pure / token-free / testable).
    enum ColorRole: Equatable {
        case connected // success / green
        case inFlight // connecting / reconnecting — warning / yellow
        case trouble // failed / unreachable — error / red
        case idle // disconnected — muted
    }

    /// The compact pill label (empty ⇒ the view renders no pill). Mirrors
    /// ``ConnectionPresenter/shortLabel(for:)`` so the pill copy can't drift from the rest of the app.
    static func label(for status: ConnectionStatus) -> String {
        ConnectionPresenter.shortLabel(for: status)
    }

    /// The dot colour role for `status`.
    static func colorRole(for status: ConnectionStatus) -> ColorRole {
        switch status {
        case .connected: .connected
        case .connecting,
             .reconnecting: .inFlight
        case .failed,
             .unreachable: .trouble
        case .disconnected: .idle
        }
    }

    /// Whether a manual Retry affordance should be shown (only the give-up states: a terminal `.failed`
    /// initial connect or a post-connect `.unreachable`). Connected / connecting / reconnecting keep the
    /// affordance hidden (the supervisor is already retrying or there is nothing to retry).
    static func showsReconnect(for status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The hover tooltip: the host plus the actionable headline (``ConnectionPresenter/headline(for:)``).
    static func help(host: String, status: ConnectionStatus) -> String {
        "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
    }
}
