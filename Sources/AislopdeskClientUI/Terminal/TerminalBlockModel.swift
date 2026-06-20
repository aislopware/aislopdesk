import AislopdeskClient
import Foundation

// MARK: - CommandBlock (one Warp-style per-command block, client-side)

/// One Warp-style "Block" as the client knows it (WB2): a per-command record built from the host's
/// `commandBlock` metadata (wire type 28). It carries ONLY the metadata — the captured OUTPUT bytes are
/// fetched on demand (``TerminalBlockModel/requestOutput(index:send:)`` → wire type 15 → 29) so the
/// CONTROL channel never floods with command output.
///
/// A PURE value type (no SwiftUI / client import beyond the metadata) so the whole block model is
/// headlessly unit-testable.
public struct CommandBlock: Equatable, Sendable, Identifiable {
    /// The 0-based block index in the channel's segmenter lifetime — the upsert key AND the
    /// ``TerminalBlockModel/requestOutput(index:send:)`` request key. Stable for a block's lifetime.
    public let index: UInt32
    /// The typed command line (no prompt), as the host segmented it. Empty for a still-forming block.
    public var commandText: String
    /// The command's `$?` once it finished (nil while running, or if the shell did not report one).
    public var exitCode: Int32?
    /// The host-measured C→D wall-clock time in ms (nil while still running).
    public var durationMS: UInt32?
    /// True once the matching OSC 133 `D` arrived — the command finished.
    public var complete: Bool
    /// How many output bytes the host currently holds for this block (UI size hint / "has output" gate).
    public var outputLen: UInt32

    /// `Identifiable` over the stable wire index — so SwiftUI lists key rows by the block identity.
    public var id: UInt32 { index }

    public init(
        index: UInt32,
        commandText: String,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
        complete: Bool = false,
        outputLen: UInt32 = 0,
    ) {
        self.index = index
        self.commandText = commandText
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.complete = complete
        self.outputLen = outputLen
    }

    // MARK: Status → presentation (the testable icon/label mapping)

    /// The block's high-level status, derived purely from `complete` + `exitCode`.
    public enum Status: Equatable, Sendable {
        /// Still executing (no OSC 133 `D` yet) — the spinner state.
        case running
        /// Finished successfully (exit 0, or the shell reported no code — treated as success).
        case succeeded
        /// Finished with a non-zero exit `code`.
        case failed(code: Int32)
    }

    /// The derived status: running until complete, then succeeded (exit 0 / unknown) or failed (≠0).
    public var status: Status {
        guard complete else { return .running }
        switch exitCode {
        case nil,
             0:
            return .succeeded
        case let code?:
            return .failed(code: code)
        }
    }

