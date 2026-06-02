#if canImport(SwiftUI)
import SwiftUI

/// The **seam** between the cross-platform SwiftUI client and a remote GUI-window
/// video view (PATH 2 / Phase 4, doc 17 §3).
///
/// Like ``TerminalRendererFactory`` for the terminal pixels, the cross-platform
/// library cannot reference `RworkVideoClient.VideoWindowView` directly — that would
/// pull VideoToolbox + Metal into the headless `swift build` (and those frameworks
/// HANG without a window-server + TCC session in a test context). Instead the GUI
/// app target — which links `RworkVideoClient` and runs with the Screen-Recording /
/// decode entitlements — registers a factory at launch; the library calls it and
/// falls back to a clearly-labelled placeholder when no factory was registered
/// (i.e. when no host is capturing a GUI window).
///
/// This is **gated**: the GUI video path is secondary to the terminal path. A remote
/// GUI window only appears when (a) the app injects a factory AND (b) the host is
/// actively capturing a window. Until then the placeholder explains the state.
///
/// Wiring (app target, once at launch):
/// ```swift
/// import RworkVideoClient
/// VideoWindowFactory.shared = { descriptor in
///     AnyView(VideoWindowView(title: descriptor.title))
/// }
/// ```
public struct RemoteWindowDescriptor: Sendable, Equatable {
    /// The remote window's last-known title (from the geometry channel).
    public var title: String
    /// A stable identifier for the remote window (host CGWindowID).
    public var windowID: UInt32
    /// The host's NetBird-routable address (or hostname). Empty ⇒ no live endpoint
    /// (the factory then builds the chrome-only / placeholder view).
    public var host: String
    /// The host media UDP port (control/video/geometry/input). `0` ⇒ no endpoint.
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port. `0` ⇒ no endpoint.
    public var cursorPort: UInt16

    public init(
        title: String,
        windowID: UInt32,
        host: String = "",
        mediaPort: UInt16 = 0,
        cursorPort: UInt16 = 0
    ) {
        self.title = title
        self.windowID = windowID
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
    }

    /// True when the descriptor carries a complete live endpoint (host + two DISTINCT ports).
    /// The app's `VideoWindowFactory` uses this to choose the LIVE `VideoWindowView`
    /// (orchestrator comes up) vs. the chrome-only placeholder. The media + cursor sockets
    /// must be distinct ports (PATH 2 opens two separate UDP connections).
    public var hasEndpoint: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && mediaPort != 0 && cursorPort != 0 && mediaPort != cursorPort
    }
}

/// Injects the production remote-GUI-window video view when the app target provides
/// one. `nil` → the gated placeholder is shown.
@MainActor
public final class VideoWindowFactory {
    /// App-registered factory (set once at launch). `nil` → use the placeholder.
    public static var shared: ((RemoteWindowDescriptor) -> AnyView)?

    /// Builds the remote-GUI-window view: the registered production renderer if
    /// present (and a host is capturing), else the gated placeholder.
    public static func make(_ descriptor: RemoteWindowDescriptor) -> AnyView {
        if let factory = shared {
            return factory(descriptor)
        }
        return AnyView(RemoteWindowPlaceholderView(descriptor: descriptor))
    }
}

/// The gated placeholder shown when the GUI video path is not active (no host
/// capturing / no `RworkVideoClient` view injected). It is NOT a substitute renderer
/// — it explains that the secondary GUI video path is idle. The terminal path is the
/// primary experience (doc 17: terminal-first).
public struct RemoteWindowPlaceholderView: View {
    let descriptor: RemoteWindowDescriptor

    public init(descriptor: RemoteWindowDescriptor) {
        self.descriptor = descriptor
    }

    public var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Remote GUI window not streaming")
                    .font(.headline)
                Text(descriptor.title.isEmpty ? "window \(descriptor.windowID)" : descriptor.title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("the host is not capturing this window (GUI video path is secondary to the terminal path)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
#endif
