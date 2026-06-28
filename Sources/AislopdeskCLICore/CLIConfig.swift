import Foundation

// `aislopdesk config path | edit | validate` — the LOCAL (no-socket) config-file ops (otty-clone
// E20, WI-4). These operate on the optional user config FILE (otty parity: `~/.config/otty/`), which
// is the persisted source a launch-time bridge reads. The RUNNING-app config ops
// (`get`/`set`/`unset`/`show`/`reload`, incl. `--transient`) go over the control socket instead;
// only `path`/`edit`/`validate` are pure file ops, so the path resolution + the validator live here,
// PURE and unit-tested (the `edit` $EDITOR spawn lives in the compiled-only `main.swift`).

public enum CLIConfig {
    /// Env override for the config-file location (the `--config-file` flag takes precedence over this).
    public static let configFileEnvKey = "AISLOPDESK_CONFIG_FILE"

    /// Resolve the config-file path: explicit `--config-file` > ``configFileEnvKey`` env > the XDG
    /// default. Pure (env injected) so the resolution order is unit-testable.
    public static func resolvePath(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override, !override.isEmpty { return override }
        if let env = environment[configFileEnvKey], !env.isEmpty { return env }
        return defaultPath(environment: environment)
    }

    /// `$XDG_CONFIG_HOME/aislopdesk/config.toml`, else `~/.config/aislopdesk/config.toml` (otty parity).
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg + "/aislopdesk/config.toml"
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return home + "/.config/aislopdesk/config.toml"
    }

    /// One config-file syntax problem (1-based line number + reason).
    public struct ValidationError: Equatable, Sendable {
        public let line: Int
        public let message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
    }

    /// Validate the simple `key = value` config syntax. Blank lines, `#`/`;` comments, and `[section]`
    /// table headers are skipped; every other line must be `key = value` (or `key=value`) with a
    /// non-empty key. Returns every problem found (empty ⇒ valid). PURE — no file I/O; the caller reads
    /// the file and passes its contents.
    public static func validate(_ contents: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("[") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                errors.append(ValidationError(line: index + 1, message: "missing '=' (expected key = value)"))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                errors.append(ValidationError(line: index + 1, message: "empty key before '='"))
            }
        }
        return errors
    }
}
