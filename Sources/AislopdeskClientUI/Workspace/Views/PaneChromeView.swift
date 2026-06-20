// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneChromeView (chrome-less on the tree shell; compact header on iOS carousel)

/// Wraps every leaf's content. The Muxy redesign makes the IDE tree shell CHROME-LESS: no per-pane
/// header, no border stroke, no focus ring, no opacity dim — focus lives on the TAB (its bottom accent
/// line), not the pane. The focused pane is full-opacity and seamless with its split siblings; the
/// bottom ``PaneStatusBar`` surfaces the focused pane's connection / title / RTT / agent state.
///
/// The iOS compact carousel keeps a slim header (``showsHeader == true``): a single carousel pane has no
/// tab strip, so its header is the only place to surface the title + split/zoom/close controls. All
/// actions funnel through the store's pure mutations, so the chrome holds no state of its own.
struct PaneChromeView<Content: View>: View {
    /// The leaf this chrome wraps.
    let id: PaneID
    /// The leaf's intent (kind + title) — drives the header glyph and label.
    let spec: PaneSpec
    /// The live session, for the header status dot (read-only).
    let handle: (any PaneSessionHandle)?
    /// Whether this pane is focused. On the chrome-less tree shell this is IGNORED for visuals (focus is
    /// shown on the tab); it still tints the compact carousel header.
    let isFocused: Bool
    /// Whether the tab is currently maximized on THIS pane (flips the maximize button's glyph/intent).
    let isZoomed: Bool
    /// The store, for the chrome's mutations.
    let store: WorkspaceStore
    /// Whether to draw the per-pane header bar. The Muxy IDE tree shell (``SplitTreeView``) sets this
    /// FALSE — Muxy has NO per-pane header (the tab strip is the only header; focus is the tab's accent
    /// line). The iOS compact carousel keeps it TRUE.
    var showsHeader: Bool = true
    /// The wrapped content (the leaf view).
    @ViewBuilder let content: () -> Content

