// StatusBarStrip — the per-pane bottom status bar (E10 WI-4 / ES-E10-3, ES-E10-4).
//
// A FLAT, ≤20pt horizontal strip pinned along the BOTTOM edge of a terminal leaf (the OPPOSITE edge from the
// E17 top-trailing pills — carryover coexistence: persistent chrome owns opposite edges). otty lists the
// status bar as "planned, not implemented" (`spec/user-interface__status-bar.md`), so this is the spec's own
// inferred-but-conventional terminal pattern: the otty-shorthand cwd on the LEFT, the last-exit badge +
// pane-kind + connection host on the RIGHT, and — while ⌘-hovering a detected link — the FULL resolved path
// on a darker sub-strip in white monospace (`full-path-hover.png`, ES-E10-4).
//
// FLAT by construction: the strip background == the pane background (`Otty.Surface.card`), separated from the
// terminal only by a top hairline — never a floating card. All dimensions/colours come through the `Otty`
// token scale (`scripts/check-ds-leaks.sh`), and the only logic is the PURE ``StatusBarContent`` model
// (headlessly unit-tested) read here; this view is a thin renderer. No libghostty / Metal / VideoToolbox is
// touched (CLAUDE.md rule #6).
//
// VISIBILITY: the LEAF gates whether the strip mounts at all (`!staticMirror && !hideStatusBar`); this view
// is a pure renderer once mounted. The exit badge stays live because it reads the pane model's OBSERVABLE
// ``TerminalViewModel/lastCommand`` directly in `body`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct StatusBarStrip: View {
    /// The pane's terminal model — read for the OBSERVABLE last-exit (`lastCommand`) so the badge updates
    /// reactively as commands finish. `nil` for a not-yet-live pane (the badge then follows the kind only).
    let model: TerminalViewModel?
    /// The host-reported working directory (`PaneSpec.lastKnownCwd`, OSC 7) — truncated to the otty shorthand.
    let cwd: String?
    /// The pane kind (drives the right-edge label + whether an exit badge applies).
    let kind: PaneKind
    /// The app-global connection host (`ConnectionTarget.host`) — empty when not yet connected / unknown.
    let host: String
    /// The resolved absolute path of a ⌘-hovered link (ES-E10-4), or `nil`. Overrides the left field with the
    /// full path on the dark sub-strip (`full-path-hover.png`). Wired by WI-5 (`TerminalViewModel`'s hover
    /// state); `nil` until then, so the strip resting state is correct today.
    let hoverFullPath: String?

    /// The pure status content for the current inputs. Reading ``TerminalViewModel/lastCommand`` here (inside
    /// `body`'s evaluation) registers observation, so a finishing command re-renders the badge.
    private var content: StatusBarContent {
        StatusBarContent.make(
            cwd: cwd,
            lastCommand: model?.lastCommand,
            kind: kind,
            host: host,
            hoverFullPath: hoverFullPath,
        )
    }

    var body: some View {
        let c = content
        HStack(spacing: Otty.Metric.space2) {
            leftField(c)
            Spacer(minLength: Otty.Metric.space2)
            rightField(c)
        }
        .padding(.horizontal, Otty.Metric.space2)
        .frame(height: 20) // ≤20pt: keep the strip out of the terminal's way (status-bar spec recommendation)
        .frame(maxWidth: .infinity)
        .background(Otty.Surface.card) // FLAT: strip background == pane background
        // A single top hairline is the only separation from the terminal content above (otty flat design).
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverLabel(c))
    }

    /// LEFT: the ⌘-hovered FULL path on a dark sub-strip (white monospace), else the otty-shorthand cwd with a
    /// folder glyph and the full path as the tooltip. Empty when nothing is known (renders no left text).
    @ViewBuilder
    private func leftField(_ c: StatusBarContent) -> some View {
        if c.isPathHover {
            Text(c.cwdDisplay)
                .font(.system(size: Otty.Typeface.small, design: .monospaced))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Otty.Metric.space1)
                .padding(.vertical, 1)
                .background(Otty.Surface.element, in: .rect(cornerRadius: Otty.Metric.radiusSmall))
        } else if !c.cwdDisplay.isEmpty {
            HStack(spacing: Otty.Metric.space1) {
                Image(systemSymbol: .folder)
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.tertiary)
                Text(c.cwdDisplay)
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
                    .foregroundStyle(Otty.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .ottyHelp(c.fullCwd)
        }
    }

    /// RIGHT: the OSC 9;4 progress readout, then the last-exit badge, then the pane-kind label, then the host —
    /// all in the muted text tones. Reading ``TerminalViewModel/progress`` here (inside `body`'s evaluation)
    /// registers observation, so a `9;4` update re-renders the readout.
    private func rightField(_ c: StatusBarContent) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            progressReadout(model?.progress)
            exitBadge(c.exit)
            if !c.paneKind.isEmpty {
                Text(c.paneKind)
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
                    .foregroundStyle(Otty.Text.tertiary)
                    .lineLimit(1)
            }
            if !c.host.isEmpty {
                Text(c.host)
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
                    .foregroundStyle(Otty.Text.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The taskbar-style OSC 9;4 progress readout (E14/K1 — `progress-state.md` Behaviors). Renders the built +
    /// tested ``StatusPresentation/progressPresentation(_:)`` so a DETERMINATE `9;4;1;NN` state shows its bar +
    /// "NN%" number CROSS-PLATFORM (not only on the macOS Dock — iOS has no Dock). An indeterminate state shows
    /// a compact spinner; an error / none render nothing here (the tab badge + exit badge carry those). A pure
    /// SwiftUI view — never a capture/video session (CLAUDE.md hang-safety rule #6).
    @ViewBuilder
    private func progressReadout(_ progress: PaneProgress?) -> some View {
        switch StatusPresentation.progressPresentation(progress) {
        case .none,
             .error:
            EmptyView()
        case .spinner:
            ProgressView()
                .controlSize(.mini)
        case let .determinate(fraction, label):
            HStack(spacing: Otty.Metric.space1) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                Text(label)
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
                    .foregroundStyle(Otty.Text.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The last-exit badge: a green check on success, a red cross + code on failure, an indeterminate dot
    /// while no command has finished, nothing for a non-terminal pane. Colours via the theme `Otty.Status`
    /// tokens (the only theme-coupled part — the classification itself lives in the pure model).
    @ViewBuilder
    private func exitBadge(_ exit: StatusBarContent.ExitBadge) -> some View {
        switch exit {
        case .none:
            EmptyView()
        case .running:
            Image(systemSymbol: .circleFill)
                .font(.system(size: Otty.Typeface.small))
                .foregroundStyle(Otty.Text.tertiary)
        case .success:
            Image(systemSymbol: .checkmark)
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.Status.ok)
        case let .failure(code):
            HStack(spacing: Otty.Metric.space1) {
                Image(systemSymbol: .xmark)
                    .font(.system(size: Otty.Typeface.small, weight: .semibold))
                Text("\(code)")
                    .font(.system(size: Otty.Typeface.small, design: .monospaced))
            }
            .foregroundStyle(Otty.Status.err)
        }
    }

    /// A combined VoiceOver label so the strip reads as one element (cwd, exit, kind, host).
    private func voiceOverLabel(_ c: StatusBarContent) -> String {
        var parts: [String] = []
        if !c.cwdDisplay.isEmpty { parts.append(c.isPathHover ? "Path \(c.cwdDisplay)" : "Directory \(c.cwdDisplay)") }
        switch c.exit {
        case .none: break
        case .running: parts.append("running")
        case .success: parts.append("last command succeeded")
        case let .failure(code): parts.append("last command failed, exit \(code)")
        }
        if !c.paneKind.isEmpty { parts.append(c.paneKind) }
        if !c.host.isEmpty { parts.append("on \(c.host)") }
        return parts.joined(separator: ", ")
    }
}
#endif
