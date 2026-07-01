// ConnectionInfoSection — the sidebar's connection status, reseated as a WHISPER STATUS LINE pinned at the
// bottom of the navigator (Zed/Linear window-chrome, NOT a bordered card). No box, no fill: a single top
// hairline separates it from the tab list, then one full-bleed line — a leading state-coloured dot, the host
// in muted secondary text, and the live telemetry ("9 ms · 30 fps") in tertiary monospaced digits flushed to
// the RIGHT edge. When not connected the right slot shows the status word ("Connecting…", "Unreachable") and,
// in a give-up state, a Retry. The whole line taps through to the Connect-to-Host editor. Reads
// `connection.status` (an `@Observable`) so it stays live; `pingMS` / `fps` are resolved by the parent (ping
// = the active pane's RTT or any live pane's; fps for a live video pane only).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct ConnectionInfoSection: View {
    @Bindable var connection: AppConnection
    /// The smoothed RTT (ms) to show, or `nil` when unknown. Resolved by the parent — the ACTIVE pane's
    /// per-channel `latencyMS`, falling back to any live pane's (every pane pings the SAME host) so the ping
    /// stays shown even when the active pane is a GUI/video window (which has no terminal-channel ping).
    var pingMS: Double?
    /// The active VIDEO pane's host-announced stream cadence (frames/sec), or `nil` when the active pane is a
    /// terminal (no fps) / the cadence has not yet been announced.
    var fps: Int?
    /// Opens the Connect-to-Host editor (pre-seeded with the current host/port).
    var onConnect: () -> Void = {}

    private var status: ConnectionStatus { connection.status }
    private var host: String { connection.target.host }
    private var isConnected: Bool { if case .connected = status { true } else { false } }

    /// The live telemetry segments — ping (when known) then fps (when a live video pane).
    private var metrics: [String] {
        var out: [String] = []
        if let pingMS { out.append("\(Int(pingMS.rounded())) ms") }
        if let fps { out.append("\(fps) fps") }
        return out
    }

    /// The RIGHT-flushed summary: live metrics ("9 ms · 30 fps", tertiary mono) when connected, else the
    /// status word ("Connecting…", "Unreachable", secondary) — the dropped-"Connected" rule: a green dot + a
    /// ping already say it. `nil` ⇒ connected with no sample yet (dot + host alone read as connected).
    private var trailing: (text: String, isMetric: Bool)? {
        if isConnected {
            let m = metrics
            return m.isEmpty ? nil : (m.joined(separator: " · "), true)
        }
        return (StatusPresentation.connectionLabel(status), false)
    }

    var body: some View {
        VStack(spacing: 0) {
            // One hairline seats the line as window chrome (no card border / fill).
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)

            HStack(spacing: Slate.Metric.space2) {
                // The dot + host + right-flushed summary is the tap target → the Connect-to-Host editor.
                Button(action: onConnect) {
                    HStack(spacing: Slate.Metric.space2) {
                        SlateStatusDot(
                            color: StatusPresentation.connectionColor(status),
                            glowKey: StatusPresentation.connectionLabel(status),
                        )
                        Text(host)
                            .font(.system(size: Slate.Typeface.base))
                            .foregroundStyle(Slate.Text.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Slate.Metric.space2)
                        if let trailing {
                            Text(trailing.text)
                                .font(.system(size: Slate.Typeface.footnote).monospacedDigit())
                                .foregroundStyle(trailing.isMetric ? Slate.Text.tertiary : Slate.Text.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(StatusPresentation.connectionHelp(host: host, status: status))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(StatusPresentation.connectionHelp(host: host, status: status))

                // Give-up state (failed / unreachable): a one-tap Retry at the far right.
                if StatusPresentation.showsRetry(status) {
                    Button { Task { await connection.retry() } } label: {
                        Image(systemSymbol: .arrowClockwise)
                            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                            .foregroundStyle(Slate.Text.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Retry connecting to \(host)")
                    .accessibilityLabel("Retry connecting to \(host)")
                }
            }
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, Slate.Metric.space2)
        }
    }
}
#endif
