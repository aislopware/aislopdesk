// AgentInputFooterView — the otty "Claude bottom bar" chip strip (E13 / WI-4). Sits at the bottom of a
// terminal leaf WHENEVER the pane hosts a detected agent (`claudeStatus != .none`); mounted by
// ``TerminalLeafView``. The view is DUMB: every pill emits one ``AgentInputFooterAction`` through the
// injected ``AgentInputFooterCoordinator/handle(_:)`` — the single dispatch site that routes each intent to
// the real engine (PreferencesStore / InputBarModel / FileExplorerModel / the parent-supplied settings +
// remote-control hooks). No engine logic lives here (docs/30 §"Claude bottom bar").
//
// Anatomy (top → bottom), matching docs/30-ui-architecture.md:
//   [ green "Enable … notifications" suggestion banner — shown only while `showsNotificationChip` (W4) ]
//   [ file-explorer panel — revealed while the "File explorer" pill is toggled on (W2)                 ]
//   [ chip strip — "+" add-context · "/remote-control" · "File explorer" · "Rich Input" · Settings     ]
//
// `Otty.*` tokens ONLY (raw font / radius / colour literals fail `scripts/check-ds-leaks.sh`). Pure SwiftUI
// + SFSafeSymbols — no libghostty / Metal / AppKit, so the file compiles on iOS too (the gate runs
// `bash scripts/check-ios.sh`). The coordinator is `@Observable`, so reading its derived view-state in
// `body` (`showsNotificationChip` / `richInputActive` / `fileExplorerActive` / the file listing) tracks
// reactively — the strip re-renders on each toggle without an explicit `@Bindable`.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

struct AgentInputFooterView: View {
    /// The single per-pane footer coordinator (built + wired by ``TerminalLeafView``). All pill taps route
    /// through ``AgentInputFooterCoordinator/handle(_:)``; the derived `*Active` reads drive the toggle state.
    let coordinator: AgentInputFooterCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // W4: the green CTA banner — only while not dismissed / not already enabled (Warp's "hide once a
            // plugin connects or the user dismisses it" rule, resolved by the PreferencesStore-backed gate).
            if coordinator.showsNotificationChip {
                FooterNotificationBanner(
                    agentName: coordinator.agentName,
                    onEnable: { coordinator.handle(.installNotifications) },
                    onDismiss: { coordinator.handle(.dismissNotifications) },
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // W2: the file panel reflows in above the chips while the explorer is toggled on. Picking a file
            // emits `.selectFile(path)` → the coordinator's `onSelectFile` (composer insert).
            if coordinator.fileExplorerActive {
                FooterFileExplorerPanel(
                    model: coordinator.fileExplorer,
                    onSelect: { coordinator.handle(.selectFile($0)) },
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            chipStrip
        }
        .background(Otty.Surface.element)
        // A top hairline detaches the footer from the terminal surface (the PromptQueueStrip idiom).
        .overlay(alignment: .top) {
            Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
        }
        .animation(Otty.Anim.reveal, value: coordinator.showsNotificationChip)
        .animation(Otty.Anim.reveal, value: coordinator.fileExplorerActive)
    }

    /// The action-pill row — horizontally scrollable so a narrow pane never clips a pill (queue-strip idiom).
    /// Order mirrors docs/30: "+" add-context · "/remote-control" · "File explorer" · "Rich Input" · Settings.
    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Otty.Metric.space2) {
                // "+" add-context — toggles the file explorer to attach a file (docs/30: "toggles the file
                // explorer"). Wired by the leaf via `onAddContext`; never a dead stub.
                FooterPill(symbol: .plus, help: "Add context") {
                    coordinator.handle(.addContext)
                }
                // "/remote-control" — opens the remote-window picker (W1, via the overlay coordinator).
                FooterPill(symbol: .macwindow, label: "/remote-control", help: "Share a host window") {
                    coordinator.handle(.startRemoteControl)
                }
                // "File explorer" — toggles the per-pane file panel (W2). Active = panel open.
                FooterPill(
                    symbol: .folder,
                    label: "File explorer",
                    isActive: coordinator.fileExplorerActive,
                    help: "Browse the working directory",
                ) {
                    coordinator.handle(.toggleFileExplorer)
                }
                // "Rich Input" — toggles multi-line rich-input mode (W3). Active = rich mode on.
                FooterPill(
                    symbol: .pencil,
                    label: "Rich Input",
                    isActive: coordinator.richInputActive,
                    help: "Multi-line rich input",
                ) {
                    coordinator.handle(.toggleRichInput)
                }
                // Settings — open the Agents settings section (routes through the overlay coordinator).
                FooterPill(symbol: .gearshape, label: "Settings", help: "Agent settings") {
                    coordinator.handle(.openAgentSettings)
                }
            }
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, Otty.Metric.space2)
        }
    }
}

// MARK: - Pills

