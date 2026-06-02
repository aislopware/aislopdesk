#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneChromeView (per-pane header + focus ring)

/// The per-pane chrome that wraps every leaf's content (docs/22 §3, §7): a thin header bar
/// (kind glyph + title + connection-status dot + split-H / split-V / zoom / close buttons) over the
/// content, plus a focus ring when the pane is focused.
///
/// All actions funnel through the store's pure mutations (`split`, `toggleZoom`, `closePane`), so the
/// chrome holds no state of its own — it is a thin, declarative skin. Buttons are monochrome SF
/// Symbols in the native toolbar idiom; the focus ring is a 1.5pt accent stroke that appears only on
/// the focused pane so the user always knows where keyboard input goes.
struct PaneChromeView<Content: View>: View {
    /// The leaf this chrome wraps.
    let id: PaneID
    /// The leaf's intent (kind + title) — drives the header glyph and label.
    let spec: PaneSpec
    /// The live session, for the header status dot (read-only).
    let handle: (any PaneSessionHandle)?
    /// Whether this pane is focused (shows the ring + a brighter header).
    let isFocused: Bool
    /// Whether the tab is currently zoomed on THIS pane (flips the zoom button's glyph/intent).
    let isZoomed: Bool
    /// The store, for the chrome's mutations.
    let store: WorkspaceStore
    /// The wrapped content (the leaf view).
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            // The focus ring: an accent stroke on the focused pane only (docs/22 §3 affordance).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.caption)
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)

            if let dot = statusColor {
                Circle().fill(dot).frame(width: 7, height: 7)
            }

            Text(spec.title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            controls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
    }

    /// The split / zoom / close controls. Compact icon buttons in the native borderless toolbar idiom.
    /// The split affordances are KIND-pickers (docs/22 WF6 DECISIONS): a plain tap splits with a
    /// terminal (the common case); the menu offers Claude Code / Remote so the user chooses the new
    /// pane's KIND before it is created — mirroring the sidebar / detail "New" idiom.
    private var controls: some View {
        HStack(spacing: 2) {
            splitMenu("rectangle.split.2x1", axis: .horizontal, help: "Split right")
            splitMenu("rectangle.split.1x2", axis: .vertical, help: "Split down")
            chromeButton(
                isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: isZoomed ? "Restore" : "Zoom"
            ) {
                store.focus(id)        // zoom acts on the focused pane — ensure it's this one first
                store.toggleZoom()
            }
            chromeButton("xmark", help: "Close pane", role: .destructive) {
                store.closePane(id)
            }
        }
        .font(.caption)
    }

    /// A split affordance that picks the new pane's KIND: tap to split with a terminal, or open the
    /// menu to split with a Claude Code / Remote pane along `axis` (docs/22 WF6 DECISIONS).
    @ViewBuilder
    private func splitMenu(_ systemImage: String, axis: SplitAxis, help: String) -> some View {
        Menu {
            Button {
                store.split(id, axis: axis, kind: .terminal)
            } label: {
                Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
            }
            Button {
                store.split(id, axis: axis, kind: .claudeCode)
            } label: {
                Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
            }
            Button {
                store.split(id, axis: axis, kind: .remoteGUI)
            } label: {
                Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
            }
        } label: {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        } primaryAction: {
            store.split(id, axis: axis, kind: .terminal)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(help)
    }

    @ViewBuilder
    private func chromeButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Status dot

    /// The header status dot colour, mirrored from the live connection (production handle only).
    private var statusColor: Color? {
        switch (handle as? LivePaneSession)?.connection?.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .disconnected: return .secondary
        case .none: return nil      // video pane / faked handle — no PATH-1 connection
        }
    }
}
#endif
