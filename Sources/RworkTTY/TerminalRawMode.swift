#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Puts the LOCAL terminal into raw mode and **guarantees restore** on every exit path:
/// `defer`, normal return, and asynchronous signals (Ctrl-C / SIGTERM / SIGHUP / crash).
///
/// The user's terminal must NEVER be left corrupted (no echo, no line discipline). To
/// honor that even when a signal fires mid-session, the saved `termios` is stashed in a
/// process-global the signal handler can read, and restore is done with the
/// async-signal-safe `tcsetattr`. We register handlers for SIGINT/SIGTERM/SIGQUIT/SIGHUP
/// that restore the terminal and then re-raise the default disposition so the process
/// dies with the right status (or, for SIGINT in raw mode, we let the byte through —
/// see `rwork-client` main).
///
/// Not an actor: termios is process-global TTY state, manipulated by synchronous libc
/// calls and (necessarily) from a signal handler. We model it as a small value with
/// static save/restore and an `@unchecked Sendable` box guarded by an `os_unfair_lock`.
public enum TerminalRawMode {
    /// Process-global saved attributes + the fd they belong to, so a signal handler can
    /// restore without capturing context. Written once before entering raw mode.
    private final class SavedState: @unchecked Sendable {
        var lock = os_unfair_lock()
        var saved: termios?
        var fd: Int32 = -1
        var active = false
    }
    private static let state = SavedState()

    /// Whether raw mode is currently engaged (for diagnostics / idempotency).
    public static var isActive: Bool {
        os_unfair_lock_lock(&state.lock)
        defer { os_unfair_lock_unlock(&state.lock) }
        return state.active
    }

    // MARK: - Pure, testable termios primitives (no process-global state)

    /// Reads the current `termios` of `fd`. Throws on failure / non-tty.
    /// Pure helper (no global side effects) — unit-testable against an openpty fd.
    public static func currentAttributes(fd: Int32) throws -> termios {
        guard isatty(fd) != 0 else { throw RawModeError.notATTY }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw RawModeError.tcgetattrFailed(errno) }
        return t
    }

    /// Returns a raw-mode copy of `original`: `cfmakeraw` + VMIN=1 / VTIME=0. Pure.
    public static func rawAttributes(from original: termios) -> termios {
        var raw = original
        cfmakeraw(&raw)
        withUnsafeMutableBytes(of: &raw.c_cc) { buf in
            buf[Int(VMIN)] = 1
            buf[Int(VTIME)] = 0
        }
        return raw
    }

    /// Applies `attrs` to `fd` with `TCSAFLUSH`. Pure (no global state). Throws on failure.
    public static func applyAttributes(_ attrs: termios, fd: Int32) throws {
        var copy = attrs
        guard tcsetattr(fd, TCSAFLUSH, &copy) == 0 else { throw RawModeError.tcsetattrFailed(errno) }
    }

    /// Sets the window size of `fd` via `TIOCSWINSZ` (the host-side / SIGWINCH mapping).
    /// Pure helper, unit-testable against an openpty master fd.
    @discardableResult
    public static func setWindowSize(fd: Int32, cols: UInt16, rows: UInt16, pxWidth: UInt16 = 0, pxHeight: UInt16 = 0) -> Bool {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pxWidth, ws_ypixel: pxHeight)
        return ioctl(fd, UInt(TIOCSWINSZ), &ws) == 0
    }

    // MARK: - Process-global raw mode (used by the rwork-client executable)

    /// Enters raw mode on `fd` (default stdin). Saves the current attributes first.
    /// Throws if `fd` is not a tty or `tcgetattr`/`tcsetattr` fail.
    /// - Returns: the original `termios`, so the caller can `defer { restore() }`.
    @discardableResult
    public static func enableRaw(fd: Int32 = STDIN_FILENO) throws -> termios {
        let original = try currentAttributes(fd: fd)

        os_unfair_lock_lock(&state.lock)
        state.saved = original
        state.fd = fd
        state.active = true
        os_unfair_lock_unlock(&state.lock)

        // Keep ISIG OFF (cfmakeraw clears it): we deliver Ctrl-C as a raw byte to the
        // remote PTY (the remote shell's line discipline raises SIGINT there). The local
        // disconnect key is Ctrl-] (handled in the read loop), not a signal.
        let raw = rawAttributes(from: original)
        do {
            try applyAttributes(raw, fd: fd)
        } catch {
            // Roll back the active flag if we could not actually enter raw mode.
            os_unfair_lock_lock(&state.lock)
            state.active = false
            os_unfair_lock_unlock(&state.lock)
            throw error
        }
        return original
    }

    /// Restores the saved attributes. Idempotent and safe to call multiple times and
    /// from a signal handler (`tcsetattr` is async-signal-safe). No-op if never enabled.
    public static func restore() {
        os_unfair_lock_lock(&state.lock)
        guard state.active, var saved = state.saved, state.fd >= 0 else {
            os_unfair_lock_unlock(&state.lock)
            return
        }
        let fd = state.fd
        state.active = false
        os_unfair_lock_unlock(&state.lock)
        _ = tcsetattr(fd, TCSAFLUSH, &saved)
    }

    /// Installs signal handlers that restore the terminal then perform the default
    /// disposition (re-raise) so the process exits cleanly with the right status.
    /// Call AFTER `enableRaw`. Uses `sigaction` (not `signal`) for portable semantics.
    public static func installRestoreOnSignals() {
        for sig in [SIGINT, SIGTERM, SIGQUIT, SIGHUP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signo in
                TerminalRawMode.restore()
                // Re-raise with the default disposition so we die with the right status.
                signal(signo, SIG_DFL)
                raise(signo)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    /// Reads the local terminal window size via `TIOCGWINSZ`. Returns `nil` if `fd`
    /// is not a tty or the ioctl fails.
    public static func windowSize(fd: Int32 = STDIN_FILENO) -> (cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16)? {
        var ws = winsize()
        guard ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
        return (cols: ws.ws_col, rows: ws.ws_row, pxWidth: ws.ws_xpixel, pxHeight: ws.ws_ypixel)
    }
}

public enum RawModeError: Error, CustomStringConvertible {
    case notATTY
    case tcgetattrFailed(Int32)
    case tcsetattrFailed(Int32)

    public var description: String {
        switch self {
        case .notATTY: return "stdin is not a TTY"
        case let .tcgetattrFailed(e): return "tcgetattr failed (errno \(e))"
        case let .tcsetattrFailed(e): return "tcsetattr failed (errno \(e))"
        }
    }
}
