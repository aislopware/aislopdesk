import Foundation

// MARK: - E10 WI-6 (ES-E10-2): pure link gesture/menu → action mapping

/// The user gesture on a detected link the policy resolves. A plain (un-modified) click is included so
/// the otty "click does nothing — prevents accidental opens" rule is encoded HERE (not as an implicit
/// absence), keeping the mapping total and unit-testable.
public enum LinkGesture: Equatable, Sendable, CaseIterable {
    /// A bare left-click — otty maps this to *nothing* (no accidental opens).
    case plainClick
    /// `⌘`click — open / copy / nothing, per ``LinkActionConfig/cmdClick``.
    case commandClick
    /// `⌘⇧`click — reveal-in-Finder / open-system-default (paths) or copy (URLs), per
    /// ``LinkActionConfig/cmdShiftClick``.
    case commandShiftClick
}

/// The two otty link config knobs (`link-cmd-click` / `link-cmd-shift-click`) the policy reads, reusing
/// the persisted ``LinkCmdClick`` / ``LinkCmdShiftClick`` enums so there is ONE source of truth (the
/// renderer builds this from ``SettingsKey/linkCmdClick`` + ``SettingsKey/linkCmdShiftClick`` at click
/// time). Pure value type — no `Defaults`/AppKit — so the policy stays headless-testable.
public struct LinkActionConfig: Equatable, Sendable {
    /// What a `⌘`click does (otty `link-cmd-click`, default ``LinkCmdClick/open``).
    public var cmdClick: LinkCmdClick
    /// What a `⌘⇧`click does (otty `link-cmd-shift-click`, default ``LinkCmdShiftClick/revealFinder``).
    public var cmdShiftClick: LinkCmdShiftClick

    public init(cmdClick: LinkCmdClick = .open, cmdShiftClick: LinkCmdShiftClick = .revealFinder) {
        self.cmdClick = cmdClick
        self.cmdShiftClick = cmdShiftClick
    }

    /// The otty defaults (open / reveal-finder).
    public static let `default` = Self()
}

/// The resolved action the renderer dispatches for a link gesture / context-menu item. Each case names
/// **where it actuates** so the thin macOS/iOS actuator can route it without re-deriving intent:
///
/// - ``copyPathClient``: write the resolved path / URL to the CLIENT pasteboard (Copy Path / Copy URL).
/// - ``changeDirectoryPTY``: inject `cd <path>` as **verbatim UTF-8** down the pane's PTY (Change
///   Directory Here) — never via `SendKeysParser` (memory: re-run/cd is verbatim UTF-8).
/// - ``openHost``: ask the HOST to open the path in its best handler (the file lives on the host Mac, so
///   `NSWorkspace.open` must run host-side — delivered by the E10 WI-7 metadata RPC verb).
/// - ``revealHost``: ask the HOST to reveal the path in Finder (host-side `activateFileViewerSelecting`,
///   WI-7).
/// - ``openURLClient``: open the URL on the CLIENT (a URL / IP is host-agnostic — `NSWorkspace.open` /
///   `UIApplication.open`, or the in-app browser pane per config).
/// - ``nothing``: no-op (a plain click, or a config that disables the gesture).
public enum LinkAction: Equatable, Sendable {
    case copyPathClient(String)
    case changeDirectoryPTY(String)
    case openHost(String)
    case revealHost(String)
    case openURLClient(String)
    case nothing
}

