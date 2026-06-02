#if canImport(SwiftUI)
import SwiftUI

/// The Rwork client app scene, shared by both Xcode app targets (ClientApp-macOS,
/// ClientApp-iOS). The app targets reference this as their `@main` entry — see the
/// `project.yml`s under `Apps/`.
///
/// It wires the view-models once and hands them to ``ClientRootView``. Platform chrome is
/// branched with `#if os(macOS)` / `#if os(iOS)`:
/// - macOS: a `WindowGroup` plus the standard commands; the window is resizable.
/// - iOS: a `WindowGroup` and the app handles background/foreground via the scene phase to
///   drive the client `pause()`/`resume()` byte-exact-resume seam (doc 17 §2.5).
///
/// The terminal renderer is the gated seam: in the app target, register a
/// ``TerminalRendererFactory/shared`` factory that builds the libghostty
/// `GhosttyTerminalView` once the xcframework is present; until then the BUILD-STATUS
/// placeholder shows. The library compiles and runs without it.
public struct RworkClientApp: App {
    @State private var terminal = TerminalViewModel()
    @State private var connection: ConnectionViewModel
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        let terminal = TerminalViewModel()
        _terminal = State(initialValue: terminal)
        _connection = State(initialValue: ConnectionViewModel(terminal: terminal))
    }

    public var body: some Scene {
        WindowGroup {
            ClientRootView(connection: connection)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .task { await autoConnectIfRequested() }
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }

    /// Automation seam: if `RWORK_AUTOCONNECT_HOST` + `RWORK_AUTOCONNECT_PORT` are present in
    /// the environment, fill the form and connect on launch. This lets `scripts/check-macos.sh
    /// --connect` drive a real end-to-end render check (a host daemon ↔ this GUI, glyphs on the
    /// Metal layer) WITHOUT fragile SwiftUI accessibility automation. Both vars unset in normal
    /// use, so a production launch is unaffected; runs once when the root scene first appears.
    private func autoConnectIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["RWORK_AUTOCONNECT_HOST"], !host.isEmpty,
              let port = env["RWORK_AUTOCONNECT_PORT"], !port.isEmpty else { return }
        connection.host = host
        connection.port = port
        await connection.connect()
    }

    /// Drives the iOS lifecycle seam: background → `pause()` (host retains the tail),
    /// foreground → `resume()` (byte-exact). On macOS scene phase is informational only.
    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .background:
            Task { await connection.pause() }
        case .active:
            Task { await connection.resume() }
        default:
            break
        }
        #endif
    }
}
#endif