    /// The SF Symbol name for the status icon (chrome chip / navigator row / sticky header).
    public var statusSymbol: String {
        switch status {
        case .running: "circle.dotted" // a spinner is overlaid in the view; this is the static fallback
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    /// A short, human status label ("running…", "exit 0", "exit 137").
    public var statusLabel: String {
        switch status {
        case .running: "running…"
        case .succeeded: "exit \(exitCode ?? 0)"
        case let .failed(code): "exit \(code)"
        }
    }

    /// The duration formatted compactly ("1.25s", "340ms"), or `nil` while running / unknown.
    public var durationLabel: String? {
        guard let ms = durationMS else { return nil }
        if ms >= 1000 {
            // One decimal of seconds (1250ms → "1.3s"); integer-rounded so the chip never jitters width.
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }
}

// MARK: - TerminalBlockModel (the per-pane ordered, bounded block store)

/// The per-pane block store (WB2): an ORDERED, BOUNDED `[CommandBlock]` keyed by `index`, upserted from
/// the host's `commandBlock` metadata (wire type 28), plus a pending-output-request registry resolved by
/// `blockOutput` (type 29) with strict empty-eviction handling (never hangs).
///
/// PURE + headlessly testable: it holds no SwiftUI / surface / actor state. The owning
/// ``TerminalViewModel`` folds the two block events into it and the SwiftUI surfaces (navigator / sticky
/// header / chrome chip) read its observable projections. `@MainActor @Observable` like the rest of the
/// view-model layer (the events fold + the SwiftUI reads are both on the main actor), but every method is
/// a synchronous pure mutation a unit test drives directly.
@preconcurrency
@MainActor
@Observable
public final class TerminalBlockModel {
    /// The block ring cap — mirrors the host `CommandBlockTracker`'s 64-block ring so the client can never
    /// hold a block the host already evicted (a request for an over-old index just yields an empty type-29,
    /// handled gracefully). Eviction drops the OLDEST (lowest-index) blocks.
    public static let maxBlocks = 64

    /// The blocks in INDEX order (oldest first). Newest is `last`. Bounded to ``maxBlocks``.
    public private(set) var blocks: [CommandBlock] = []

    /// The newest block (the CURRENT / last command), or `nil` if none yet. Drives the sticky header +
    /// the chrome status chip.
    public var latest: CommandBlock? { blocks.last }

    /// The blocks newest-first — the Command Navigator's display order (most recent at the top).
    public var navigatorBlocks: [CommandBlock] { blocks.reversed() }

    public init() {}

    /// The block for `index`, or `nil` if unknown / evicted.
    public func block(at index: UInt32) -> CommandBlock? {
        blocks.first { $0.index == index }
    }

    // MARK: Upsert (wire type 28 fold)

    /// Upserts a block from a `commandBlock` metadata update: a NEW index appends (kept index-ordered,
    /// evicting the oldest past ``maxBlocks``); a KNOWN index updates the existing record in place
    /// (running → completed transition, growing `outputLen`, a late command-text fill). The host emits
    /// monotonically increasing indices, but we tolerate any order: a binary-free linear scan finds the
    /// slot, and a brand-new lower index (shouldn't happen) still inserts in order.
    public func upsert(
        index: UInt32,
        commandText: String,
        exitCode: Int32?,
        durationMS: UInt32?,
        complete: Bool,
        outputLen: UInt32,
    ) {
        let block = CommandBlock(
            index: index,
            commandText: commandText,
            exitCode: exitCode,
            durationMS: durationMS,
            complete: complete,
            outputLen: outputLen,
        )
        if let existing = blocks.firstIndex(where: { $0.index == index }) {
            blocks[existing] = block
            return
        }
        // New index — insert at the index-ordered position (almost always the end, since the host emits
        // ascending indices), then evict the oldest to stay bounded.
        let insertAt = blocks.firstIndex(where: { $0.index > index }) ?? blocks.endIndex
        blocks.insert(block, at: insertAt)
        evictIfNeeded()
    }

    /// Folds one `AislopdeskClient.Event`. Only `.commandBlock` mutates the ring; `.blockOutput` resolves
    /// a pending output request (see ``resolveOutput(index:output:)``). All other events are ignored — the
    /// caller hands the whole event stream here for symmetry with the other folds.
    public func handle(_ event: AislopdeskClient.Event) {
        switch event {
        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText):
            upsert(
                index: index, commandText: commandText, exitCode: exitCode,
                durationMS: durationMS, complete: complete, outputLen: outputLen,
            )
        case let .blockOutput(index, output):
            resolveOutput(index: index, output: output)
        default:
            break
        }
    }

    private func evictIfNeeded() {
        while blocks.count > Self.maxBlocks {
            blocks.removeFirst()
        }
    }

    /// Clears all blocks + cancels every pending output request with an empty result (so a caller awaiting
    /// one never hangs). Called on a session reset / reconnect — the dead session's blocks are stale.
    public func reset() {
        blocks.removeAll()
        // Resolve every in-flight request as "unavailable" so its continuation never strands.
        let stranded = pending
        pending.removeAll()
        for (_, callbacks) in stranded {
            for callback in callbacks { callback(nil) }
        }
    }

    // MARK: Output request → resolve flow (wire type 15 → 29)

    /// The result of an output request: the RAW VT bytes the host captured, or `nil` when the block was
    /// EVICTED / never existed (the host replied with an empty type-29) — so a consumer can distinguish
    /// "no output available" from "empty output" without hanging.
    public typealias OutputResult = Data?

    /// In-flight output requests keyed by block index. A list of callbacks per index COALESCES concurrent
    /// requests for the same block onto ONE wire request: the first request sends, later ones for the same
    /// index just append a callback; the single type-29 reply fans out to all of them.
    @ObservationIgnored private var pending: [UInt32: [(OutputResult) -> Void]] = [:]

    /// Monotonic per-index REQUEST GENERATION, bumped each time a brand-new pending slot opens for an
    /// index (NOT on a coalesced piggy-back). A timeout `Task` captures the generation it armed for and
    /// passes it to ``timeoutPending(index:generation:)``; the timeout only fires if THAT generation is
    /// still the live one — so a stale timer from request #1 can never resolve a fresh request #2 for the
    /// same index (the #5 race). Resolving / timing out a slot leaves the counter alone (it only ever
    /// advances), so the next request gets a strictly newer token.
    @ObservationIgnored private var requestGeneration: [UInt32: UInt64] = [:]

    /// The generation currently armed for an in-flight request at `index`, or `nil` if none is pending —
    /// the token a caller's timeout must match to fire. Bumped by ``requestOutput`` on a fresh send.
    public func currentRequestGeneration(index: UInt32) -> UInt64? {
        pending[index] != nil ? requestGeneration[index] : nil
    }

    /// Requests block `index`'s output, invoking `completion` with the RAW VT bytes when the host replies
    /// (or `nil` on an EMPTY reply = evicted/unknown). `send` actually fires the wire request (it is the
    /// `AislopdeskClient.requestBlockOutput` call, injected so the model stays pure / testable); a request
    /// for an already-pending index does NOT re-send (it coalesces). Returns the request GENERATION the
    /// caller should pass to ``timeoutPending(index:generation:)`` so a stale timer can't kill a later
    /// request (#5). The flow NEVER hangs: a `blockOutput` always resolves it (empty → `nil`), and the
    /// generation-gated timeout is the belt-and-braces guard for a dropped reply.
    @discardableResult
    public func requestOutput(
        index: UInt32,
        send: (UInt32) -> Void,
        completion: @escaping (OutputResult) -> Void,
    ) -> UInt64 {
        if pending[index] != nil {
            // Already in flight — coalesce: just register this callback, do NOT re-send. The live
            // generation is the one armed when this slot opened; a coalesced caller shares it.
            pending[index]?.append(completion)
            return requestGeneration[index] ?? 0
        }
        let generation = (requestGeneration[index] ?? 0) &+ 1
        requestGeneration[index] = generation
        pending[index] = [completion]
        send(index)
        return generation
    }

    /// Resolves a pending request for `index` from a `blockOutput` reply: an EMPTY `output` is treated as
    /// "unavailable" (`nil`) — the host evicted the block or never had it. A reply for an index with no
    /// pending request is dropped (a stray / late type-29 must not crash). Fans out to every coalesced
    /// callback, then clears the slot.
    public func resolveOutput(index: UInt32, output: Data) {
        guard let callbacks = pending.removeValue(forKey: index) else { return }
        let result: OutputResult = output.isEmpty ? nil : output
        for callback in callbacks { callback(result) }
    }

    /// Whether a request for `index` is still in flight (the view shows a copy spinner while true).
    public func isOutputPending(index: UInt32) -> Bool {
        pending[index] != nil
    }

    /// Times out a still-pending request for `index`, resolving it as "unavailable" (`nil`) — the
    /// belt-and-braces guard for a host that drops the reply (so the UI's copy spinner never spins
    /// forever). A no-op if the request already resolved.
    ///
    /// GENERATION-GATED (#5): fires ONLY if `generation` is still the live token for this index. A copy
    /// request resolves its slot and a SECOND copy of the same block opens a NEW slot with a NEWER
    /// generation; the first copy's parked timeout then carries a STALE generation and is correctly
    /// ignored, so it can't resolve the fresh request as "unavailable". Passing `nil` keeps the old
    /// unconditional behavior (any pending request for the index is timed out).
    public func timeoutPending(index: UInt32, generation: UInt64? = nil) {
        if let generation, requestGeneration[index] != generation { return } // stale timer — ignore.
        guard let callbacks = pending.removeValue(forKey: index) else { return }
        for callback in callbacks { callback(nil) }
    }
}
