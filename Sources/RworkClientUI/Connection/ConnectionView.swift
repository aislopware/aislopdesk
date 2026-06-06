#if canImport(SwiftUI)
import SwiftUI

/// Host/port entry + connect/disconnect + live status + session id. Binds a
/// ``ConnectionViewModel`` (which owns the ``RworkClient`` + ``ReconnectManager``).
public struct ConnectionView: View {
    @Bindable private var model: ConnectionViewModel

    public init(model: ConnectionViewModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("host", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                TextField("port", text: $model.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                connectButton
            }
            // Return-to-connect: pressing Enter in either field triggers Connect, gated exactly like the
            // Connect button (actionable + canConnect) so it is inert when the button is disabled or a
            // session is live/connecting — a keyboard-only path to dial in (UI/UX pass-3 #10).
            .onSubmit {
                guard isFormActionable, model.canConnect else { return }
                Task { await model.connect() }
            }

            // Explain a disabled Connect button instead of leaving it silently greyed. Only while the
            // form is actionable (a connectable state) — never over a live/connecting session.
            if isFormActionable, let hint = model.validationHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                statusBadge
                if let sid = model.sessionID {
                    Text("session \(sid.uuidString.prefix(8))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let log = model.lastLog {
                    Text(log)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
    }

    /// Whether the form is showing a Connect button (so a validation hint is meaningful) rather than
    /// a live/connecting session's Disconnect.
    private var isFormActionable: Bool {
        switch model.status {
        case .disconnected, .failed, .unreachable: return true
        case .connected, .reconnecting, .connecting: return false
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        switch model.status {
        case .connected, .reconnecting, .connecting:
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnect() }
            }
        case .disconnected, .failed, .unreachable:
            Button("Connect") {
                Task { await model.connect() }
            }
            .disabled(!model.canConnect)
            .help(model.validationHint ?? "Connect to the host")
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            // Fill the dot from the SINGLE status→colour mapping (`PaneConnectionStatus.from(_:).color`)
            // the chrome + sidebar already share — instead of a 3rd hand-rolled switch that the SSOT
            // doc-comment promises can't drift. Static 8pt dot (no pulse) is the intentional form here.
            Circle()
                .fill(PaneConnectionStatus.from(model.status).color)
                .frame(width: 8, height: 8)
            Text(model.status.label)
                .font(.system(.caption, design: .monospaced))
        }
        // The colour-only dot reads nothing to VoiceOver; combine it with the adjacent status text so
        // the pair speaks as one labelled element (e.g. "connected") — matching the shared PaneStatusDot.
        .accessibilityElement(children: .combine)
    }
}
#endif
