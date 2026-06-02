#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneLeafView (WF4 placeholder — WF5 replaces only the BODY)

/// The content of a single leaf pane.
///
/// **This is a WF4 placeholder.** Its SIGNATURE is final and load-bearing — WF5 will replace ONLY
/// the `body` to wire the real seams per kind (docs/22 §7):
/// - `.terminal`   → `TerminalScreenView(model: handle.terminalModel)`
/// - `.claudeCode` → the same terminal + `InspectorPanel(model:client:)` composite
/// - `.remoteGUI`  → `RemoteWindowPanel(model: handle.remoteWindow!, showCloseButton: false)`
///
/// Until then it renders a clean, kind-aware placeholder (icon + title + kind label + connection
/// status) so the shell lays out and the identity/zoom/focus plumbing is exercised end to end. The
/// real content is deliberately NOT wired here — WF4's job is the shell, not the seams.
///
/// The handle is `any PaneSessionHandle` (the store-level test seam, docs/22 §0). To surface a live
/// connection status we down-cast to the production ``LivePaneSession`` — a view-only read, never a
/// mutation; a faked handle simply shows no status, which is correct for the placeholder.
struct PaneLeafView: View {
    /// The live session backing this leaf, or `nil` if the registry has not materialized it yet.
    let handle: (any PaneSessionHandle)?
    /// The pure intent for this leaf (kind + title + endpoint).
    let spec: PaneSpec
    /// Whether this leaf is the focused pane of its tab (drives the chrome's focus ring, passed
    /// through for content that wants to dim when unfocused).
    let isFocused: Bool

    var body: some View {
        ZStack {
            // A subtle, kind-tinted backdrop so adjacent panes read as distinct surfaces.
            Rectangle()
                .fill(.background)

            VStack(spacing: 10) {
                Image(systemName: kindIcon)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)

                Text(spec.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(kindLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if let endpoint = endpointDescription {
                    Text(endpoint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                connectionStatusBadge
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(isFocused ? 1 : 0.92)
    }

    // MARK: Kind presentation

    /// The SF Symbol for this pane's kind (mirrors the sidebar glyphs).
    private var kindIcon: String { Self.icon(for: spec.kind) }

    /// A human label for the kind, shown under the title.
    private var kindLabel: String {
        switch spec.kind {
        case .terminal:   return "terminal"
        case .claudeCode: return "claude"
        case .remoteGUI:  return "remote"
        }
    }

    /// The endpoint string (host:port for terminals, host + window for remote), or `nil` when the
    /// spec is unconfigured.
    private var endpointDescription: String? {
        if let e = spec.endpoint { return "\(e.host):\(e.port)" }
        if let v = spec.video { return "\(v.host) · \(v.title)" }
        return nil
    }

    // MARK: Connection status (read-only down-cast — placeholder only)

    @ViewBuilder
    private var connectionStatusBadge: some View {
        if let status = liveStatusLabel {
            HStack(spacing: 5) {
                Circle().fill(liveStatusColor).frame(width: 7, height: 7)
                Text(status)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else {
            Text("not connected")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// The connection status label, if this handle is a production ``LivePaneSession`` with a
    /// connection. `nil` for video panes / faked handles (no PATH-1 connection).
    private var liveStatusLabel: String? {
        (handle as? LivePaneSession)?.connection?.status.label
    }

    /// The colour for ``liveStatusLabel`` (mirrors `ConnectionView`'s badge palette).
    private var liveStatusColor: Color {
        switch (handle as? LivePaneSession)?.connection?.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected, .none: return .secondary
        }
    }

    // MARK: Shared kind glyph (reused by the chrome + sidebar)

    /// The canonical SF Symbol for a ``PaneKind`` — one source of truth for the glyph so the leaf,
    /// the chrome header, and the sidebar agree.
    static func icon(for kind: PaneKind) -> String {
        switch kind {
        case .terminal:   return "terminal"
        case .claudeCode: return "sparkles"
        case .remoteGUI:  return "macwindow.on.rectangle"
        }
    }
}
#endif