    var body: some View {
        if showsHeader {
            // The compact carousel keeps a slim header over the content (no tab strip to carry focus).
            VStack(spacing: 0) {
                header
                Divider()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(AislopdeskTheme.bg)
        } else {
            // The IDE tree shell: CHROME-LESS pane body — no per-pane header, no focus ring, no opacity
            // dim (focus is shown by the tab's bottom accent line). The Warp "floating card" look:
            // 8pt continuous rounded corners + a soft 1px fg@10% border so each pane reads as a
            // raised card floating on the `bg` gutter that SplitTreeView's half-gap padding exposes.
            //
            // BORDER: uniform across ALL panes (no dim, no conditional focus tint) — the invariant from
            // the design spec. The accent-line on the active TAB is the focus cue; the card border is
            // purely structural chrome.
            //
            // METAL CLIPPING: SwiftUI `.clipShape` clips the SwiftUI render tree but NOT the hosted
            // AppKit/UIKit sublayer that libghostty installs (the IOSurfaceLayer — see
            // GhosttyLayerBackedView). The corner radius for the live Metal surface is applied directly
            // on the hosted layer in GhosttyLayerBackedView.layout() via `layer?.cornerRadius` +
            // `layer?.masksToBounds = true`. This view supplies the visual card chrome only; the renderer
            // is responsible for its own layer clipping.
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AislopdeskTheme.bg)
                .clipShape(
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous)
                        .strokeBorder(AislopdeskTheme.border, lineWidth: 1),
                )
        }
    }

    // MARK: Header (compact carousel only)

    private var header: some View {
        HStack(spacing: AislopdeskTheme.Space.m) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.system(size: UIMetrics.fontCaption))
                .foregroundStyle(isFocused ? AislopdeskTheme.accent : AislopdeskTheme.fgMuted)
                .accessibilityHidden(true) // decorative — the title Text carries the row's label

            let status = connectionStatus
            PaneStatusDot(status: status, running: isRunning)

            // W5: the per-leaf Claude/agent status dot (hidden when `.none` — the common case until W10/W11).
            AgentStatusDot(status: store.agentStatus(for: id))

            Text(displayTitle)
                .font(.system(size: UIMetrics.fontCaption, design: .monospaced))
                .foregroundStyle(isFocused ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            // Reconnecting/unreachable detail beside the dot so "connecting forever" reads as a clear
            // "Reconnecting (n) — retrying in Ns" / "Unreachable" (surfacing the WF3 timeout + backoff).
            statusDetail(status)

            // Live RTT badge (docs/26 D10): the smoothed ping/pong RTT beside the title while
            // connected. Hidden until the first sample; amber past 100ms (the "this will feel laggy" line).
            if case .connected = status.phase, let ms = latencyMS {
                Text(ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms")
                    .font(.system(size: UIMetrics.fontMicro).monospacedDigit())
                    .foregroundStyle(ms > 100 ? AnyShapeStyle(.orange) : AnyShapeStyle(AislopdeskTheme.fgDim))
                    .lineLimit(1)
                    .accessibilityLabel(Text("latency \(Int(ms.rounded())) milliseconds"))
                    .help("Smoothed round-trip time to the host (3s ping)")
            }

            // A "running…" affordance while an OSC 133 command executes on this pane.
            if isRunning {
                Text("running…")
                    .font(.system(size: UIMetrics.fontMicro))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityLabel(Text("command running"))
            }

            // WB2: the Warp-style block STATUS CHIP — the latest command's status, tappable to open the
            // Command Navigator. Hidden until the first block.
            blockStatusChip

            Spacer(minLength: AislopdeskTheme.Space.m)

            controls
        }
        .padding(.horizontal, AislopdeskTheme.Space.m)
        .padding(.vertical, AislopdeskTheme.Space.s)
        #if os(macOS)
            // BUG-2 ("ở cạnh trên/header vẫn bị"): the header bar is hit-OPAQUE (it carries the
            // tap-to-focus gesture over the whole bar), so a scroll over it was SWALLOWED instead of
            // panning. Fix with a `ScrollPanForwarder` (a real NSView that forwards scroll →
            // `store.scrollPan`) that ALSO carries the tap.
            .background {
                ScrollPanForwarder(store: store)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { focusThisLeaf() })
            }
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
        #else
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            .contentShape(Rectangle())
            // A plain TAP on the title bar focuses the pane.
            .simultaneousGesture(TapGesture().onEnded { focusThisLeaf() })
        #endif
    }

    // MARK: WB2 block status chip

    /// The pane's latest Warp-style block (the current/last command), or `nil` until one has run.
    private var latestBlock: CommandBlock? { PanePresentation.latestBlock(handle) }

    /// The block status chip: the latest command's status icon + a compact "exit N · 1.2s" label, tappable
    /// to open the Command Navigator. Hidden until the first block lands (and quiet while running — the
    /// existing "running…" cue already covers that).
    @ViewBuilder
    private var blockStatusChip: some View {
        if let block = latestBlock, block.complete {
            Button { PanePresentation.openBlockNavigator(handle) } label: {
                HStack(spacing: 3) {
                    Image(systemName: block.statusSymbol)
                        .foregroundStyle(blockTint(block))
                    Text(blockChipLabel(block))
                        .font(.system(size: UIMetrics.fontMicro).monospacedDigit())
                        .foregroundStyle(AislopdeskTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            .help("Open Command Navigator (⌃⌘O)")
            .accessibilityLabel(Text("Last command \(block.statusLabel)"))
        }
    }

    /// The chip's compact label: the exit badge plus a duration when known ("exit 0 · 1.2s").
    private func blockChipLabel(_ block: CommandBlock) -> String {
        if let duration = block.durationLabel {
            return "\(block.statusLabel) · \(duration)"
        }
        return block.statusLabel
    }

    /// The chip's status tint (green succeeded / red failed; the running case is filtered out above).
    private func blockTint(_ block: CommandBlock) -> Color {
        switch block.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    /// Focuses this leaf in whichever live model is active (W5): the tree's active pane on the IDE shell,
    /// the canvas focus on the retained-but-dead path.
    private func focusThisLeaf() {
        switch store.liveModel {
        case .tree: store.focusPaneTree(id)
        case .canvas: store.focus(id)
        }
    }

    /// The per-leaf controls. On the LIVE tree shell it is the slim coding-IDE split-leaf header —
    /// split-right (⌘D), split-down (⌘⇧D), zoom, close — all funneling through the store's tree ops. On
    /// the retained-but-dead canvas path it keeps the old add-KIND-picker + maximize + close.
    @ViewBuilder
    private var controls: some View {
        switch store.liveModel {
        case .tree:
            HStack(spacing: 2) {
                chromeButton("rectangle.split.2x1", help: "Split right (⌘D)") {
                    store.focusPaneTree(id)
                    store.splitPaneTree(id, axis: .horizontal, kind: SettingsKey.defaultPaneKind)
                }
                chromeButton("rectangle.split.1x2", help: "Split down (⌘⇧D)") {
                    store.focusPaneTree(id)
                    store.splitPaneTree(id, axis: .vertical, kind: SettingsKey.defaultPaneKind)
                }
                chromeButton(
                    isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Restore" : "Zoom",
                ) {
                    store.focusPaneTree(id)
                    store.toggleZoomTree()
                }
                chromeButton("xmark", help: "Close pane", role: .destructive) {
                    // ITEM A3: route through the busy-shell guard so the chrome close honours the same
                    // confirmation ⌘W / the canvas path do — not a raw close.
                    store.requestClosePaneTree(id)
                }
            }
            .font(.system(size: UIMetrics.fontCaption))
        case .canvas:
            HStack(spacing: 2) {
                addMenu
                chromeButton(
                    isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: isZoomed ? "Restore" : "Maximize",
                ) {
                    store.focus(id) // maximize acts on the focused pane — ensure it's this one first
                    store.toggleZoom()
                }
                chromeButton(
                    "xmark",
                    help: store.isOnlyLeaf(id) ? "Close last pane" : "Close pane",
                    role: .destructive,
                ) {
                    store.requestClosePane(id)
                }
            }
            .font(.system(size: UIMetrics.fontCaption))
        }
    }

    /// The "add pane" KIND-picker: tap to add a terminal pane to the canvas, or open the menu to add a
    /// Claude Code / Remote pane.
    @ViewBuilder
    private var addMenu: some View {
        Menu {
            Button {
                store.addPane(kind: .terminal)
            } label: {
                Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
            }
            Button {
                store.addPane(kind: .remoteGUI)
            } label: {
                Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: UIMetrics.resizeHandleHitArea, height: UIMetrics.resizeHandleHitArea)
        } primaryAction: {
            store.addPane(kind: .terminal)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
            .menuStyle(.borderlessButton)
        #endif
            .fixedSize()
            .foregroundStyle(AislopdeskTheme.fgMuted)
            .help("Add pane")
            .accessibilityLabel("Add pane")
    }

    private func chromeButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: UIMetrics.resizeHandleHitArea, height: UIMetrics.resizeHandleHitArea)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AislopdeskTheme.fgMuted)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Status dot

    /// The header status presentation (the shared ``PanePresentation`` derivation).
    private var connectionStatus: PaneConnectionStatus { PanePresentation.connectionStatus(handle) }

    /// Whether an OSC 133 command is currently executing in this pane's shell.
    private var isRunning: Bool { PanePresentation.isRunning(handle) }

    /// The smoothed app-layer RTT for the latency badge (`nil` until the first ping/pong completes).
    private var latencyMS: Double? { PanePresentation.latencyMS(handle) }

    /// The header label: the LIVE OSC 0/2 terminal title when set, else `spec.title`.
    private var displayTitle: String { PanePresentation.displayTitle(handle, spec: spec) }

    /// The compact status detail shown beside the title for the in-flight / terminal states. For a
    /// reconnecting pane with a known next-retry instant it ticks a live "retrying in Ns" countdown via
    /// a `TimelineView`; otherwise it shows the static label. Hidden for the steady connected/idle states.
    @ViewBuilder
    private func statusDetail(_ status: PaneConnectionStatus) -> some View {
        switch status.phase {
        case .reconnecting:
            if let nextRetry = status.nextRetry {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(reconnectLabel(status, now: context.date, nextRetry: nextRetry))
                        .font(.system(size: UIMetrics.fontMicro))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else {
                Text(status.label)
                    .font(.system(size: UIMetrics.fontMicro))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .connecting:
            // An initial dial can block on the dead-host handshake/timeout (~10s); surface "Connecting…"
            // beside the title — neutral (muted) since it is not yet an error.
            Text(status.label)
                .font(.system(size: UIMetrics.fontMicro))
                .foregroundStyle(AislopdeskTheme.fgMuted)
                .lineLimit(1)
        case .unreachable,
             .failed:
            // Show the CONCRETE reason ("Failed: timed out") inline, not the bare word "Failed".
            Text(status.detailedLabel)
                .font(.system(size: UIMetrics.fontMicro))
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
