import Foundation
import Observation
import RworkHost

/// `@MainActor @Observable` start/stop wrapper over the in-process terminal ``HostServer``.
///
/// This is the in-process path (NOT a `rwork-hostd` subprocess): `RworkHost` is a clean
/// library product and `HostServer` has a fully app-usable public surface, so the menu-bar app
/// runs the SAME server the CLI runs — replicating the ~6 lines of `rwork-hostd/main.swift`
/// (construct → `start()` → read back `boundPort()`; `stop()` on teardown) on a background
/// task driven by a Start/Stop toggle. The plain-shell `LaunchMode` is hard-coded (no
/// `--claude`); the inspector is out of MVP scope.
@MainActor
@Observable
final class HostController {
    /// The observable lifecycle state driving the popover UI.
    enum State: Equatable {
        case stopped
        case starting
        /// Running and bound to `port` (the OS-resolved port, in case `0` was requested).
        case running(port: UInt16)
        case failed(String)
    }

    private(set) var state: State = .stopped

    /// Live count of distinct connected clients, fed by ``HostServer/onConnectionCountChanged``.
    /// `nil` means "running but the count is not being observed" → the UI shows "Listening".
    private(set) var clientCount: Int?

    /// The running server, retained across the actor while live; `nil` when stopped.
    private var server: HostServer?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isBusy: Bool { state == .starting }

    /// SF Symbol for the menu-bar status item. Red-tinted "missing-permission" affordance is
    /// applied at the view layer (research §C1); this just reflects the running state.
    var menuBarSymbol: String {
        switch state {
        case .running: return "bolt.horizontal.circle.fill"
        case .starting: return "bolt.horizontal.circle"
        case .stopped, .failed: return "bolt.horizontal.circle"
        }
    }

    /// Start the in-process terminal host on `port` (0 → OS-assigned; read back the real port).
    /// No-op unless currently stopped/failed.
    func start(port: UInt16) {
        switch state {
        case .running, .starting:
            return
        case .stopped, .failed:
            break
        }
        state = .starting
        clientCount = 0

        let server = HostServer(port: port, launchMode: .shell)
        // Surface session lifecycle to this process's stderr (same shape as the CLI's logger),
        // so a `Console.app` / launch-from-Terminal run shows "mux connection … accepted".
        server.onLog = { message in
            FileHandle.standardError.write(Data("RworkHost: \(message)\n".utf8))
        }
        // Live client count. The hook fires off the main actor (from the lock-guarded
        // spawn/remove paths), so hop to this actor before mutating observable state. The
        // delivery is a single Int assignment — not a Task-per-event firehose.
        server.onConnectionCountChanged = { [weak self] count in
            Task { @MainActor in self?.clientCount = count }
        }
        self.server = server

        Task {
            do {
                try await server.start()
                let bound = await server.boundPort() ?? port
                // Guard against a stop() that raced in while we were awaiting start().
                guard self.server === server else { return }
                self.state = .running(port: bound)
            } catch {
                guard self.server === server else { return }
                self.server = nil
                self.clientCount = nil
                self.state = .failed(Self.describe(error))
            }
        }
    }

    /// Stop the in-process host and return to `.stopped`. No-op when not running.
    func stop() {
        guard let server else { return }
        self.server = nil
        state = .stopped
        clientCount = nil
        Task { await server.stop() }
    }

    /// A compact, user-facing error description (avoid dumping a giant Swift error).
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        // POSIX address-in-use (EADDRINUSE = 48) is the common, actionable failure.
        if ns.domain == NSPOSIXErrorDomain && ns.code == 48 {
            return "Port already in use"
        }
        return ns.localizedDescription
    }
}
