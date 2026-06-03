import Foundation

/// Host-side replay buffer + live fan-out for the inspector event stream.
///
/// The ``InspectorEngine`` produces ONE `AsyncStream<InspectorEvent>` (a stream can be
/// iterated exactly once). A second inspector connection — or a reconnect — needs the
/// *full* history from the beginning, then the live tail. ``InspectorReplayLog`` is the
/// seam that makes that possible: it consumes the engine's single stream exactly once
/// (via ``ingest(_:)``), appends every event into an ordered `history`, and lets any
/// number of subscribers ask for `subscribe(fromSeq:)` — a full (or resumed) replay
/// followed by the live tail.
///
/// ## Sequence numbering
/// `history` is append-only, so the array index *is* the sequence number: `history[i]`
/// is event `seq == i`. This matches the `InspectorWire` `Int64 fromSeq` semantics —
/// the client subscribes `fromSeq: 0` for a full replay, or `fromSeq: N` to resume after
/// a reconnect (skipping the `0..<N` prefix it already rendered). (Resolves BUG-B: the
/// decoded `fromSeq` is now actually *used* to slice the replay, not ignored — a
/// reconnecting client no longer gets a blank inspector after any drop.)
///
/// ## Snapshot-then-attach atomicity
/// ``subscribe(fromSeq:)`` snapshots `history[fromSeq...]` AND attaches a live
/// continuation in ONE atomic actor step (a single non-suspending method body). Because
/// the actor cannot interleave another `ingest` between the snapshot and the attach, no
/// event can slip through the gap: an event appended *before* the call is in the
/// snapshot; one appended *after* lands on the freshly-attached continuation. The
/// returned stream replays the snapshot in order, then forwards live events.
///
/// Per-subscriber continuations live in `[UUID: Continuation]` and are removed on
/// stream termination (cancel / client gone).
///
/// Read-only by construction: the only input is the engine's observation stream; there
/// is no path back to the agent.
public actor InspectorReplayLog {
    /// Append-only event history. `history[i]` is `seq == i`.
    private var history: [InspectorEvent] = []

    /// Live subscribers, keyed by a per-subscription id so termination can detach the
    /// right one.
    private var subscribers: [UUID: AsyncStream<InspectorEvent>.Continuation] = [:]

    /// `true` once the upstream engine stream finished (host shutdown). A subscription
    /// created after this still gets the full replay, then finishes immediately (no live
    /// tail will ever arrive).
    private var finished = false

    public init() {}

    /// Consumes the engine's single ordered event stream exactly once: appends each
    /// event to `history` and fans it out to every live subscriber. Call this ONCE with
    /// `engine.events` (the engine vends a single-shot `AsyncStream`).
    ///
    /// `nonisolated`: the consume loop runs off the actor so each `await self.append(_:)`
    /// is a genuine actor hop (the append + fan-out stays serialised on the actor).
    public nonisolated func ingest(_ stream: AsyncStream<InspectorEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
            await self?.markFinished()
        }
    }

    /// Appends one event to the history and pushes it to every live subscriber. One
    /// atomic actor step, so a concurrent ``subscribe(fromSeq:)`` either sees this event
    /// in its snapshot (if it ran first) or receives it live (if it ran after) — never
    /// both, never neither.
    public func append(_ event: InspectorEvent) {
        history.append(event)
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Marks the upstream stream finished and closes every live subscriber. Idempotent.
    public func markFinished() {
        guard !finished else { return }
        finished = true
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    /// The number of events recorded so far (diagnostics / tests).
    public var historyCount: Int { history.count }

    /// Subscribes from `fromSeq`: replays `history[fromSeq...]` in order, then streams
    /// live events. `fromSeq == 0` = full replay then live; a higher value resumes after a
    /// reconnect, skipping the already-rendered prefix.
    ///
    /// The snapshot + the live-continuation attach happen in this single, non-suspending
    /// actor step, so no event slips between them (see the type doc). A `fromSeq` past the
    /// end of `history` (a future resume point) yields an empty replay then the live tail.
    public func subscribe(fromSeq: Int64) -> AsyncStream<InspectorEvent> {
        // Clamp to the valid range: a negative or out-of-range fromSeq must not crash the
        // slice. A fromSeq beyond `history.count` means "I already have everything" →
        // empty replay.
        let lowerBound = max(0, min(Int(fromSeq), history.count))
        let snapshot = Array(history[lowerBound...])

        // If the upstream already finished, there will be no live tail: deliver the
        // snapshot and finish.
        if finished {
            return AsyncStream { continuation in
                for event in snapshot {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        let id = UUID()
        // Build the stream and attach the continuation in the SAME atomic actor step as
        // the snapshot above — between `snapshot` being read and `subscribers[id]` being
        // set, the actor does not suspend, so no `append` can interleave.
        let stream = AsyncStream<InspectorEvent> { continuation in
            for event in snapshot {
                continuation.yield(event)
            }
            // Detach on termination (cancel / client gone). Hops back onto the actor.
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
            subscribers[id] = continuation
        }
        return stream
    }

    /// Detaches a subscriber (its stream terminated). No-op if already gone.
    public func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// The number of currently-attached live subscribers (diagnostics / tests).
    public var subscriberCount: Int { subscribers.count }
}
