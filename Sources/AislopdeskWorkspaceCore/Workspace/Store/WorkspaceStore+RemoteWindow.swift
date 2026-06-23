// WorkspaceStore+RemoteWindow — the LIVE tree-path entry point for opening a remote-GUI (PATH 2 video)
// pane PRE-BOUND to a host window (the L6 Remote-Window picker / `/remote-control` pill / "New Remote
// Window Tab" action). The canvas-era counterpart is ``WorkspaceStore/addRemoteWindowPane(windowID:title:
// appName:)``; this one reshapes the TREE so it works under the IDE shell.

import Foundation

public extension WorkspaceStore {
    /// Opens a NEW `.remoteGUI` tab PRE-BOUND to host window `windowID` on the LIVE tree shell — the
    /// tree-path counterpart of the canvas-era ``addRemoteWindowPane(windowID:title:appName:)``. The spec
    /// carries the ``VideoEndpoint`` so the materialized ``RemoteWindowModel`` opens immediately (admission
    /// still flows through ``liveVideoCap`` at activation — a saturated cap shows the gated placeholder).
    /// Selected + focused like ``newTab(kind:)``. Returns the new pane id.
    @discardableResult
    func newRemoteWindowTab(windowID: UInt32, title: String, appName: String) -> PaneID {
        let label = title.isEmpty ? (appName.isEmpty ? "Remote window" : appName) : title
        let spec = PaneSpec(
            kind: .remoteGUI,
            title: label,
            video: VideoEndpoint(windowID: windowID, title: label, appName: appName),
        )
        let (next, id) = WorkspaceTreeOps.newTab(in: tree, spec: spec)
        tree = next
        reconcileTree()
        return id
    }
}
