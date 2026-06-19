import Foundation

/// Builds the curated environment for a spawned login shell.
///
/// W11 retired the curated `claude` launch mode (a Claude session is now an auto-detected `.terminal`
/// pane — see `ClaudePaneDetector`), so the only Claude-Code-specific surface left is the ``Term`` choice
/// in ``ClaudeCodeProfile`` (and `ClaudeCodeProfile.environment`/`ClaudeAuthResolver` were removed in P4).
/// This generic profile is the env for a plain login shell (WF-3) and is Claude-agnostic.
///
/// TERM is shared: the client renders with libghostty, so the plain-shell path advertises the SAME
/// `TERM=xterm-ghostty` as the retired Claude path (``ClaudeCodeProfile/Term/ghostty``) — one source of
/// truth, not a divergent `xterm-256color` default. `curated(term:)` takes the value so callers can pick
/// the documented `.xterm256` fallback (#54700) symmetrically with the profile toggle.
public enum HostEnvironment {
    /// The default `TERM` for a spawned shell. Single source of truth shared with
    /// ``ClaudeCodeProfile`` (its `.ghostty` raw value): the client renders with
    /// libghostty, so a plain shell advertises the native ghostty TERM too.
    public static let defaultTerm = ClaudeCodeProfile.Term.ghostty.rawValue

    /// A curated child environment: inherit a safe allowlist from the parent and layer
    /// the terminal defaults on top. We deliberately do **not** forward the parent's
    /// `PATH` blindly ([12] §1.4) — we set a conservative default the child's login
    /// shell will re-derive from its profile anyway.
    ///
    /// - Parameters:
    ///   - term: the `TERM` to advertise. Defaults to ``defaultTerm`` (`xterm-ghostty`),
    ///     matching what the libghostty client renders.
    ///   - agentSocketPath: when non-nil, exported as `AISLOPDESK_SOCKET_PATH` so an installed
    ///     Claude Code hook (W10, ``AgentInstaller``) knows where to POST hook events. Absent
    ///     by default — detection works WITHOUT hooks via the foreground watcher (Decision #5).
    ///   - paneID: when non-nil, exported as `AISLOPDESK_PANE_ID` so the hook can tag which pane
    ///     it belongs to (Muxy's `MUXY_PANE_ID` analog). Absent by default.
    public static func curated(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        term: String = Self.defaultTerm,
        agentSocketPath: String? = nil,
        paneID: String? = nil,
    )
        -> [String: String]
    {
        var env: [String: String] = [:]

        // Mirror identity / locale-ish vars from the parent when present.
        //
        // TERMINFO / TERMINFO_DIRS are mirrored (R8 #2) because the host's terminfo PROBE
        // (``TerminfoResolver/searchDirectories``) honours them when deciding whether `xterm-ghostty`
        // resolves. If the operator launched the host from a shell whose TERMINFO points at a
        // non-standard dir holding the ghostty entry (Nix / Homebrew / per-user install), the probe says
        // "resolvable" and we advertise `TERM=xterm-ghostty` — but a child that did NOT inherit those vars
        // would have its ncurses search only the default dirs and FAIL to find the entry, so every TUI
        // degrades. Forwarding them makes the child's ncurses search the SAME dirs the probe used (only
        // forwarded when present), so a "resolvable" verdict is actually honoured.
        for key in [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "TERM_PROGRAM",
            "TERMINFO",
            "TERMINFO_DIRS",
        ] {
            if let value = parent[key] { env[key] = value }
        }

        // Terminal defaults (UTF-8 end-to-end; [12] §1.4).
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = term
        env["COLORTERM"] = "truecolor"
        env["NCURSES_NO_UTF8_ACS"] = "1"

        // Conservative PATH so the shell can find its own profile / common tools even
        // before the login profile augments it. (Not forwarded blindly from parent.)
        env["PATH"] = parent["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // W10: export the agent-hook socket path + pane id into the PTY env (Muxy's
        // MUXY_SOCKET_PATH / MUXY_PANE_ID analog) when the host has the opt-in hook listener
        // enabled. The installed hook script (``AgentInstaller/hookScript()``) reads these to
        // POST hook events to the host; absent → the hook is a silent no-op.
        if let agentSocketPath { env[Self.agentSocketEnvKey] = agentSocketPath }
        if let paneID { env[Self.agentPaneIDEnvKey] = paneID }

        return env
    }

    /// The PTY env var carrying the agent-hook listener socket path (W10). The installed
    /// Claude Code hook (``AgentInstaller``) POSTs to this socket; matches `MUXY_SOCKET_PATH`.
    public static let agentSocketEnvKey = "AISLOPDESK_SOCKET_PATH"

    /// The PTY env var carrying the pane id the hook should tag its events with (W10);
    /// matches `MUXY_PANE_ID`.
    public static let agentPaneIDEnvKey = "AISLOPDESK_PANE_ID"

    /// W10 — whether host-side Claude-Code agent detection is enabled (the foreground
    /// process-watch + the rolled-up status emission). Default idiom = DEFAULT-ON via
    /// `env[key] != "0"` (only an explicit `"0"` disables) — process-watch is zero-config and
    /// the ratified primary signal (Decision #5), so it is on unless the operator opts out.
    public static let agentDetectEnvKey = "AISLOPDESK_AGENT_DETECT"

    /// Resolves whether agent detection (the foreground watcher) is enabled. Default-ON:
    /// only the exact string `"0"` disables it; anything else (unset, `"1"`, etc.) enables.
    public static func agentDetectEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    )
        -> Bool
    {
        environment[agentDetectEnvKey] != "0"
    }

    /// W10 — whether the opt-in Claude-Code HOOK listener (the `AF_UNIX` socket) is enabled.
    /// Default idiom = DEFAULT-OFF via `env[key] == "1"` (only an explicit `"1"` enables):
    /// hooks are the SECOND/opt-in signal (Decision #5), so the socket is bound only when the
    /// operator turned it on (or `integration install claude` set it for them).
    public static let agentHooksEnvKey = "AISLOPDESK_AGENT_HOOKS"

    /// Resolves whether the hook listener socket should be bound. Default-OFF: only `"1"`
    /// enables; anything else (unset, `"0"`) keeps it off (foreground watch still runs).
    public static func agentHooksEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    )
        -> Bool
    {
        environment[agentHooksEnvKey] == "1"
    }

    /// The user's login shell path: `$SHELL` if set and absolute, else `/bin/zsh`.
    public static func loginShell(parent: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        if let shell = parent["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }

    /// The login-shell `argv[0]`: the shell's basename with a leading `-` (so it sources
    /// `.zprofile`/`.zshrc`; [12] §1.4).
    public static func loginArgv0(forShell shell: String) -> String {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        return "-" + name
    }
}
