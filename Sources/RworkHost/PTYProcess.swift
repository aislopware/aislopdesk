#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RworkProtocol

/// A child process attached to a pseudo-terminal (PTY) on the macOS host.
///
/// ## Spawn strategy (`DECISIONS.md` / [12])
/// `openpty()` to allocate the master/slave pair, then `posix_spawn` with
/// `POSIX_SPAWN_SETSID` (create a new session so the child is a session leader with
/// the slave as its controlling terminal). `forkpty` is **unsafe** to call from
/// Swift (fork in a multi-threaded runtime), so we never use it.
///
/// `setBlocking(true)` clears `O_NONBLOCK` on the master FD before spawn — a
/// non-blocking master breaks some children (Happy #301).
///
/// The relay (PTY <-> transport) is no-buffer with a `USER_INTERACTIVE` QoS thread
/// (no intermediate ring buffer — the NoMachine NX lesson); that lives in
/// ``HostSession`` (WF-3).
///
/// - Note: Documented seam for WF-3. `Darwin` may be imported, but the unimplemented
///   logic is guarded / stubbed so the package compiles cleanly.
public final class PTYProcess: @unchecked Sendable {
    /// Master side of the PTY (host reads child output / writes child input here).
    /// `-1` until ``spawn(_:arguments:environment:)`` succeeds.
    public private(set) var masterFD: Int32 = -1

    /// PID of the spawned child, or `-1` before spawn.
    public private(set) var pid: pid_t = -1

    public init() {}

    /// Allocates a PTY and spawns `executable` as a session leader attached to it.
    ///
    /// - Parameters:
    ///   - executable: absolute path to the program (e.g. the user's `$SHELL`).
    ///   - arguments: argv (excluding argv[0], which is set to `executable`).
    ///   - environment: full environment for the child (e.g. `TERM=xterm-ghostty`,
    ///     `CLAUDE_CODE_NO_FLICKER=1` — set by WF-7).
    public func spawn(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws {
        // TODO(WF-3): openpty() -> (master, slave); setBlocking(true) on master;
        //   posix_spawn_file_actions add dup2(slave -> 0/1/2);
        //   POSIX_SPAWN_SETSID; posix_spawn; close slave in parent.
        throw HostError.notImplemented("PTYProcess.spawn — WF-3")
    }

    /// Clears `O_NONBLOCK` on `fd` so reads/writes block (Happy #301).
    /// Exposed for WF-3 wiring and tests.
    public static func setBlocking(_ fd: Int32) {
        #if canImport(Darwin)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        #endif
    }

    /// Applies a terminal size to the PTY via `TIOCSWINSZ` (driven by `resize`).
    public func setWindowSize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) {
        // TODO(WF-3): build winsize, ioctl(masterFD, TIOCSWINSZ, &ws).
    }

    /// Reaps the child and returns its exit code, or `nil` if still running.
    public func waitExitCode() -> Int32? {
        // TODO(WF-3): waitpid(pid, &status, WNOHANG); decode WIFEXITED/WEXITSTATUS.
        nil
    }
}

/// Host-side errors. Distinct from ``RworkError`` (which is wire-decode only).
public enum HostError: Error, Equatable, Sendable {
    /// A seam that WF-3 has not implemented yet.
    case notImplemented(String)
    /// A POSIX syscall failed; associated value is `errno`.
    case posix(Int32)
}