/// The PURE mapping `(gesture or menu item) × link kind × config → ``LinkAction``` behind otty's
/// "Click Actions" table (`user-interface__files-and-links` §"Click Actions"):
///
/// | Target | Click | ⌘click | ⌘⇧click |
/// |---|---|---|---|
/// | Path | nothing | open best handler (host) / copy / nothing | reveal-Finder (host) / open-default (host) |
/// | URL  | nothing | open URL (client) / copy / nothing | Copy URL (client) |
///
/// Splitting it out as a pure enum keeps the otty table unit-testable headless (``LinkActionPolicyTests``,
/// revert-to-confirm-fail) and lets BOTH the ⌘click/⌘⇧click renderer path (WI-6) and the right-click
/// context menu (``TerminalContextMenu/LinkItem``) resolve through the SAME logic — no parallel switch
/// that could drift. The renderer is the thin actuator: it feeds the ``DetectedLink`` under the pointer
/// + the live config and dispatches the returned action.
///
/// A path's actuation path uses ``DetectedLink/resolvedAbsolute`` when the detector could resolve it
/// purely (an absolute path, a relative path joined to an absolute cwd, a `file://` path) and falls back
/// to the raw matched text otherwise (a `~`-path / an unresolved relative path) — the HOST expands the
/// remainder (`~`/cwd) and validates before acting (WI-7), so the client never reads the disk.
public enum LinkActionPolicy {
    /// Resolve a left-click gesture on `link` under `config`.
    public static func action(for gesture: LinkGesture, link: DetectedLink, config: LinkActionConfig) -> LinkAction {
        switch gesture {
        case .plainClick:
            // otty: a bare click on a link does NOTHING — it prevents accidental opens.
            .nothing
        case .commandClick:
            commandClickAction(link: link, behavior: config.cmdClick)
        case .commandShiftClick:
            commandShiftClickAction(link: link, behavior: config.cmdShiftClick)
        }
    }

    /// Resolve a right-click context-menu item on `link` (``TerminalContextMenu/LinkItem``). The menu
    /// only offers reveal / cd for path kinds (see ``TerminalContextMenu/linkItems(for:)``), so a URL +
    /// reveal/cd is defensively ``LinkAction/nothing``.
    public static func action(for menuItem: TerminalContextMenu.LinkItem, link: DetectedLink) -> LinkAction {
        switch menuItem {
        case .open:
            if isURL(link) { .openURLClient(link.raw) } else { .openHost(effectivePath(link)) }
        case .copyPath:
            .copyPathClient(isURL(link) ? link.raw : effectivePath(link))
        case .revealInFinder:
            isURL(link) ? .nothing : .revealHost(effectivePath(link))
        case .changeDirectoryHere:
            isURL(link) ? .nothing : .changeDirectoryPTY(effectivePath(link))
        }
    }

    // MARK: - Gesture sub-rules

    private static func commandClickAction(link: DetectedLink, behavior: LinkCmdClick) -> LinkAction {
        switch behavior {
        case .open:
            if isURL(link) { .openURLClient(link.raw) } else { .openHost(effectivePath(link)) }
        case .copy:
            .copyPathClient(isURL(link) ? link.raw : effectivePath(link))
        case .nothing:
            .nothing
        }
    }

    private static func commandShiftClickAction(link: DetectedLink, behavior: LinkCmdShiftClick) -> LinkAction {
        // A URL has no Finder target, so otty maps ⌘⇧click on a URL to *Copy URL* regardless of the
        // (path-oriented) `link-cmd-shift-click` setting.
        if isURL(link) { return .copyPathClient(link.raw) }
        switch behavior {
        case .revealFinder:
            return .revealHost(effectivePath(link))
        case .openSystemDefault:
            return .openHost(effectivePath(link))
        }
    }

    // MARK: - Helpers

    /// A pure URL (`scheme://…` or `mailto:`), as opposed to a filesystem path. A `file://` URL is a PATH
    /// for action purposes — its filesystem target is what `Open` / `Reveal` / `Copy Path` act on.
    static func isURL(_ link: DetectedLink) -> Bool { link.kind == .url }

    /// The best path string for a path-kind action: the purely-resolved absolute path when the detector
    /// could derive one, else the raw matched text (the host expands `~`/cwd + validates). Never reads
    /// the disk.
    static func effectivePath(_ link: DetectedLink) -> String { link.resolvedAbsolute ?? link.raw }
}
