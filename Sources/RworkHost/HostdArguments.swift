import Foundation

/// Parsed command-line configuration for the `rwork-hostd` daemon.
///
/// This lives in the library (not in the executable's `main.swift`) so the arg-parse →
/// ``HostServer/LaunchMode`` mapping is unit-testable without spawning a process: a test
/// parses an argv slice and asserts on the resulting `launchMode` / `port` / `shell`.
///
/// ## Flags
/// - `--port N` / `-p N`: TCP port to bind (default `7420`; `0` = OS-assigned).
/// - `--shell PATH` / `-s PATH`: shell to spawn (default: the user's login shell).
/// - `--claude`: launch `claude` under the curated ``ClaudeCodeProfile`` instead of a
///   plain login shell — selects ``HostServer/LaunchMode/claudeCode(_:)``.
/// - `--xterm256`: with `--claude`, advertise `TERM=xterm-256color`
///   (``ClaudeCodeProfile/Term/xterm256``, the #54700 fallback) instead of the default
///   `xterm-ghostty`. Ignored without `--claude`.
/// - `--help` / `-h`: returns `nil` (caller prints usage + exits non-zero).
public struct HostdArguments: Sendable, Equatable {
    public let port: UInt16
    public let shell: String?
    public let launchMode: HostServer.LaunchMode

    public init(port: UInt16, shell: String?, launchMode: HostServer.LaunchMode) {
        self.port = port
        self.shell = shell
        self.launchMode = launchMode
    }

    /// The usage string printed on `--help` or a parse error.
    public static func usage(programName: String) -> String {
        "usage: \(programName) [--port N] [--shell /path/to/shell] [--claude [--xterm256]]"
    }

    /// Parses a full argv (including `argv[0]`, which is dropped). Returns `nil` for
    /// `--help`/`-h`, a missing flag value, or an unknown flag — the caller then prints
    /// ``usage(programName:)`` and exits non-zero.
    public static func parse(_ args: [String]) -> HostdArguments? {
        var port: UInt16 = 7420
        var shell: String?
        var claude = false
        var xterm256 = false

        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--port", "-p":
                guard let value = iterator.next(), let p = UInt16(value) else { return nil }
                port = p
            case "--shell", "-s":
                guard let value = iterator.next() else { return nil }
                shell = value
            case "--claude":
                claude = true
            case "--xterm256":
                xterm256 = true
            case "--help", "-h":
                return nil
            default:
                return nil
            }
        }

        let launchMode: HostServer.LaunchMode
        if claude {
            let term: ClaudeCodeProfile.Term = xterm256 ? .xterm256 : .ghostty
            launchMode = .claudeCode(ClaudeCodeProfile(term: term))
        } else {
            // `--xterm256` without `--claude` is a no-op: the plain-shell TERM is fixed
            // to the libghostty default here (the daemon does not expose a TERM override
            // for the plain shell — that would be a separate flag if ever needed).
            launchMode = .shell
        }

        return HostdArguments(port: port, shell: shell, launchMode: launchMode)
    }
}
