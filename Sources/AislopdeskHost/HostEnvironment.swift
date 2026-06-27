import AislopdeskVideoProtocol
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
        controlSocketPath: String? = nil,
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
        if let controlSocketPath { env[Self.agentControlSocketEnvKey] = controlSocketPath }

        return env
    }

    /// The PTY env var carrying the agent-hook listener socket path (W10). The installed
    /// Claude Code hook (``AgentInstaller``) POSTs to this socket; matches `MUXY_SOCKET_PATH`.
    public static let agentSocketEnvKey = "AISLOPDESK_SOCKET_PATH"

    /// The PTY env var carrying the pane id the hook should tag its events with (W10);
    /// matches `MUXY_PANE_ID`.
    public static let agentPaneIDEnvKey = "AISLOPDESK_PANE_ID"

    /// Agent-control socket path exported to every PTY env when the control listener is
    /// enabled. Agents shell out to `aislopdesk-ctl` pointing at this socket.
    public static let agentControlSocketEnvKey = "AISLOPDESK_CONTROL_SOCKET"

    /// Whether the agent-control Unix-domain socket should be bound. Default idiom =
    /// DEFAULT-OFF via `env[key] == "1"` (same as hooks) — writing to PTYs and spawning
    /// shells is not something to enable silently. Only an explicit `"1"` enables it.
    public static let agentControlEnvKey = "AISLOPDESK_AGENT_CONTROL"

    /// SENTINEL exported into a control-SPAWNED pane's env (P1): `"1"` tells an agent running
    /// inside that it lives under aislopdesk control and the ctl socket/binary are reachable, so it
    /// can self-orient with zero discovery. Set ONLY for `spawn`-created panes (not user panes).
    public static let ctlSentinelEnvKey = "AISLOPDESK_CTL"

    /// The absolute path to the `aislopdesk-ctl` binary, exported into a control-spawned pane's env
    /// (P1) so an agent can invoke it directly without a PATH lookup. Empty/absent → the agent
    /// falls back to a PATH lookup of `aislopdesk-ctl`.
    public static let ctlBinaryEnvKey = "AISLOPDESK_CTL_BIN"

    /// Resolves whether the agent-control socket should be bound. Default-OFF: only `"1"` enables.
    public static func agentControlEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        environment[agentControlEnvKey] == "1"
    }

    /// W10 — whether host-side Claude-Code agent detection is enabled (the foreground
    /// process-watch + the rolled-up status emission). Default idiom = DEFAULT-ON via
    /// `env[key] != "0"` (only an explicit `"0"` disables) — process-watch is zero-config and
    /// the ratified primary signal (Decision #5), so it is on unless the operator opts out.
    public static let agentDetectEnvKey = "AISLOPDESK_AGENT_DETECT"

    /// Resolves whether agent detection (the foreground watcher) is enabled. Default-ON:
    /// only the exact string `"0"` disables it; anything else (unset, `"1"`, etc.) enables.
    ///
    /// W12: the default `environment` resolves through ``EnvConfig`` (ProcessInfo env → settings
    /// overlay), so a GUI toggle in the agent settings (folded into the overlay from `video-prefs.json`)
    /// reaches this host gate. With an EMPTY overlay the resolved entry is byte-identical to the
    /// previous `ProcessInfo.processInfo.environment[key]`, so the default-ON `!= "0"` truth table is
    /// unchanged. An explicit `environment:` argument (tests) bypasses the overlay entirely.
    public static func agentDetectEnabled(
        environment: [String: String] = configEnv(agentDetectEnvKey),
    )
        -> Bool
    {
        environment[agentDetectEnvKey] != "0"
    }

    /// WB1 — whether the host segments the outbound PTY stream into Warp-style "Blocks" (the
    /// additive parallel ``CommandBlockSegmenter`` tap + the type-28/29 wire). Default idiom =
    /// DEFAULT-ON via `env[key] != "0"` (only an explicit `"0"` disables): when off, the byte
    /// pipeline + the live ``HostOutputSniffer`` stay byte-identical (no segmenter, no emit).
    public static let blocksEnvKey = "AISLOPDESK_BLOCKS"

    /// Resolves whether the Blocks tap is enabled. Default-ON: only the exact string `"0"`
    /// disables it; anything else (unset, `"1"`, etc.) enables. Same ``EnvConfig`` overlay
    /// resolution as ``agentDetectEnabled(environment:)`` (an empty overlay is byte-identical to
    /// the previous `ProcessInfo` read, so the default-ON `!= "0"` truth table is unchanged).
    public static func blocksEnabled(
        environment: [String: String] = configEnv(blocksEnvKey),
    )
        -> Bool
    {
        environment[blocksEnvKey] != "0"
    }

    /// E14/K2 — the env-bridge key carrying the client's "Auto Progress-Bar Commands" list to the
    /// host's synthetic OSC-9;4 spinner matcher (``AutoProgressMatcher``). The value is NEWLINE-separated
    /// prefix entries (each itself a whitespace-delimited command prefix, e.g. `git push`). It is
    /// resolved at THIS ONE shared site — set IDENTICALLY on host + client (like ``AISLOPDESK_FEC_M``):
    /// the client setting `autoProgressCommands` is the edit surface, and a live edit re-drives the host
    /// only on the NEXT host launch (the env is read at start). See docs/DECISIONS.md.
    public static let autoProgressCommandsEnvKey = "AISLOPDESK_AUTO_PROGRESS_COMMANDS"

    /// Resolves the host's auto-progress prefix list (E14/K2). UNSET ⇒ ``AutoProgressMatcher/builtInPrefixes``
    /// (the otty default list — auto-progress ON for known slow commands); SET-but-EMPTY ⇒ `[]`
    /// (auto-progress DISABLED, the otty "clear the field" behaviour); SET ⇒ the parsed entries. Same
    /// ``EnvConfig`` overlay resolution as the other gates (an empty overlay is byte-identical to a
    /// `ProcessInfo` read), so a GUI override reaches the matcher; an explicit `environment:` (tests)
    /// bypasses the overlay.
    public static func autoProgressPrefixes(
        environment: [String: String] = configEnv(autoProgressCommandsEnvKey),
    )
        -> [String]
    {
        AutoProgressMatcher.parsePrefixes(envValue: environment[autoProgressCommandsEnvKey])
    }

    /// E14/K13 — the env-bridge keys gating the agent-control ctl socket's MUTATING verbs. Default idiom =
    /// DEFAULT-OFF via `env[key] == "1"` (same as ``agentControlEnvKey``): injecting keys into a live PTY,
    /// spawning / killing a pane, or reaching a `sudo`/`ssh` prompt is not something to enable silently. The
    /// CLIENT toggles (`SettingsKey.ipcAllowSendKeys` / `ipcAllowSensitiveSessions`) are the edit surface and
    /// re-drive the host on the NEXT launch — set IDENTICALLY host+client, like ``AISLOPDESK_FEC_M``. The
    /// guard ENFORCES host-side on the existing NDJSON ctl socket (no new socket, no tokens, no crypto — the
    /// WireGuard mesh is the security boundary). See docs/DECISIONS.md.
    public static let ipcAllowSendKeysEnvKey = "AISLOPDESK_IPC_ALLOW_SEND_KEYS"
    public static let ipcAllowSensitiveEnvKey = "AISLOPDESK_IPC_ALLOW_SENSITIVE"

    /// Resolves whether the ctl socket may run MUTATING verbs (`write`/`run`/`spawn`/`kill`/`resize`).
    /// Default-OFF: only the exact string `"1"` enables; read-only verbs are always allowed regardless. Same
    /// ``EnvConfig`` overlay resolution as the other gates (an empty overlay is byte-identical to a
    /// `ProcessInfo` read), so a GUI toggle reaches the gate; an explicit `environment:` (tests) bypasses it.
    public static func ipcAllowSendKeys(
        environment: [String: String] = configEnv(ipcAllowSendKeysEnvKey),
    )
        -> Bool
    {
        environment[ipcAllowSendKeysEnvKey] == "1"
    }

    /// Resolves whether a mutating ctl verb may target a SENSITIVE foreground session (`ssh`/`sudo`/`login`/…).
    /// Default-OFF: only the exact string `"1"` enables. Same ``EnvConfig`` overlay resolution as
    /// ``ipcAllowSendKeys(environment:)``.
    public static func ipcAllowSensitiveSessions(
        environment: [String: String] = configEnv(ipcAllowSensitiveEnvKey),
    )
        -> Bool
    {
        environment[ipcAllowSensitiveEnvKey] == "1"
    }

    /// W10 — whether the opt-in Claude-Code HOOK listener (the `AF_UNIX` socket) is enabled.
    /// Default idiom = DEFAULT-OFF via `env[key] == "1"` (only an explicit `"1"` enables):
    /// hooks are the SECOND/opt-in signal (Decision #5), so the socket is bound only when the
    /// operator turned it on (or `integration install claude` set it for them).
    public static let agentHooksEnvKey = "AISLOPDESK_AGENT_HOOKS"

    /// Resolves whether the hook listener socket should be bound. Default-OFF: only `"1"`
    /// enables; anything else (unset, `"0"`) keeps it off (foreground watch still runs).
    ///
    /// W12: the default `environment` resolves through ``EnvConfig`` (ProcessInfo env → settings
    /// overlay) — same as ``agentDetectEnabled(environment:)`` — so a GUI toggle reaches the gate; an EMPTY
    /// overlay is byte-identical to the previous `ProcessInfo` read (default-OFF `== "1"` preserved).
    public static func agentHooksEnabled(
        environment: [String: String] = configEnv(agentHooksEnvKey),
    )
        -> Bool
    {
        environment[agentHooksEnvKey] == "1"
    }

    /// The single `AISLOPDESK_*` key resolved through ``EnvConfig`` (ProcessInfo env →
    /// settings overlay) and wrapped back into the `[String: String]` shape these gates index — so the gate's exact
    /// truth table stays at the call site while the key's *source* honours a GUI override. An empty
    /// overlay ⇒ at most the one `ProcessInfo` entry (or none), so the read is byte-identical to the
    /// old `ProcessInfo.processInfo.environment` default. `public` only because it is referenced from a
    /// `public` function's default-argument expression (evaluated at the call site).
    public static func configEnv(_ key: String) -> [String: String] {
        guard let value = EnvConfig.string(key) else { return [:] }
        return [key: value]
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
