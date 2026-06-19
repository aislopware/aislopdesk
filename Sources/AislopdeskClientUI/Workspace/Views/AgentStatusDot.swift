#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - AgentStatusDot (the Claude/agent status indicator — W5)

/// A small colored indicator for a pane / tab / session's rolled-up ``ClaudeStatus`` (docs/41 §4.3,
/// docs/42 W5). The colour maps the Herdr/Warp vocabulary:
/// `needsPermission → red`, `working → yellow`, `done → blue`, `idle → green`, `none → hidden`.
///
/// `.none` renders an EMPTY view (zero size) so a plain terminal pane with no agent shows no dot at all —
/// the sidebar/tab/chrome stays clean until a `claude` is actually detected. Pure presentation; the W10/W11
/// detection pipeline feeds the status in via the store.
struct AgentStatusDot: View {
    /// The rolled-up status to render. `.none` ⇒ nothing.
    let status: ClaudeStatus
    /// The dot diameter (the sidebar uses a slightly larger dot than the pane chrome).
    var size: CGFloat = 7

    var body: some View {
        if let color = Self.color(for: status) {
            Circle()
                .fill(color)
                // A subtle ring so the dot reads on both light and dark sidebars.
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .frame(width: size, height: size)
                .help(Self.label(for: status))
                .accessibilityLabel(Text("agent \(Self.label(for: status))"))
        } else {
            // `.none`: render nothing (zero size) so a no-agent row carries no dot.
            EmptyView()
        }
    }

    /// The dot colour for `status`, or `nil` for ``ClaudeStatus/none`` (hidden).
    static func color(for status: ClaudeStatus) -> Color? {
        switch status {
        case .none: nil
        case .idle: .green
        case .working: .yellow
        case .done: .blue
        case .needsPermission: .red
        }
    }

    /// A short human label for the tooltip / accessibility.
    static func label(for status: ClaudeStatus) -> String {
        switch status {
        case .none: "none"
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .needsPermission: "needs permission"
        }
    }
}
#endif
