import AislopdeskProtocol
import Foundation

/// The HOST per-channel "Blocks" tracker: the live glue between the pure ``CommandBlockSegmenter``
/// and the wire. It runs as an ADDITIVE PARALLEL tap on the same outbound PTY chunks the live
/// ``HostOutputSniffer`` observes — it only OBSERVES; the byte pipeline forwards the bytes unchanged.
///
/// Responsibilities:
/// - feed each chunk to the per-channel ``CommandBlockSegmenter`` and produce a ``WireMessage/commandBlock``
///   METADATA update (type 28) on each block create / update / complete, DEDUPED so identical
///   metadata is not re-sent;
/// - keep a BOUNDED ring of each completed block's captured OUTPUT bytes (bounded by both a block
///   COUNT cap and a total-BYTES cap) so a long session can never blow host memory;
/// - serve a ``WireMessage/blockOutput`` (type 29) from that ring on a ``requestBlockOutput`` —
///   an EMPTY output when the block was evicted or never existed.
///
/// This is a pure value-ish type (no I/O, no clock of its own beyond the segmenter's injected one),
/// so it is fully unit-testable headlessly. ``MuxChannelSession`` owns ONE per channel under a lock
/// (the read-loop thread feeds `ingest`; the control task calls `serveOutput`).
struct CommandBlockTracker {
    /// Default ring bound on the number of completed blocks whose output is retained.
    static let defaultMaxBlocks = 64
    /// Default ring bound on the total retained output bytes across all held blocks (8 MiB) — a
    /// second ceiling so 64 max-size (256 KiB) blocks can't pin 16 MiB; evicts oldest-first.
    static let defaultMaxTotalOutputBytes = 8 * 1024 * 1024

    private var segmenter: CommandBlockSegmenter
    private let maxBlocks: Int
    private let maxTotalOutputBytes: Int

    /// The wire-relevant metadata of a block — the dedup key (re-emit only when this changes).
    private struct BlockMeta: Equatable {
        var exitCode: Int32?
        var durationMS: UInt32?
        var complete: Bool
        var outputLen: UInt32
        var commandText: String
    }

    /// One retained COMPLETED block's output (the output ring).
    private struct Held {
        var index: UInt32
        var output: [UInt8]
    }

    /// Insertion-ordered ring of retained completed blocks (oldest first). Evicted oldest-first
    /// when either bound is exceeded. A dictionary would not preserve eviction order → an array.
    private var held: [Held] = []
    private var totalOutputBytes = 0

    /// Dedup state: the metadata LAST EMITTED per block index (covers BOTH the running and the
    /// completed emit, independent of the output ring — a running block is not retained but still
    /// deduped). Bounded the same way the ring is (pruned alongside eviction) so it can't grow
    /// unbounded across a long session.
    private var lastEmitted: [UInt32: BlockMeta] = [:]

    init(
        segmenter: CommandBlockSegmenter = CommandBlockSegmenter(),
        maxBlocks: Int = Self.defaultMaxBlocks,
        maxTotalOutputBytes: Int = Self.defaultMaxTotalOutputBytes,
    ) {
        self.segmenter = segmenter
        // Validate-then-clamp: a non-positive bound would mean "retain nothing"; treat <=0 as the
        // default so a caller can never accidentally disable retention or under/overflow.
        self.maxBlocks = maxBlocks > 0 ? maxBlocks : Self.defaultMaxBlocks
        self.maxTotalOutputBytes = maxTotalOutputBytes > 0 ? maxTotalOutputBytes : Self.defaultMaxTotalOutputBytes
    }

