// AgentInputFooterAction — the typed intents the Claude-Code bottom integration bar emits
// (warp-bottom-bar.md §5). The footer view is dumb: each pill's `onClick` emits one of these via a
// single closure, and a small coordinator (``AgentInputFooterCoordinator``) handles them against the
// real logic (PreferencesStore / InputBarModel / RemoteWindowModel / a settings hook). This mirrors
// Warp's dispatch-then-handle split (`AgentInputFooterAction` enum + handlers in `mod.rs`).
//
// One case per pill in the CLI footer layout:
//   - installNotifications   ← the green suggestion pill's main half  (W4)
//   - dismissNotifications    ← the green suggestion pill's trailing ✕ (W4)
//   - addContext              ← the leading "+" pill (attach file / add context)
//   - selectFile              ← a chosen file from the file explorer / picker
//   - startRemoteControl      ← the "/remote-control" pill            (W1)
//   - toggleFileExplorer      ← the "File explorer" pill              (W2)
//   - toggleRichInput         ← the "Rich Input" pill                 (W3)
//   - openAgentSettings       ← the "Settings" sliders pill

import Foundation

/// A typed intent emitted by a footer pill. `selectFile` carries the chosen path; the rest are bare.
public enum AgentInputFooterAction: Equatable, Sendable {
    /// The green pill's main half — enable rich agent notifications (W4).
    case installNotifications
    /// The green pill's trailing ✕ — dismiss the suggestion chip, persisted (W4).
    case dismissNotifications
    /// The "+" pill — add context (toggles the per-pane file explorer; a file pick inserts its path).
    case addContext
    /// A file chosen via the file-explorer panel / picker → its absolute path (W2).
    case selectFile(String)
    /// The "/remote-control" pill — open the remote-window picker / start sharing (W1).
    case startRemoteControl
    /// The "File explorer" pill — toggle the per-pane file panel (W2).
    case toggleFileExplorer
    /// The "Rich Input" pill — toggle multi-line rich-input mode (W3).
    case toggleRichInput
    /// The "Settings" sliders pill — open the coding-agent settings.
    case openAgentSettings
}
