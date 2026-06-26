// StatusPresentation — pure view-side mapping of connection + agent state to native SwiftUI presentation
// (REBUILD-V2, L4a). Recovers the connection-pill derivation (label / colour-role / dot) from the deleted
// `Chrome/TopBarConnectionPill.swift`, but maps the colour role straight to a SYSTEM semantic `Color` (no
// design-system token). Shared by the unified-toolbar status pill and the inspector's Session section so
// the copy + dot colour can't drift. The label copy itself comes from `ConnectionPresenter` (the one
// source of truth) — this only adds the view-layer colour + dot.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import SwiftUI

// `@MainActor` because the colour mappers read the runtime ``Otty/theme`` (D3) — every call site is a
// SwiftUI view body, all MainActor.
@MainActor
enum StatusPresentation {
    // MARK: Connection

    /// The compact pill label (e.g. "connected", "reconnecting 3/20", "failed").
    static func connectionLabel(_ status: ConnectionStatus) -> String {
        ConnectionPresenter.shortLabel(for: status)
    }

    /// The status-dot colour — otty status palette (cohesive on the active theme).
    static func connectionColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: Otty.Status.ok
        case .connecting,
             .reconnecting: Otty.Status.warn
        case .failed,
             .unreachable: Otty.Status.err
        case .disconnected: Otty.Text.secondary
        }
    }

    /// Whether a manual Retry affordance applies (only the give-up states).
    static func showsRetry(_ status: ConnectionStatus) -> Bool {
        switch status {
        case .failed,
             .unreachable: true
        default: false
        }
    }

    /// The hover/accessibility help: host + the actionable headline.
    static func connectionHelp(host: String, status: ConnectionStatus) -> String {
        "Connection: \(host) — \(ConnectionPresenter.headline(for: status))"
    }

    // MARK: Agent (Claude Code)

    /// SF Symbol for an agent status. `nil` ⇒ render nothing (no active agent).
    static func agentSymbol(_ status: ClaudeStatus) -> String? {
        switch status {
        case .none: nil
        case .idle: "circle.fill"
        case .working: "gearshape.fill"
        case .done: "checkmark.circle.fill"
        case .needsPermission: "exclamationmark.triangle.fill"
        }
    }

    /// otty-palette tint for an agent status (matches docs/42 glyph palette: idle🟢 working🟡 done🔵 needs🔴).
    static func agentTint(_ status: ClaudeStatus) -> Color {
        switch status {
        case .none: Otty.Text.secondary
        case .idle: Otty.Status.ok
        case .working: Otty.Status.warn
        case .done: Otty.Status.info
        case .needsPermission: Otty.Status.err
        }
    }

    /// The short agent label (the one source — `ClaudeStatus.displayLabel`).
    static func agentLabel(_ status: ClaudeStatus) -> String {
        status.displayLabel
    }

    // MARK: Tab badge (E6 sidebar row, WI-4)

    /// How a sidebar tab's fused ``TabBadgeKind`` renders — the otty glyph map, kept next to ``agentSymbol``
    /// so the two status vocabularies can't drift (`terminal-features__progress-state.md` "The full badge
    /// set"). `.spinner` (running) and `.dot` (the settled accent dot) are bespoke shapes; every other kind
    /// is a tinted SF-symbol fill. The view layer (``TabBadgeView``) switches on this so the symbol + tint
    /// have a single source.
    static func tabBadge(_ kind: TabBadgeKind) -> TabBadgeStyle {
        switch kind {
        case .running: .spinner
        case .completed: .symbol(name: "checkmark.circle.fill", tint: Otty.Status.ok)
        case .finished: .dot(Otty.Status.ok)
        case .error: .symbol(name: "exclamationmark.triangle.fill", tint: Otty.Status.err)
        case .awaitingInput: .symbol(name: "hand.raised.fill", tint: Otty.Status.warn)
        case .caffeinate: .symbol(name: "cup.and.saucer.fill", tint: Otty.Text.secondary)
        case .sudo: .symbol(name: "shield.lefthalf.filled", tint: Otty.Text.secondary)
        }
    }

    /// The accessibility / tooltip label for a tab badge, so the otherwise icon-only glyph is VoiceOver-
    /// legible and testable. Pure text — mirrors the `progress-state.md` badge vocabulary.
    static func tabBadgeLabel(_ kind: TabBadgeKind) -> String {
        switch kind {
        case .running: "Running"
        case .completed: "Completed"
        case .finished: "Finished"
        case .error: "Error"
        case .awaitingInput: "Awaiting input"
        case .caffeinate: "Caffeinated"
        case .sudo: "Privileged"
        }
    }
}

/// The rendering recipe for one tab badge (see ``StatusPresentation/tabBadge(_:)``). `.spinner` and `.dot`
/// are bespoke shapes the view draws directly; `.symbol` is an SF-symbol name + its tint. A pure value (no
/// view), so the badge map can be unit-tested without rendering.
enum TabBadgeStyle {
    /// An indeterminate gray spinner (a running command / working agent). A pure SwiftUI animation — never a
    /// video/capture session (CLAUDE.md hang-safety rule #6).
    case spinner
    /// A small filled accent dot (the settled "unread output" `.finished` marker).
    case dot(Color)
    /// A tinted SF-symbol fill (completed / error / awaiting-input / caffeinate / sudo).
    case symbol(name: String, tint: Color)
}
#endif
