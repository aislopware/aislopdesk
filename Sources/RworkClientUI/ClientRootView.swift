#if canImport(SwiftUI)
import SwiftUI
import RworkInspector

/// The root client view: a split layout of the terminal screen + a toggleable inspector
/// panel, with the connection chrome on top and the input bar at the bottom.
///
/// Platform chrome differs (`#if os(macOS)` / `#if os(iOS)`):
/// - **macOS**: a side-by-side `HSplitView`-style layout (terminal left, inspector right) —
///   doc 16 "desktop = split-view".
/// - **iOS**: the inspector is a bottom sheet / overlay toggled from the toolbar — doc 16
///   "iOS = tab/bottom-sheet".
public struct ClientRootView: View {
    @State private var connection: ConnectionViewModel
    @State private var input: InputBarModel
    @State private var remoteWindow: RemoteWindowModel
    private let inspectorModel: InspectorViewModel
    private let inspectorClient: InspectorClient?

    @State private var showInspector = false
    @State private var showRemoteWindow = false

    public init(
        connection: ConnectionViewModel,
        input: InputBarModel = InputBarModel(),
        remoteWindow: RemoteWindowModel = RemoteWindowModel(),
        inspectorModel: InspectorViewModel = InspectorViewModel(),
        inspectorClient: InspectorClient? = nil
    ) {
        _connection = State(initialValue: connection)
        _input = State(initialValue: input)
        _remoteWindow = State(initialValue: remoteWindow)
        self.inspectorModel = inspectorModel
        self.inspectorClient = inspectorClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConnectionView(model: connection)
            Divider()
            content
            Divider()
            InputBarView(model: input, client: connection.activeClient)
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
        // PATH 2 (secondary): a remote GUI window opens in a sheet so the terminal stays
        // primary. The panel hosts the endpoint form + the live VideoWindowFactory view.
        .sheet(isPresented: $showRemoteWindow) {
            RemoteWindowPanel(model: remoteWindow)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 480)
                #else
                .presentationDetents([.large])
                #endif
        }
        .task { autoOpenRemoteWindowIfRequested() }
    }

    /// Automation seam (PATH 2): if `RWORK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports +
    /// window id are present in the environment, fill the Remote-window form and open the live
    /// `VideoWindowView` on launch — the counterpart to `RworkClientApp`'s terminal
    /// `RWORK_AUTOCONNECT`. This lets `scripts/check-video.sh` drive a real end-to-end video
    /// check (rwork-videohostd capture/encode → this app decode/Metal-render) WITHOUT fragile
    /// SwiftUI automation of the endpoint form. All vars unset in normal use, so a production
    /// launch is unaffected; runs once when the root scene first appears.
    private func autoOpenRemoteWindowIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["RWORK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let media = env["RWORK_VIDEO_AUTOCONNECT_MEDIA_PORT"], !media.isEmpty,
              let cursor = env["RWORK_VIDEO_AUTOCONNECT_CURSOR_PORT"], !cursor.isEmpty,
              let wid = env["RWORK_VIDEO_AUTOCONNECT_WINDOW_ID"], !wid.isEmpty else { return }
        remoteWindow.host = host
        remoteWindow.mediaPort = media
        remoteWindow.cursorPort = cursor
        remoteWindow.windowID = wid
        if let title = env["RWORK_VIDEO_AUTOCONNECT_TITLE"], !title.isEmpty {
            remoteWindow.title = title
        }
        remoteWindow.open()
        showRemoteWindow = true
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // Desktop: terminal + inspector side-by-side (doc 16 split-view).
        HStack(spacing: 0) {
            terminal
            if showInspector {
                Divider()
                inspector
                    .frame(minWidth: 280, maxWidth: 420)
            }
        }
        .toolbar { inspectorToggle; remoteWindowToggle }
        #else
        // iOS: terminal full-bleed, inspector as a bottom sheet (doc 16 tab/bottom-sheet).
        terminal
            .toolbar { inspectorToggle; remoteWindowToggle }
            .sheet(isPresented: $showInspector) {
                inspector
                    .presentationDetents([.medium, .large])
            }
        #endif
    }

    private var terminal: some View {
        TerminalScreenView(model: connection.terminalModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        InspectorPanel(model: inspectorModel, client: inspectorClient)
    }

    private var inspectorToggle: some ToolbarContent {
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: showInspector ? "sidebar.right" : "sidebar.squares.right")
            }
        }
    }

    /// Opens the PATH 2 remote-GUI-window sheet (endpoint form + live video view).
    private var remoteWindowToggle: some ToolbarContent {
        ToolbarItem {
            Button {
                showRemoteWindow.toggle()
            } label: {
                Label("Remote window", systemImage: "macwindow.on.rectangle")
            }
        }
    }
}
#endif