    /// Feeds one OUTBOUND PTY chunk to the segmenter and returns the ``WireMessage/commandBlock``
    /// metadata updates (type 28) to enqueue on the CONTROL channel — DEDUPED (a block whose
    /// metadata did not change since the last emit produces nothing). Completed blocks AND the
    /// currently-running block are both surfaced, so the UI sees a RUNNING block as soon as it opens.
    mutating func ingest(_ chunk: Data) -> [WireMessage] {
        let completed = segmenter.ingest(Array(chunk))
        var messages: [WireMessage] = []
        for block in completed {
            // Emit BEFORE retaining so dedup compares against the PRIOR emit, then retain the output.
            if let message = emitIfChanged(block) { messages.append(message) }
            store(block)
        }
        // Surface the still-open (running) block too — its partial output length + RUNNING state —
        // so the client shows the in-flight command. Its output is NOT retained until it completes
        // (it is still growing; a fetch mid-run would race the segmenter), so outputLen here is the
        // metadata-only partial count and the ring fill happens on completion above.
        if let open = segmenter.peekOpenBlock(), let message = emitIfChanged(open) {
            messages.append(message)
        }
        return messages
    }

    /// Serves a ``WireMessage/blockOutput`` (type 29) for `index` from the ring — the retained
    /// output bytes, or an EMPTY output if that block was evicted or never existed (never traps).
    func serveOutput(index: UInt32) -> WireMessage {
        let bytes = held.first(where: { $0.index == index })?.output ?? []
        return .blockOutput(index: index, output: Data(bytes))
    }

    // MARK: - Internals

    /// Builds the wire metadata for a block and returns a `commandBlock` message ONLY if that
    /// metadata differs from what was last emitted for this index (dedup). Records the new metadata.
    private mutating func emitIfChanged(_ block: CommandBlockSegmenter.CommandBlock) -> WireMessage? {
        let index = UInt32(truncatingIfNeeded: block.index)
        let meta = BlockMeta(
            exitCode: block.exitCode,
            durationMS: block.durationMS,
            complete: block.complete,
            outputLen: UInt32(truncatingIfNeeded: block.output.count),
            commandText: block.commandText,
        )
        if lastEmitted[index] == meta { return nil }
        lastEmitted[index] = meta
        return .commandBlock(
            index: index,
            exitCode: meta.exitCode,
            durationMS: meta.durationMS,
            complete: meta.complete,
            outputLen: meta.outputLen,
            commandText: meta.commandText,
        )
    }

    /// Retains a COMPLETED block's output in the ring (replacing any prior record for that index),
    /// then evicts oldest-first until both bounds hold.
    private mutating func store(_ block: CommandBlockSegmenter.CommandBlock) {
        let index = UInt32(truncatingIfNeeded: block.index)
        if let i = held.firstIndex(where: { $0.index == index }) {
            totalOutputBytes -= held[i].output.count
            held[i].output = block.output
            totalOutputBytes += block.output.count
        } else {
            held.append(Held(index: index, output: block.output))
            totalOutputBytes += block.output.count
        }
        evictToBounds()
    }

    /// Evicts the OLDEST retained blocks until both the count and total-bytes bounds hold. Always
    /// keeps at least the most-recent block even if it alone exceeds the byte bound (so a single
    /// huge block is still servable; the segmenter already caps a block's output at 256 KiB). The
    /// evicted block's dedup record is dropped too (an evicted index re-emits if it ever recurs —
    /// it never will, indices are monotonic — and the map stays bounded by the ring size).
    private mutating func evictToBounds() {
        while held.count > maxBlocks, !held.isEmpty {
            evictOldest()
        }
        while totalOutputBytes > maxTotalOutputBytes, held.count > 1 {
            evictOldest()
        }
    }

    private mutating func evictOldest() {
        let gone = held.removeFirst()
        totalOutputBytes -= gone.output.count
        lastEmitted[gone.index] = nil
    }

    // MARK: - Test seams

    /// The indices currently retained in the ring (oldest first) — for ring/eviction tests.
    var retainedIndicesForTesting: [UInt32] { held.map(\.index) }
    /// The total retained output bytes — for byte-bound eviction tests.
    var totalOutputBytesForTesting: Int { totalOutputBytes }
}
