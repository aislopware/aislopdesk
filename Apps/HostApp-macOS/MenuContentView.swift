import AppKit
import SwiftUI

/// The body of the menu-bar popover (research §C4 / §C1).
///
/// Top to bottom: a status row (running / stopped / failed), an editable + persisted port
/// field, a Start/Stop button, a best-effort client-activity line, the TCC permission
/// checklist (the C1 deliverable), and a Quit button.
struct MenuContentView: View {
    @Bindable var controller: HostController
    /// The desired listen port, persisted across launches (research default 7779). Editable
    /// only while stopped — changing the port requires a stop → start.
    @Binding var port: Int

    /// Re-preflighted TCC state. Bumped on `.onAppear` and on a light timer so the dots
    /// reflect grants the user just toggled in System Settings (grants go stale — never cache).
    @State private var tccRefreshTick = 0

    /// Drives the periodic TCC re-check while the popover is open.
    private let tccTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            portField
            startStopButton
            clientActivity
            Divider()
            tccChecklist
            Divider()
            quitButton
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { tccRefreshTick &+= 1 }
        .onReceive(tccTimer) { _ in tccRefreshTick &+= 1 }
    }

    // MARK: Header / status

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rwork Host")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch controller.state {
        case let .running(boundPort): return "Running on :\(boundPort)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case let .failed(message): return "Failed: \(message)"
        }
    }

    // MARK: Port

    private var portField: some View {
        HStack {
            Text("Port")
                .frame(width: 56, alignment: .leading)
            TextField("7779", value: $port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isRunning || controller.isBusy)
                .help(controller.isRunning ? "Stop the host to change the port." : "TCP port to listen on (0 = OS-assigned).")
        }
    }

    // MARK: Start / Stop

    private var startStopButton: some View {
        Button(action: toggle) {
            HStack {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(controller.isRunning ? "Stop Host" : "Start Host")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(controller.isRunning ? .red : .accentColor)
        .disabled(controller.isBusy)
    }

    private func toggle() {
        if controller.isRunning {
            controller.stop()
        } else {
            controller.start(port: UInt16(clamping: max(0, port)))
        }
    }

    // MARK: Client activity (best-effort)

    @ViewBuilder
    private var clientActivity: some View {
        if controller.isRunning {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                Text(clientActivityText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientActivityText: String {
        guard let count = controller.clientCount else { return "Listening" }
        return count == 1 ? "1 client connected" : "\(count) clients connected"
    }

    // MARK: TCC permission checklist (research §C1)

    private var tccChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))
            Text("Needed for the GUI-video & remote-input features.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(TCC.rows) { row in
                TCCRowView(row: row, refreshTick: tccRefreshTick)
            }
        }
    }

    // MARK: Quit

    private var quitButton: some View {
        Button(role: .destructive) {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit Rwork Host")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
    }
}

/// One checklist row: a live status dot, the title + rationale, and an "Enable…" deep-link
/// button (hidden once granted). The `refreshTick` input forces a re-render — and therefore a
/// fresh `row.isGranted()` preflight — whenever the parent bumps it.
private struct TCCRowView: View {
    let row: TCCRow
    let refreshTick: Int

    var body: some View {
        // Re-preflight on every render (grants go stale; never cache). `refreshTick` is read so
        // SwiftUI invalidates this view when the parent bumps it.
        let granted = withRefresh(refreshTick) { row.isGranted() }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                Text(row.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !granted && row.requiresRelaunch {
                    Text("Quit & Reopen Rwork Host after granting.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !granted {
                Button("Enable…") {
                    NSWorkspace.shared.open(row.settingsURL)
                }
                .controlSize(.small)
            }
        }
    }

    /// Reads `tick` (so the view depends on it) and returns the freshly-computed value.
    private func withRefresh<T>(_ tick: Int, _ body: () -> T) -> T {
        _ = tick
        return body()
    }
}
