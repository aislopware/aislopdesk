// AgentInputFooterCoordinator — handles the typed ``AgentInputFooterAction``s emitted by the footer,
// wiring each to the real logic (warp-bottom-bar.md §5 dispatch-then-handle). It owns the per-pane
// view-state the footer needs (the file-explorer model) and routes the rest into the proven models:
//
//   - installNotifications  → PreferencesStore.enableNotifications(agent)   (W4; TODO host OSC wire)
//   - dismissNotifications  → PreferencesStore.dismissNotificationChip(agent) (W4, persisted)
//   - toggleRichInput       → InputBarModel.toggleRichMode()                (W3, real toggle)
//   - toggleFileExplorer    → FileExplorerModel.toggle(cwd:isRemote:)       (W2, real listing)
//   - startRemoteControl    → onStartRemoteControl()                        (W1, opens picker via parent)
//   - openAgentSettings     → onOpenSettings()                             (route to settings, L5)
//   - addContext            → onAddContext()                               (add-context menu, stub)
//   - selectFile(path)      → onSelectFile(path)                           (insert into prompt)
//
// `@MainActor @Observable` so the footer view re-renders on the toggle-state changes it owns. The
// PreferencesStore is injected (single owner from the app scene); the InputBarModel is the pane's.

import AislopdeskWorkspaceCore
import Foundation
import Observation

@preconcurrency
@MainActor
@Observable
public final class AgentInputFooterCoordinator {
    /// The agent display name (folds into the green pill label + the dismissal/enable persistence key).
    public let agentName: String
    /// The pane's input bar — the rich-input toggle target (W3). `nil` ⇒ the Rich-Input pill is inert.
    @ObservationIgnored public let inputBar: InputBarModel?
    /// The single live preferences owner — drives notification dismissal/enable persistence (W4).
    @ObservationIgnored public let preferences: PreferencesStore?
    /// The pane's last-known cwd (for the file explorer) + whether it is a remote pane.
    @ObservationIgnored public var cwd: String?
    @ObservationIgnored public let isRemote: Bool

    /// The per-pane file-explorer panel state (W2). Observed by the footer/leaf so the panel toggles.
    public let fileExplorer = FileExplorerModel()

    // Parent-supplied hooks for actions the footer can't complete on its own at L4.
    /// W1: open the remote-window picker / start sharing. The full video-pane mount is L6; this triggers
    /// the picker/open path as far as the existing logic allows. TODO(L6): mount the video pane.
    @ObservationIgnored public var onStartRemoteControl: () -> Void = {}
    /// Route to the coding-agent settings (the Settings overlay lands in L5). TODO(L5).
    @ObservationIgnored public var onOpenSettings: () -> Void = {}
    /// The add-context "+" menu (stub at L4). TODO: surface the attach/context menu.
    @ObservationIgnored public var onAddContext: () -> Void = {}
    /// A file was chosen (from the explorer) → insert its path into the prompt.
    @ObservationIgnored public var onSelectFile: (String) -> Void = { _ in }

    public init(
        agentName: String,
        inputBar: InputBarModel?,
        preferences: PreferencesStore?,
        cwd: String?,
        isRemote: Bool = false,
    ) {
        self.agentName = agentName
        self.inputBar = inputBar
        self.preferences = preferences
        self.cwd = cwd
        self.isRemote = isRemote
    }

    // MARK: Derived view-state the footer binds

    /// Whether the green suggestion chip should be shown (not dismissed, not already enabled — W4).
    public var showsNotificationChip: Bool {
        preferences?.shouldShowNotificationChip(for: agentName) ?? true
    }

    /// The Rich-Input pill's toggled-on state (W3).
    public var richInputActive: Bool { inputBar?.richMode ?? false }

    /// The File-explorer pill's toggled-on state (W2).
    public var fileExplorerActive: Bool { fileExplorer.isOpen }

    // MARK: The single handler

    /// Route one footer action to its logic. The ONLY place footer intents are interpreted.
    public func handle(_ action: AgentInputFooterAction) {
        switch action {
        case .installNotifications:
            // W4: record intent + (TODO host) fire the OSC/notification-enable wire when it exists.
            preferences?.enableNotifications(for: agentName)
        case .dismissNotifications:
            preferences?.dismissNotificationChip(for: agentName) // W4: persisted dismissal
        case .toggleRichInput:
            inputBar?.toggleRichMode() // W3: real multi-line rich-input toggle
        case .toggleFileExplorer:
            fileExplorer.toggle(cwd: cwd, isRemote: isRemote) // W2: real cwd listing
        case .startRemoteControl:
            onStartRemoteControl() // W1: open the remote-window picker (video mount = L6)
        case .openAgentSettings:
            onOpenSettings()
        case .addContext:
            onAddContext()
        case let .selectFile(path):
            onSelectFile(path)
        }
    }
}