/// One footer action pill — an icon + optional label in a compact rounded chip. An ACTIVE pill (toggle on)
/// fills with the accent wash + accent text/border; an idle pill is the card surface with a hover plate.
private struct FooterPill: View {
    let symbol: SFSymbol
    var label: String?
    var isActive: Bool = false
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    // Platform hit-target sizing — iOS uses a larger finger target (the PromptQueueStrip mapping note).
    #if os(iOS)
    private let pillHeight: CGFloat = 34
    #else
    private let pillHeight: CGFloat = 26
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space1) {
                Image(systemSymbol: symbol)
                    .font(.system(size: Otty.Typeface.small, weight: .medium))
                if let label {
                    Text(label)
                        .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Otty.State.accent : Otty.Text.secondary)
            .padding(.horizontal, Otty.Metric.space2)
            .frame(height: pillHeight)
            .background(pillFill, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .strokeBorder(pillBorder, lineWidth: Otty.Metric.hairline),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .ottyHelp(help)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
    }

    private var pillFill: Color {
        if isActive { return Otty.State.accentMuted }
        return hovering ? Otty.State.hover : Otty.Surface.card
    }

    private var pillBorder: Color {
        isActive ? Otty.State.accent.opacity(0.5) : Otty.Line.subtle
    }
}

/// The green "Enable … notifications" suggestion banner (W4). A full-width tinted row: a bell + the
/// CTA label (tap → enable), then a trailing ✕ (dismiss). Both halves route through the coordinator so the
/// PreferencesStore records the per-agent flag (and `enable` re-opens the global OSC delivery gate).
private struct FooterNotificationBanner: View {
    let agentName: String
    let onEnable: () -> Void
    let onDismiss: () -> Void

    @State private var dismissHover = false

    var body: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemSymbol: .bell)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Otty.Status.ok)
            Button(action: onEnable) {
                Text("Enable \(agentName) notifications")
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .ottyHelp("Notify when \(agentName) finishes or needs input")
            Spacer(minLength: Otty.Metric.space2)
            Button(action: onDismiss) {
                Image(systemSymbol: .xmark)
                    .font(.system(size: Otty.Typeface.small, weight: .medium))
                    .foregroundStyle(Otty.Text.secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        dismissHover ? Otty.State.selected : .clear,
                        in: .rect(cornerRadius: Otty.Metric.radiusSmall),
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { dismissHover = $0 }
            .ottyHelp("Dismiss")
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
        .background(Otty.Status.ok.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
        }
    }
}

/// The per-pane file panel (W2) — a compact listing of the pane's working directory revealed under the
/// chip strip when the "File explorer" pill is toggled on. Tapping a file emits its absolute path via
/// `onSelect` (→ composer insert). The four ``FileListing`` states each render an honest, non-blank row:
/// a real local directory lists; an unknown cwd / a remote pane / an unreadable path each say why.
private struct FooterFileExplorerPanel: View {
    let model: FileExplorerModel
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
            content
        }
        .frame(maxHeight: 180)
        .background(Otty.Surface.content)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
        }
    }

    private var header: some View {
        HStack(spacing: Otty.Metric.space1) {
            Image(systemSymbol: .folder)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.icon)
            Text(model.cwd ?? "Working directory")
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Otty.Metric.space3)
        .padding(.vertical, Otty.Metric.space2)
    }

    @ViewBuilder private var content: some View {
        switch model.listing {
        case let .entries(entries):
            if entries.isEmpty {
                note("Empty directory")
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        case .unknownCwd:
            note("No working directory yet")
        case .remoteUnavailable:
            note("File browsing isn't available for remote panes yet")
        case let .unreadable(path):
            note("Can't read \(path)")
        }
    }

    /// One file/dir row — a folder/doc icon + name; tapping emits its absolute path. A directory resolves to
    /// its own path too (the same insert seam), so a future drill-down can replace this without a wire change.
    private func row(_ entry: FileEntry) -> some View {
        Button { onSelect(absolutePath(entry.name)) } label: {
            HStack(spacing: Otty.Metric.space1) {
                Image(systemSymbol: entry.isDirectory ? .folder : .doc)
                    .font(.system(size: Otty.Typeface.small, weight: .regular))
                    .foregroundStyle(Otty.Text.icon)
                Text(entry.name)
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, Otty.Metric.space1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Otty.Typeface.footnote))
            .foregroundStyle(Otty.Text.tertiary)
            .padding(.horizontal, Otty.Metric.space3)
            .padding(.vertical, Otty.Metric.space2)
    }

    /// Join the panel's cwd (tilde-expanded via the shared ``FilePath``) with the entry name → an absolute
    /// path. A `nil` cwd falls back to the bare name (still a usable insert; never a crash).
    private func absolutePath(_ name: String) -> String {
        guard let cwd = model.cwd, !cwd.isEmpty else { return name }
        let base = URL(fileURLWithPath: FilePath.expandingTilde(cwd), isDirectory: true)
        return base.appendingPathComponent(name).path
    }
}
#endif
