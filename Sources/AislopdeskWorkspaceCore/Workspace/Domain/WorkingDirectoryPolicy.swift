import Foundation

// MARK: - WorkingDirectoryPolicy (otty `working-directory` / inherit-cwd policy)

/// How a freshly-opened pane (new window / new tab / new split) chooses its initial working directory — the
/// faithful clone of otty's per-context `working-directory` config
/// (`spec/user-interface__window-tab-split.md`, values a path / `home` / `inherit`).
///
/// - ``inherit``: start in the **active pane's** last-known cwd (otty "Same as Current Tab"). The source cwd
///   is the host `cwd` RPC refreshed on command-completion — the OSC-7 equivalent (see `docs/DECISIONS.md`).
/// - ``home``: start in the shell's login directory. Resolves to a **`nil`** cwd: a fresh login shell already
///   starts at `$HOME`, so emitting a literal `cd $HOME` would be redundant (and would fight a shell that is
///   configured to open elsewhere). No `cd` is sent — see ``resolve(activePaneCwd:)``.
/// - ``path``: start in a fixed absolute path the user configured.
///
/// PURE — no filesystem I/O, never traps. ``init(rawConfig:)`` is validate-then-repair: an empty / unknown
/// stored string falls back to a sane default rather than crashing on hostile persisted config. ``rawConfig``
/// round-trips the stored otty config string so the setting persists losslessly.
public enum WorkingDirectoryPolicy: Sendable, Equatable {
    /// Same cwd as the active pane (otty `inherit`).
    case inherit
    /// The shell's login directory — resolves to `nil` (no redundant `cd`); otty `home` / empty.
    case home
    /// A fixed absolute path (any non-`inherit`/non-`home` otty config value).
    case path(String)

    /// Decodes the stored otty `working-directory` config string. Validate-then-repair: a (trimmed)
    /// `"inherit"` → ``inherit``; `"home"` or an empty / whitespace-only string → ``home``; anything else →
    /// ``path`` carrying the trimmed string. Never traps.
    public init(rawConfig: String) {
        let trimmed = rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "inherit":
            self = .inherit
        case "",
             "home":
            self = .home
        default:
            self = .path(trimmed)
        }
    }

    /// The stored otty config string for this policy (the inverse of ``init(rawConfig:)``): ``inherit`` →
    /// `"inherit"`, ``home`` → `"home"`, ``path(p)`` → `p`. Round-trips through ``init(rawConfig:)``.
    public var rawConfig: String {
        switch self {
        case .inherit: "inherit"
        case .home: "home"
        case let .path(path): path
        }
    }

    /// Resolves the initial cwd for a new pane, given the active pane's last-known cwd:
    ///
    /// - ``inherit`` → `activePaneCwd` (possibly `nil` when the active pane has no known cwd yet).
    /// - ``home`` → `nil` (the shell's login cwd — emit no redundant `cd`).
    /// - ``path(p)`` → `p`.
    ///
    /// A `nil` result means "send no `cd`" (the new pane keeps the login shell's default cwd).
    public func resolve(activePaneCwd: String?) -> String? {
        switch self {
        case .inherit: activePaneCwd
        case .home: nil
        case let .path(path): path
        }
    }
}
