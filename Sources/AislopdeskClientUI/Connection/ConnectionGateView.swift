#if canImport(SwiftUI)
import SwiftUI

/// The app-global connect-gate (docs/31): a modal card over the whole workspace that blocks the canvas
/// until the ONE ``AppConnection`` is `.connected`. It owns host/port entry (+ collapsible video ports),
/// the Connect/Retry button, and the single app-wide status. Shown by ``WorkspaceRootView`` whenever the
/// connection is not `.connected`; on a mid-session drop it reappears showing "reconnecting…" and
/// dismisses itself when the supervisor restores the link.
public struct ConnectionGateView: View {
    @Bindable private var connection: AppConnection
    /// Whether the video ports are revealed (collapsed by default — most users only set host + port).
    @State private var showAdvanced = false

    public init(connection: AppConnection) {
        _connection = Bindable(connection)
    }

    public var body: some View {
        ZStack {
            // Dimmed backdrop: the canvas behind is unusable until connected. Tapping it does nothing
            // (you must connect or it stays) — a hard gate, not a dismissible sheet.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            card
                .frame(maxWidth: 460)
                .padding(DSSpace.s8)
                // Hard modal (NOT a transient overlay): keep the .regularMaterial backing + the modal
                // corner, but tokenize the radius (DSRadius.modal=16), the shadow (the single
                // DSElevation.shadowModal profile), and add the L4 inner top-edge highlight.
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.modal, style: .continuous))
                // Inner top-edge highlight, clipped to the modal corner so the 1pt strip follows the round.
                .overlay(alignment: .top) { DSElevation.innerTopHighlight() }
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.modal, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.modal, style: .continuous).strokeBorder(.separator))
                .dsShadow(DSElevation.shadowModal)
                .padding(DSSpace.s8)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: DSSpace.s5) {
                Image(systemName: "network")
                    .dsFont(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: DSSpace.s1) {
                    Text("Connect to a host")
                        .font(.title3.weight(.semibold))
                    Text("Enter the address of a machine running aislopdesk-hostd.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("host", text: $connection.host)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    #endif
                        .disabled(isBusy)
                    TextField("port", text: $connection.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                        .disabled(isBusy)
                    // Recent hosts (most-recent-first, successful connects only): one pick fills the
                    // whole form — the daily two-machine loop should never re-type an address.
                    if !connection.recentTargets.isEmpty {
                        Menu {
                            ForEach(Array(connection.recentTargets.enumerated()), id: \.offset) { _, t in
                                Button("\(t.host):\(String(t.port))") { connection.fillForm(from: t) }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .fixedSize()
                        .help("Recent hosts")
                        .accessibilityLabel("Recent hosts")
                        .disabled(isBusy)
                    }
                }
                .onSubmit { connectIfPossible() }

                DisclosureGroup("Video ports", isExpanded: $showAdvanced) {
                    HStack(spacing: 8) {
                        labeledField("media", text: $connection.mediaPort)
                        labeledField("cursor", text: $connection.cursorPort)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .disabled(isBusy)

                if let hint = connection.validationHint, !isBusy {
                    Text(hint).font(.caption2).foregroundStyle(.red)
                }
            }

            HStack(spacing: 10) {
                statusRow
                Spacer()
                actionButton
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isBusy { ProgressView().controlSize(.small) }
            Circle()
                .fill(PaneConnectionStatus.from(connection.status).color)
                .frame(width: 8, height: 8)
            // Human, actionable copy ("Connection refused — is aislopdesk-hostd running?"), with the
            // raw transport payload preserved as a tooltip for debugging. The reconnect campaign is
            // honest about its progress ("attempt 3 of 20") vs a first "Connecting…".
            Text(ConnectionPresenter.headline(for: connection.status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(ConnectionPresenter.rawDetail(for: connection.status) ?? "")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch connection.status {
        case .connecting,
             .reconnecting:
            Button("Cancel", role: .cancel) { Task { await connection.disconnect() } }
        case .disconnected,
             .connected:
            Button("Connect") { connectIfPossible() }
                .buttonStyle(.borderedProminent)
                .disabled(!connection.canConnect)
        case .failed,
             .unreachable:
            Button("Retry") { connectIfPossible() }
                .buttonStyle(.borderedProminent)
                .disabled(!connection.canConnect)
        }
    }

    /// Whether the connection is mid-attempt (form locked + spinner shown).
    private var isBusy: Bool {
        switch connection.status {
        case .connecting,
             .reconnecting: true
        case .disconnected,
             .connected,
             .failed,
             .unreachable: false
        }
    }

    private func connectIfPossible() {
        guard connection.canConnect, !isBusy else { return }
        Task { await connection.connect() }
    }
}
#endif
