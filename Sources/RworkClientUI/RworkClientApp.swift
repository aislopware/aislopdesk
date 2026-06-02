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
        // Build the store exactly once with the production session factory. `makeInspector` is now the
        // live builder (`WorkspaceStore.liveMakeInspector`): a `.claudeCode` pane's read-only inspector
        // second channel (NWConnection #2) is an `NWByteChannel` → `InspectorClient` over the
        // terminal-port+1 convention (docs/16, docs/20, docs/22 §7), connected LAZILY on appear. The
        // GUARDRAIL holds: the host does not yet serve an inspector port, so the channel simply never
        // completes its handshake against today's `rwork-hostd` and the terminal is unaffected — the
        // FOLD is what is wired + unit-tested (via `LoopbackByteChannel`), and real-network inspector
        // serving is a hardware followup. We pass it explicitly (rather than relying on the default) so
        // the wiring is auditable here at the one app-glue site.
        // One persistence handle: it loads the restored tree here AND backs the store's debounced
        // save-on-mutation (docs/22 §6). The same default file URL on both sides so a debounced write
        // and the next launch's load agree.
        let persistence = WorkspacePersistence()
        let store = WorkspaceStore(
            restoring: persistence.load(),
            makeSession: WorkspaceStore.liveMakeSession(
                makeClient: { RworkClient() },
                makeInspector: WorkspaceStore.liveMakeInspector
            ),
            liveVideoCap: 2,
            persistence: persistence
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
        // The native command surface (docs/22 §5): a Pane + Tab menu on macOS, the hardware-keyboard
        // ⌘-hold HUD on iPadOS — both driven by the SAME ⌘/⌥-prefixed shortcuts as
        // `CommandInterpreter.defaultBindings`, so plain keys + Ctrl-letters still flow to the focused
        // terminal (the §5 conflict rule). Each item resolves the key scene's store via
        // `@FocusedValue(\.workspaceStore)`, which `WorkspaceRootView` publishes. The ⌘K command
        // palette is a window-level affordance owned inside `WorkspaceRootView` (it needs view-tree
        // state + an overlay), so it is wired there, not here.
        .commands { WorkspaceCommands() }
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
                // Flush the tree NOW (cancelling any in-flight debounced save) through the store's
                // configured persistence — docs/22 §6 save-on-background.
                store.saveImmediately()
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
