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
                .accessibilityHidden(true)   // decorative — the title Text carries the row's label

            let status = connectionStatus
            PaneStatusDot(status: status, running: isRunning)

            Text(displayTitle)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Reconnecting/unreachable detail beside the dot so "connecting forever" reads as a clear
            // "Reconnecting (n) — retrying in Ns" / "Unreachable" (surfacing the WF3 timeout + backoff).
            statusDetail(status)

            // A "running…" affordance while an OSC 133 command executes on this pane — the iconic
            // modern-terminal activity cue, beside the title. Hidden at the idle prompt.
            if isRunning {
                Text("running…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityLabel(Text("command running"))
            }

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
            chromeButton("xmark", help: store.isOnlyLeaf(id) ? "Close tab" : "Close pane", role: .destructive) {
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
        .accessibilityLabel(help)
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
        .accessibilityLabel(help)
    }

    // MARK: Status dot

    /// The header status presentation, derived once from the live connection (production handle only).
    /// A `.remoteGUI` / faked handle has no PATH-1 connection ⇒ `.none` ⇒ no dot.
    private var connectionStatus: PaneConnectionStatus {
        PaneConnectionStatus.from((handle as? LivePaneSession)?.connection?.status)
    }

    /// Whether an OSC 133 command is currently executing in this pane's shell (production handle
    /// only). Drives the amber running ring on the dot + the "running…" header label. A faked /
    /// non-terminal handle reports idle.
    private var isRunning: Bool {
        (handle as? LivePaneSession)?.terminalModel?.shellActivity == .running
    }

    /// The header label: prefer the LIVE OSC 0/2 terminal title (the shell's cwd / running command)
    /// when the shell has set one, falling back to the static `spec.title`. Without this, split
    /// same-kind panes all read the generic "Terminal" and are indistinguishable in a multi-pane tab
    /// (and in the Cmd-K pane-jump list). Reading the `@Observable` model's `title` here re-renders the
    /// header when the shell changes it. Empty/whitespace titles fall back so a pane is never blank.
    private var displayTitle: String {
        if let live = (handle as? LivePaneSession)?.terminalModel?.title,
           !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return live
        }
        return spec.title
    }

    /// The compact status detail shown beside the title for the in-flight / terminal states. For a
    /// reconnecting pane with a known next-retry instant it ticks a live "retrying in Ns" countdown via
    /// a `TimelineView` (refreshed once a second, no store mutation); otherwise it shows the static
    /// label. Hidden entirely for the steady connected/idle states so the header stays clean.
    @ViewBuilder
    private func statusDetail(_ status: PaneConnectionStatus) -> some View {
        switch status.phase {
        case .reconnecting:
            if let nextRetry = status.nextRetry {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(reconnectLabel(status, now: context.date, nextRetry: nextRetry))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else {
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .connecting:
            // An initial dial can block on the dead-host handshake/timeout (~10s); surface a
            // "Connecting…" cue beside the title — not just the pulsing dot — so the wait reads as
            // in-flight, not frozen. Neutral (secondary) since it is not yet an error.
            Text(status.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .unreachable, .failed:
            // Show the CONCRETE reason ("Failed: timed out") inline, not the bare word "Failed" —
            // the reason was previously reachable only via the 7pt status-dot hover tooltip. The
            // full text stays in `.help` for the truncated case. (`.unreachable` carries no message,
            // so `detailedLabel` is just "Unreachable" there — still correct.)
            Text(status.detailedLabel)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.detailedLabel)
        default:
            EmptyView()
        }
    }

    /// "Reconnecting (n) — retrying in Ns" once a countdown is known; clamps the remaining seconds at 0
    /// and collapses to "Reconnecting (n)…" when the deadline has passed (the attempt is firing now).
    private func reconnectLabel(_ status: PaneConnectionStatus, now: Date, nextRetry: Date) -> String {
        let remaining = Int(nextRetry.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return status.label }
        return "\(status.label) retrying in \(remaining)s"
    }
}
#endif
