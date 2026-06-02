#if canImport(SwiftUI)
import SwiftUI

/// Holds the entry fields for opening one remote GUI window (PATH 2 / Phase 4) and the
/// resulting ``RemoteWindowDescriptor`` once the user opens it. `@MainActor @Observable`
/// so the ``RemoteWindowPanel`` form binds directly.
///
/// PATH 2 is the SECONDARY path (terminal-first). The client cannot discover the host's
/// shareable windows over the wire yet (no window-list control protocol), so the endpoint
/// is entered by hand: the host daemon (`rwork-videohostd --list`) prints each window's
/// CGWindowID + title + the media/cursor ports it serves, and the user types them here.
/// When that discovery protocol lands, this model is where a picked window would populate.
@MainActor
@Observable
public final class RemoteWindowModel {
    // MARK: Entry fields (bound to the form)
    public var host: String
    public var mediaPort: String
    public var cursorPort: String
    public var windowID: String
    public var title: String

    /// The opened window's descriptor (carries the full endpoint). `nil` ⇒ the form is shown;
    /// non-nil ⇒ the live ``VideoWindowFactory`` view is shown.
    public private(set) var active: RemoteWindowDescriptor?

    public init(
        host: String = "",
        mediaPort: String = "9000",
        cursorPort: String = "9001",
        windowID: String = "",
        title: String = "Remote window"
    ) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
        self.title = title
    }

    var parsedMediaPort: UInt16? { UInt16(mediaPort.trimmingCharacters(in: .whitespaces)) }
    var parsedCursorPort: UInt16? { UInt16(cursorPort.trimmingCharacters(in: .whitespaces)) }
    var parsedWindowID: UInt32? { UInt32(windowID.trimmingCharacters(in: .whitespaces)) }

    /// Whether the fields parse to a complete endpoint (non-empty host, valid + DISTINCT
    /// media/cursor ports, valid windowID). The two UDP sockets must use different ports.
    public var canOpen: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedMediaPort != nil && parsedMediaPort != 0
            && parsedCursorPort != nil && parsedCursorPort != 0
            && parsedMediaPort != parsedCursorPort
            && parsedWindowID != nil
    }

    /// Builds the descriptor from the entered endpoint and marks it active (the panel then
    /// brings up the live ``VideoWindowView`` via the factory). No-op if the fields are invalid.
    public func open() {
        guard canOpen,
              let media = parsedMediaPort,
              let cursor = parsedCursorPort,
              let wid = parsedWindowID else { return }
        active = RemoteWindowDescriptor(
            title: title.isEmpty ? "window \(wid)" : title,
            windowID: wid,
            host: host.trimmingCharacters(in: .whitespaces),
            mediaPort: media,
            cursorPort: cursor
        )
    }

    /// Closes the remote window (tears down the live view → its orchestrator `stop()`).
    public func close() {
        active = nil
    }
}

/// The PATH 2 panel: an endpoint-entry form, then the live remote-GUI-window view once opened.
///
/// When no window is active it shows the connect form; when active it shows
/// ``VideoWindowFactory/make(_:)`` (the app-injected `VideoWindowView`, or the gated
/// placeholder if no factory was registered) plus a Close button.
public struct RemoteWindowPanel: View {
    @Bindable private var model: RemoteWindowModel

    public init(model: RemoteWindowModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let descriptor = model.active {
                VideoWindowFactory.make(descriptor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text(descriptor.title)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button("Close", role: .destructive) { model.close() }
                }
                .padding(8)
                .background(.ultraThinMaterial)
            } else {
                entryForm
            }
        }
    }

    private var entryForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open a remote GUI window")
                .font(.headline)
            Text("PATH 2 (secondary). Run `rwork-videohostd --list` on the host to find a "
                 + "window's id + ports, then enter them here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("host", text: $model.host, kind: .url)
            HStack(spacing: 8) {
                field("media port", text: $model.mediaPort, kind: .number)
                field("cursor port", text: $model.cursorPort, kind: .number)
            }
            field("window id", text: $model.windowID, kind: .number)
            field("title (optional)", text: $model.title, kind: .plain)

            Button("Open") { model.open() }
                .disabled(!model.canOpen)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private enum FieldKind { case url, number, plain }

    @ViewBuilder
    private func field(_ prompt: String, text: Binding<String>, kind: FieldKind) -> some View {
        let tf = TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        #if os(iOS)
        switch kind {
        case .url:
            tf.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        case .number:
            tf.keyboardType(.numberPad)
        case .plain:
            tf
        }
        #else
        tf
        #endif
    }
}
#endif
