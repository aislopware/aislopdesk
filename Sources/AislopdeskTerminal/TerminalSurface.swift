import Foundation
import AislopdeskProtocol

/// The seam between the byte pipeline and a terminal renderer.
///
/// PATH 1 streams raw VT bytes from the host PTY to the client; **how** those bytes
/// become pixels is hidden behind this protocol. The production renderer is
/// **libghostty only** (no SwiftTerm fallback — `DECISIONS.md`): a
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

extension TerminalSurface {
    /// Default: feed each chunk individually (per-chunk flush). Renderers with a
    /// write/flush split override for one flush per batch.
    public func feedBatch(_ chunks: ArraySlice<Data>) {
        for chunk in chunks {
            feed(chunk)
        }
    }
}
