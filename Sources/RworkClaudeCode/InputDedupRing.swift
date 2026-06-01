import Foundation

/// Suppresses the PTY's echo of bytes the compose-box (input-box B1) just sent, so a
/// prompt the user typed in the overlay is not shown twice (doc 14 §"Thực thi B1" —
/// "Duplicate prompt dedup (BẮT BUỘC, bài học Happy/Happier"). The compose-box writes
/// input to the PTY *and* optimistically renders it; the PTY then echoes the same bytes
/// back in the output stream. This ring records recently-sent input and strips the
/// echoed copy out of incoming output.
///
/// ## Matching strategy — hold-and-confirm (no optimistic drops)
/// We keep a bounded ring of the bytes we expect the PTY to echo back, oldest first. On
/// output, we match bytes against the *front* of that expected echo, but we never drop a
/// byte until the match is **confirmed**:
/// - A byte that matches the next expected-echo byte is **held** (tentatively suppressed)
///   and advances the match cursor.
/// - When the held run completes the whole pending echo, the held bytes are **dropped**
///   (confirmed echo) and the ring resets.
/// - A byte that breaks the match means the held run was *not* the echo after all: the
///   held bytes are **flushed back** to the passthrough, the cursor resets, and the
///   breaking byte is re-processed from the start of the pending echo.
///
/// This is the key correctness property: a byte that merely *shares a prefix* with the
/// expected echo (e.g. the `l` in `total` vs. an expected `ls`) is held, then flushed
/// intact once the next byte diverges — it is never silently eaten.
///
/// It handles: an exact echo (`ls -la\n` → `ls -la\r\n`), a **partial echo split across
/// chunks** (the held run + cursor persist between ``filter(_:)`` calls), and non-echo
/// output (flushed straight through). We normalize the common terminal newline echo
/// (`\n` sent → `\r\n` echoed, and a bare `\r` echo) so the line-ending transform a PTY
/// applies does not defeat the match.
///
/// ## Ring bound + eviction
/// At most ``capacity`` *bytes* of pending (not-yet-echoed) input are retained, FIFO.
/// When a new send would exceed the bound, the oldest pending bytes are evicted (their
/// echo, if it ever arrives, will then simply pass through — correctness over
/// completeness: we never *hold* output waiting for an echo, and we never suppress
/// non-echo content).
public final class InputDedupRing {
    /// Maximum number of pending (sent-but-not-yet-echoed) bytes retained. A compose-box
    /// prompt is small; this bounds memory and staleness. Default 4096.
    public let capacity: Int

    /// The pending echo we still expect to see in the output, oldest byte first.
    private var pending: [UInt8] = []
    /// How many bytes at the front of `pending` we have already matched against output.
    private var matched: Int = 0

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Number of pending (un-echoed) bytes currently retained (diagnostics / tests).
    public var pendingCount: Int { pending.count - matched }

    // MARK: Send

    /// Records bytes the compose-box just wrote to the PTY. Their echo will be suppressed
    /// when it appears in the output. Normalizes the byte form so newline-echo transforms
    /// still match (see `expectedEchoBytes`).
    public func recordSent(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        // Append the expected echo of these bytes. We do NOT compact away a tentative
        // (unconfirmed) match prefix here — those held bytes might still need to be
        // flushed back if the in-flight match diverges. Compaction happens only on a
        // confirmed full match (which clears `pending`) or via FIFO eviction below.
        pending.append(contentsOf: expectedEchoBytes(Array(bytes)))

        // Evict oldest pending bytes beyond the bound (FIFO). If eviction would cut into
        // the already-held match prefix, also retreat the cursor so it stays valid.
        if pending.count > capacity {
            let drop = pending.count - capacity
            pending.removeFirst(drop)
            matched = max(0, matched - drop)
        }
    }

    /// Convenience overload.
    public func recordSent(_ bytes: [UInt8]) { recordSent(Data(bytes)) }

    // MARK: Filter

    /// Filters an incoming output chunk: drops bytes that are the confirmed echo of
    /// recently-sent input and returns the remaining (non-echo) bytes to render. Non-echo
    /// output passes through untouched. See the type doc for the hold-and-confirm model.
    public func filter(_ output: Data) -> Data {
        guard !pending.isEmpty else { return output }

        var passthrough = [UInt8]()
        passthrough.reserveCapacity(output.count)

        for byte in output {
            stepFilter(byte, into: &passthrough)
        }

        return Data(passthrough)
    }

    private func stepFilter(_ byte: UInt8, into passthrough: inout [UInt8]) {
        if pending.isEmpty {
            passthrough.append(byte)
            return
        }
        if byte == pending[matched] {
            // Tentative match — hold it (do NOT emit yet) and advance.
            matched += 1
            if matched == pending.count {
                // Whole pending echo confirmed: drop the held run, reset the ring.
                pending.removeAll(keepingCapacity: true)
                matched = 0
            }
        } else {
            // Mismatch: the bytes we held were NOT echo. Flush them back intact, then
            // re-process this byte against a reset cursor (it may start a fresh match).
            if matched > 0 {
                passthrough.append(contentsOf: pending[0..<matched])
                matched = 0
                stepFilter(byte, into: &passthrough)
            } else {
                // Nothing held and the very first byte diverges — pass it straight.
                passthrough.append(byte)
            }
        }
    }

    /// Convenience overload returning bytes.
    public func filter(_ output: [UInt8]) -> [UInt8] {
        Array(filter(Data(output)))
    }

    /// Clears all pending state (e.g. on a mode change or focus loss).
    public func reset() {
        pending.removeAll(keepingCapacity: true)
        matched = 0
    }

    // MARK: Newline normalization

    /// The byte form we expect the PTY to echo for a given sent run. A PTY in cooked
    /// mode (`ONLCR`) echoes a sent `\n` as `\r\n`, and the line discipline often echoes
    /// an Enter (`\r`) as `\r\n` too. We expand both so the echo matches regardless.
    private func expectedEchoBytes(_ sent: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(sent.count + 4)
        for byte in sent {
            if byte == 0x0A || byte == 0x0D { // '\n' or '\r'
                out.append(0x0D) // '\r'
                out.append(0x0A) // '\n'
            } else {
                out.append(byte)
            }
        }
        return out
    }
}
