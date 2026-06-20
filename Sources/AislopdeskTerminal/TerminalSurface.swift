import AislopdeskProtocol
import Foundation

/// The seam between the byte pipeline and a terminal renderer.
///
/// PATH 1 streams raw VT bytes from the host PTY to the client; **how** those bytes
/// become pixels is hidden behind this protocol. The production renderer is
/// **libghostty** (see `DECISIONS.md`): a
/// `GhosttySurface` conforming to `TerminalSurface` lives in the GUI app target
/// (WF-5), where it owns a `ghostty_surface_t` in a Metal view. The headless core
/// here never links libghostty.
///
/// ``HeadlessTerminalSurface`` is the in-package conformer used by tests and the
/// headless `aislopdesk-client` CLI.
///
/// ### Concurrency
/// libghostty's `feed_data`/`refresh`/`draw` are main-thread-only ([18 C]), so the
/// real renderer will be `@MainActor`. This protocol does not impose an isolation;
/// conformers state their own. `onWrite` fires when the surface produces bytes to
/// send back to the host (encoded keystrokes), which the client wraps in `input`.
public protocol TerminalSurface: AnyObject {
    /// Feeds inbound PTY/VT bytes (an `output` payload) into the renderer.
    func feed(_ bytes: Data)

    /// Feeds a BATCH of output payloads, flushing the renderer ONCE at the end.
    ///
    /// The batch-drain ingest path uses this so a backlog of N wire chunks costs one
    /// render flush instead of N. The default implementation simply feeds each chunk
    /// (per-chunk flush — correct, just unbatched); renderers with a separate
    /// write/flush split (GhosttySurface) override it to write all chunks and
    /// refresh/present once. Must be fully synchronous (doc-18-§C: no suspension
    /// between writes and the flush).
    func feedBatch(_ chunks: ArraySlice<Data>)

    /// Sets the terminal grid size; mirrored to the host via `resize`.
    func setSize(cols: UInt16, rows: UInt16)

    /// Handles user input already encoded as terminal bytes (e.g. from a test or a
    /// headless driver). The real GUI surface routes keys through
    /// `ghostty_surface_key` and emits bytes via ``onWrite``.
    func handleInput(_ bytes: Data)

    /// Called when the surface has bytes to send back to the host (keystrokes the
    /// renderer encoded). The client encodes these as ``WireMessage/input(_:)``.
    var onWrite: ((Data) -> Void)? { get set }
}

public extension TerminalSurface {
    /// Default: feed each chunk individually (per-chunk flush). Renderers with a
    /// write/flush split override for one flush per batch.
    func feedBatch(_ chunks: ArraySlice<Data>) {
        for chunk in chunks {
            feed(chunk)
        }
    }
}

// MARK: - TerminalSurfaceActions (the W14 editor-action capability seam)

/// The OPTIONAL capability seam (docs/42 W14) the right-click context menu and the ⌘F find bar drive: a
/// renderer that wraps a real terminal (``GhosttySurface``) exposes selection state + named keybinding
/// actions + scrollback search through these, so the SwiftUI find bar / `NSMenu` route through the SEAM
/// instead of importing libghostty. Headless conformers (tests, the CLI) DO NOT conform — the GUI probes
/// with `as? TerminalSurfaceActions` and degrades gracefully (a no-selection, no-search surface), exactly
/// like ``FeedBackpressuring``. None of these are exercised in a test (the real surface hangs without a
/// window server — the hang-safety rule); they are compiled + code-reviewed, and their PURE inputs
/// (``TerminalSearchController`` over a text mirror) carry the unit tests.
public protocol TerminalSurfaceActions: AnyObject {
    /// Whether the surface currently holds a text selection (gates Copy in the context menu).
    func hasSelection() -> Bool

    /// The current selection as text, or `nil` (drives "copy" + the find-from-selection seed).
    func readSelection() -> String?

    /// Fires a named libghostty keybinding action (`copy_to_clipboard` / `paste_from_clipboard` /
    /// `select_all` / `clear_screen` / `jump_to_prompt:-1` / `start_search:<needle>` …). Returns whether it
    /// ran. The single lever the menu + find bar + jump-to-prompt all route through.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool

    /// A flat, line-oriented text mirror of the visible scrollback (newest screen + retained scrollback),
    /// for the client-side ``TerminalSearchController`` fallback when libghostty's in-surface search result
    /// callbacks are not plumbed through the C `action_cb`. One entry per line, no trailing newline.
    func scrollbackTextLines() -> [String]
}

/// Backpressure seam for renderers whose ``TerminalSurface/feed(_:)`` is an
/// ASYNCHRONOUS enqueue (GhosttySurface's per-surface serial feed queue, docs/31 #5).
///
/// A SEPARATE `Sendable` protocol (not a `TerminalSurface` requirement with a default):
/// the ingest pump must `await` this from the main actor, and awaiting a nonisolated
/// async member on a non-Sendable `any TerminalSurface` existential is a Swift 6
/// sending violation. Synchronous renderers (headless, tests) simply don't conform —
/// the pump's `as?` probe skips them with zero overhead change.
public protocol FeedBackpressuring: Sendable {
    /// Parks until the renderer can absorb more feed work — i.e. its queued-but-
    /// unparsed backlog is below a high-water mark. The ingest pump awaits this before
    /// each pass so wire flow control (credit-at-consumption) stays coupled to actual
    /// parse progress; without it a flood turns the feed queue into an unbounded
    /// buffer. Must always resolve in bounded time.
    func feedBackpressure() async
}
