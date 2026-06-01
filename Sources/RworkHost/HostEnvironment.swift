import Foundation

/// Builds the curated environment for a spawned login shell.
///
/// WF-7 owns the Claude-Code-specific environment (`TERM=xterm-ghostty`,
/// `CLAUDE_CODE_NO_FLICKER=1`, `claude setup-token` reuse, etc.). For WF-3 we pass a
/// **sane, generic** terminal environment so the round-trip / interactive / resize
/// tests exercise a real shell, without baking in any Claude-specific values.
///
/// // TODO(WF-7): replace the placeholder `TERM=xterm-256color` with
/// // `xterm-ghostty` (kitty keyboard + DEC2026), add `CLAUDE_CODE_*` env, and own the
/// // curated-env policy. Do NOT hardcode Claude-specific env here.
public enum HostEnvironment {
    /// A curated child environment: inherit a safe allowlist from the parent and layer
    /// the terminal defaults on top. We deliberately do **not** forward the parent's
    /// `PATH` blindly ([12] §1.4) — we set a conservative default the child's login
    /// shell will re-derive from its profile anyway.
    public static func curated(parent: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String]
    {
        var env: [String: String] = [:]

        // Mirror identity / locale-ish vars from the parent when present.
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM_PROGRAM"] {
            if let value = parent[key] { env[key] = value }
        }

        // Terminal defaults (UTF-8 end-to-end; [12] §1.4).
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = "xterm-256color" // TODO(WF-7): xterm-ghostty
        env["COLORTERM"] = "truecolor"
        env["NCURSES_NO_UTF8_ACS"] = "1"

        // Conservative PATH so the shell can find its own profile / common tools even
        // before the login profile augments it. (Not forwarded blindly from parent.)
        env["PATH"] = parent["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        return env
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
        let name = (shell as NSString).lastPathComponent
        return "-" + name
    }
}
