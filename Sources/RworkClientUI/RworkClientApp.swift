#if canImport(SwiftUI)
import SwiftUI
import RworkClient
import RworkInspector

/// The Rwork client app scene, shared by both Xcode app targets (ClientApp-macOS,
/// ClientApp-iOS). The app targets reference this as their `@main` entry — see the
/// `project.yml`s under `Apps/`.
///
/// It owns ONE ``WorkspaceStore`` (docs/22 §7 app-shell): the single `@MainActor @Observable`
/// source of truth for the whole workspace (the tree of intent + the table of liveness), built with
/// the production `makeSession` factory (``LivePaneSession/make(_:makeClient:makeInspector:)`` via
/// ``WorkspaceStore/liveMakeSession(makeClient:makeInspector:)``). `body` is just
/// ``WorkspaceRootView``.
///
/// Platform chrome is branched with `#if os(macOS)` / `#if os(iOS)`:
/// - macOS: a resizable `WindowGroup`; scene phase is informational only.
/// - iOS: scene phase drives the AWAITED `pause()`/`resume()` fan-out over EVERY session
///   (`store.pauseAll()` / `store.resumeAll()`) so no socket is stranded across background.
///
/// The terminal renderer + video factories are the gated seams, registered once in
/// `Apps/Shared/AppMain.swift` (UNCHANGED) — this shell never imports `CGhostty`/`RworkVideoClient`.
public struct RworkClientApp: App {
    /// The single workspace store. Built ONCE in ``init()`` (no `@State` double-init: we construct the
    /// store eagerly and seed the `@State` backing with it, never reassigning).
    @State private var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        // Build the store exactly once with the production session factory. `makeInspector` returns
        // `nil` for now: the read-only inspector second channel (NWConnection #2) needs an endpoint →
        // `ByteChannel` bridge that does not exist yet (`InspectorClient` is `init(channel:)` only) —
        // it is the genuinely-missing app-glue WF5 wires (docs/22 §7). Returning `nil` is the correct
        // interim: a Claude Code pane shows its terminal with no live inspector until then.
        let store = WorkspaceStore(
            restoring: WorkspacePersistence().load(),
            makeSession: WorkspaceStore.liveMakeSession(
                makeClient: { RworkClient() },
                makeInspector: { _ in nil }
            ),
            liveVideoCap: 2
        )
        // Automation seams (docs/22 §7): only when the env vars are present do we let the bootstrap
        // REPLACE the restored workspace with the autoconnect/video shape (it resets to the default
        // workspace otherwise, which would discard a real user's restored tabs). The env-var names are
        // unchanged so `check-macos.sh` / `check-video.sh` keep working; the actual connect / autotype
        // / video-open TRIGGER stays in the view layer (WF5).
        if Self.hasAutomationEnvironment() {
            store.bootstrapFromEnvironment()
        }
        _store = State(initialValue: store)
    }

    public var body: some Scene {
        WindowGroup {
            WorkspaceRootView(store: store)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }

    /// Whether any of the automation env vars (`RWORK_AUTOCONNECT_*` / `RWORK_VIDEO_AUTOCONNECT_*`)
    /// are set. Gates the bootstrap so a normal launch restores the persisted workspace untouched.
    private static func hasAutomationEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let keys = [
            "RWORK_AUTOCONNECT_HOST",
            "RWORK_VIDEO_AUTOCONNECT_HOST",
        ]
        return keys.contains { (env[$0]?.isEmpty == false) }
    }

    /// Drives the iOS lifecycle seam over EVERY session (docs/22 §4 the single, AWAITED fan-out):
    /// background → `pauseAll()` (each connection's host retains the tail; each inspector channel is
    /// closed), then persist the tree; foreground → `resumeAll()` (byte-exact + inspector re-tail).
    /// On macOS scene phase is informational only.
    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .background:
            Task {
                await store.pauseAll()
                try? WorkspacePersistence().save(store.workspace)
            }
        case .active:
            Task { await store.resumeAll() }
        default:
            break
        }
        #endif
    }
}
#endif
