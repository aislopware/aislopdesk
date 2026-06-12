#if canImport(SwiftUI)
import Foundation

/// Client-side driver of the "show system popups in their own pane" feature: while the app is connected
/// it POLLS the host for its open SYSTEM dialogs (a SecurityAgent login/password prompt etc.) via the
/// ``SystemDialogDiscovery`` seam, and diffs the answer to AUTO-SPAWN an ephemeral ``PaneKind/systemDialog``
/// pane per dialog — closing it again the moment the dialog leaves the list.
///
/// **Why poll (not host-push):** a dialog is a discrete event; polling reuses the proven session-LESS
/// request/answer plumbing (the picker's `listWindows` lane) with zero new host-push infrastructure, and a
/// ~2 s detection latency for a prompt is imperceptible. The host answers `listSystemDialogs` session-less.
///
/// **Lifecycle:** the app scene owns a `.task { await monitor.run() }`; `run()` loops until that task is
/// cancelled (scene teardown), then closes every pane it spawned. Inert when no discovery seam is
/// registered (headless / no video module) or while disconnected.
@MainActor
public final class SystemDialogMonitor {
    private weak var store: WorkspaceStore?
    private let isConnected: @MainActor () -> Bool
    private let target: @MainActor () -> ConnectionTarget
    private let pollGap: Duration
    /// host windowID → the ephemeral pane currently streaming it.
    private var spawned: [UInt32: PaneID] = [:]

    public init(store: WorkspaceStore,
                isConnected: @escaping @MainActor () -> Bool,
                target: @escaping @MainActor () -> ConnectionTarget,
                pollGap: Duration = .seconds(2)) {
        self.store = store
        self.isConnected = isConnected
        self.target = target
        self.pollGap = pollGap
    }

    /// Polls + reconciles until the owning Task is cancelled, then closes any spawned panes. While
    /// DISCONNECTED it simply idles (the spawned panes show the "paused" placeholder; the next connected
    /// poll reconciles them) rather than tearing them down on every transient blip.
    public func run() async {
        defer { closeAllSpawned() }
        while !Task.isCancelled {
            if isConnected(), let query = SystemDialogDiscovery.shared {
                let t = target()
                let dialogs = await query(t.host, t.mediaPort, t.cursorPort)
                if Task.isCancelled { break }
                reconcile(dialogs)
            }
            try? await Task.sleep(for: pollGap)
        }
    }

    /// Spawn a pane for each newly-seen dialog; close the pane for each dialog that is gone. Pure diff over
    /// `spawned` — a pane the USER closed manually stays closed (its id lingers in `spawned` until the
    /// dialog itself closes, at which point the close is a safe no-op).
    private func reconcile(_ dialogs: [SystemDialogInfo]) {
        guard let store else { return }
        let present = Set(dialogs.map(\.windowID))
        // Close gone dialogs FIRST so a freed video-cap slot is available before a new one is admitted.
        for (wid, id) in spawned where !present.contains(wid) {
            store.closePane(id)
            spawned.removeValue(forKey: wid)
        }
        for d in dialogs where spawned[d.windowID] == nil {
            spawned[d.windowID] = store.addSystemDialogPane(
                windowID: d.windowID, owner: d.owner, title: d.title, isSecure: d.isSecure)
        }
    }

    private func closeAllSpawned() {
        if let store { for (_, id) in spawned { store.closePane(id) } }
        spawned.removeAll()
    }
}
#endif
