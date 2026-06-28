import Foundation

// MARK: - StatusBarModel (E10 WI-4 — the bottom status strip's PURE presentation mapping)

/// The bottom status bar's pure (no-SwiftUI) presentation model: the otty-shorthand cwd, the last-exit
/// badge, the pane-kind label, the connection host, and the ⌘-hover full-path override (ES-E10-4). Kept free
/// of `Otty` / SwiftUI so the ONLY theme-coupled part is the strip view's badge → colour map — the
/// truncation / badge classification / hover precedence are headlessly unit-tested
/// (``StatusBarModelTests``), mirroring the ``OutlinePresentation`` precedent.
///
/// The otty status bar is "planned, not implemented" upstream (`spec/user-interface__status-bar.md`), so the
/// shape is the inferred-but-conventional terminal pattern the spec's own "implementation recommendation"
/// describes: cwd truncated to the last components on the left, exit / kind / host on the right, and the full
/// resolved path surfaced on the left while ⌘-hovering a detected link (`full-path-hover.png`).
public struct StatusBarContent: Equatable, Sendable {
    /// The last-finished command's exit classification — drives the right-edge badge colour/glyph. `none` for
    /// a non-terminal pane (a video / chooser pane has no shell exit concept); `running` until the first
    /// command completes; `success` on exit 0 / no reported code; `failure` carries the non-zero code.
    public enum ExitBadge: Equatable, Sendable {
        /// No exit concept for this pane (a non-`.terminal` kind) — the badge is omitted.
        case none
        /// No completed command yet (the pane is live but nothing has finished) — an indeterminate dot.
        case running
        /// The last command finished with exit 0 (or no reported code) — a green check.
        case success
        /// The last command finished with a non-zero exit code — a red cross + the code.
        case failure(Int32)
    }

    /// The LEFT field text: the otty-shorthand cwd (`…/Workplace/otty`) at rest, OR the full resolved link
    /// path while ⌘-hovering (the hover override wins — ES-E10-4). Empty when no cwd is known and nothing is
    /// hovered (the strip then shows no left text).
    public var cwdDisplay: String
    /// The full (untruncated) path behind ``cwdDisplay`` — the resting cwd, or the hovered path while hovering.
    /// `nil` when unknown. The view uses it as the left field's tooltip so the truncation is never lossy.
    public var fullCwd: String?
    /// `true` when ``cwdDisplay`` is a ⌘-hovered link's full path (not the resting cwd): the view renders it on
    /// the darker sub-strip in white monospace per `full-path-hover.png`, distinct from the resting cwd chip.
    public var isPathHover: Bool
    /// The last-exit classification (right edge).
    public var exit: ExitBadge
    /// The pane-kind label (right edge) — a short human word for the pane's ``PaneKind``.
    public var paneKind: String
    /// The connection host (right edge). Empty when not yet connected / unknown — the view then omits it.
    public var host: String

    public init(
        cwdDisplay: String,
        fullCwd: String?,
        isPathHover: Bool,
        exit: ExitBadge,
        paneKind: String,
        host: String,
    ) {
        self.cwdDisplay = cwdDisplay
        self.fullCwd = fullCwd
        self.isPathHover = isPathHover
        self.exit = exit
        self.paneKind = paneKind
        self.host = host
    }

    /// Build the status content from the live per-pane inputs. PURE: every input is a plain value, so this is
    /// the headlessly-tested core (``StatusBarModelTests``) and the view is a thin renderer over the result.
    ///
    /// - Parameters:
    ///   - cwd: the host-reported working directory (`PaneSpec.lastKnownCwd`, OSC 7), or `nil` if not seen yet.
    ///   - lastCommand: the most-recent finished command's `(exitCode, durationMS)` (``TerminalViewModel``),
    ///     or `nil` if no command has completed in this pane.
    ///   - kind: the pane's ``PaneKind`` — a non-`.terminal` kind has no exit concept (badge `.none`).
    ///   - host: the app-global connection host (`ConnectionTarget.host`), or empty.
    ///   - hoverFullPath: the resolved absolute path of a ⌘-hovered link (ES-E10-4), or `nil`. When present it
    ///     OVERRIDES the left field with the full path (the hover takes precedence over the resting cwd).
    public static func make(
        cwd: String?,
        lastCommand: (exitCode: Int32?, durationMS: UInt32)?,
        kind: PaneKind,
        host: String,
        hoverFullPath: String? = nil,
    ) -> Self {
        let exit = exitBadge(lastCommand: lastCommand, kind: kind)
        // ES-E10-4: a ⌘-hover wins the left field, showing the FULL resolved path (untruncated) on the
        // dark sub-strip. At rest the left field is the otty-shorthand cwd with the full path as the tooltip.
        if let hovered = hoverFullPath, !hovered.isEmpty {
            return Self(
                cwdDisplay: hovered,
                fullCwd: hovered,
                isPathHover: true,
                exit: exit,
                paneKind: paneKindLabel(kind),
                host: host,
            )
        }
        return Self(
            cwdDisplay: truncatedCwd(cwd),
            fullCwd: (cwd?.isEmpty == false) ? cwd : nil,
            isPathHover: false,
            exit: exit,
            paneKind: paneKindLabel(kind),
            host: host,
        )
    }

    /// Classify the last command's exit into the badge bucket. A non-`.terminal` pane has no shell exit
    /// concept (`.none`); a terminal with no finished command yet is `.running`; exit 0 / no reported code is
    /// `.success`; a non-zero code is `.failure(code)`. Mirrors ``OutlinePresentation`` "exit 0 / no code →
    /// succeeded" so the strip and the Outline never disagree.
    static func exitBadge(lastCommand: (exitCode: Int32?, durationMS: UInt32)?, kind: PaneKind) -> ExitBadge {
        guard kind == .terminal else { return .none }
        guard let lastCommand else { return .running }
        if let code = lastCommand.exitCode, code != 0 { return .failure(code) }
        return .success
    }

    /// The otty cwd shorthand: the LAST one or two path components, prefixed with `…/` when deeper ancestors
    /// were dropped (`/Users/abner/Workplace/otty` → `…/Workplace/otty`). Root is `/`; an unknown / empty cwd
    /// is the empty string (the view shows no left text). Pure string arithmetic — no float, no allocation
    /// beyond the split.
    static func truncatedCwd(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return "/" } // the path was all separators (root)
        let tail = components.suffix(2)
        let joined = tail.joined(separator: "/")
        return components.count > tail.count ? "…/" + joined : joined
    }

    /// A short human label for the pane kind (right edge). Lower-case, terminal-style, kept stable so a
    /// regression in the mapping is visible. The status strip only mounts in a `.terminal` leaf today, but the
    /// mapping is total so the model stays robust for any future non-terminal mount.
    static func paneKindLabel(_ kind: PaneKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .remoteGUI: "remote"
        case .systemDialog: "dialog"
        case .chooser: "chooser"
        case .web: "web"
        }
    }
}
