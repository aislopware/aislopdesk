import Foundation
import RworkProtocol

/// Drives reconnection for a ``RworkClient`` after the transport drops.
///
/// iOS tears down TCP a few seconds after backgrounding, and any network blip can drop
/// the connection mid-session. On a drop this manager re-`connect`s the same
/// ``RworkClient`` — which presents the preserved `sessionID` + `highestContiguousSeq`
/// in the new hello, so the host's ``ReplayBuffer`` replays the missing tail and the
/// resume is **byte-exact** (no tmux). The client dedups the replayed tail by seq, so
/// the splice is gap-free and dup-free.
///
/// ### Policy
/// - **Trigger:** a `RworkClient.Event.disconnected` (transport FIN/failure) that is not
///   the result of a deliberate ``RworkClient/pause()``/``close()``.
/// - **Backoff:** exponential, starting at ``Backoff/initial`` (250ms),
///   multiplying by ``Backoff/multiplier`` (2.0), capped at ``Backoff/maximum``
///   (**2s** — DECISIONS §reconnect: a coding session wants a *fast* re-grab, not a
///   minutes-long backoff). Each successful reconnect resets the delay.
/// - **Lifecycle:** `start()` launches a supervising task that consumes the client's
///   `events`; `stop()` cancels it. App background/foreground is handled by the client's
///   `pause()`/`resume()` seam (WF-8), not here.
///
/// Lifecycle hooks (UIKit `didEnterBackground` + `beginBackgroundTask`) belong to the
/// client app target; this type owns only the retry policy + supervising task.
///
/// All mutable state is held inside the supervising `Task` closure / actor-isolated
/// ``RworkClient``; this type stores only immutable `let`s, so it is `Sendable`.
public final class ReconnectManager: Sendable {
    /// Exponential-backoff schedule between reconnect attempts.
    public struct Backoff: Sendable, Equatable {
        public var initial: Duration
        public var maximum: Duration
        public var multiplier: Double

        public init(
            initial: Duration = .milliseconds(250),
            maximum: Duration = .seconds(2),
            multiplier: Double = 2.0
        ) {
            self.initial = initial
            self.maximum = maximum
            self.multiplier = multiplier
        }

        /// The next delay after `current`, capped at ``maximum``.
        func next(after current: Duration) -> Duration {
            let scaled = current * multiplier
            return scaled > maximum ? maximum : scaled
        }
    }

    public let backoff: Backoff
    private let client: RworkClient
    private let onLog: (@Sendable (String) -> Void)?

    public init(
        client: RworkClient,
        backoff: Backoff = Backoff(),
        onLog: (@Sendable (String) -> Void)? = nil
    ) {
        self.client = client
        self.backoff = backoff
        self.onLog = onLog
    }

    /// Launches the supervising task that watches the client's `events` and reconnects
    /// on a disconnect. Returns the `Task` so the caller can `await`/cancel it; also
    /// retain it via ``stop()``-able handle if preferred.
    @discardableResult
    public func start(host: String, port: UInt16) -> Task<Void, Never> {
        let client = self.client
        let backoff = self.backoff
        let onLog = self.onLog
        return Task {
            for await event in client.events {
                guard case let .disconnected(reason) = event else { continue }
                // A deliberate pause/close also yields `.disconnected`; only reconnect if
                // the client still wants to be connected (not paused, not closed).
                if await client.isPaused { continue }
                onLog?("reconnect: transport dropped (\(reason)) — retrying")
                await Self.reconnectLoop(client: client, host: host, port: port, backoff: backoff, onLog: onLog)
            }
        }
    }

    /// One reconnect campaign: retry `connect` with exponential backoff until it
    /// succeeds (or the task is cancelled). The client preserves `sessionID` + seq, so
    /// each attempt is a RETURNING_CLIENT resume.
    static func reconnectLoop(
        client: RworkClient,
        host: String,
        port: UInt16,
        backoff: Backoff,
        onLog: (@Sendable (String) -> Void)?
    ) async {
        var delay = backoff.initial
        var attempt = 0
        while !Task.isCancelled {
            // If the app paused mid-campaign, stop retrying — resume() will reconnect.
            if await client.isPaused { return }
            attempt += 1
            do {
                try await client.connect(host: host, port: port)
                onLog?("reconnect: resumed after \(attempt) attempt(s)")
                return
            } catch {
                onLog?("reconnect: attempt \(attempt) failed (\(error)); backing off \(delay)")
                try? await Task.sleep(for: delay)
                delay = backoff.next(after: delay)
            }
        }
    }

    /// Drives a single reconnect campaign synchronously (used by tests and callers that
    /// want to await the resume rather than run the supervising loop). Reuses the
    /// client's preserved `sessionID` + seq.
    public func reconnect(host: String, port: UInt16) async throws {
        var delay = backoff.initial
        var lastError: Error?
        for attempt in 1...64 {
            if Task.isCancelled { throw CancellationError() }
            do {
                try await client.connect(host: host, port: port)
                onLog?("reconnect: resumed after \(attempt) attempt(s)")
                return
            } catch {
                lastError = error
                onLog?("reconnect: attempt \(attempt) failed (\(error)); backing off \(delay)")
                try? await Task.sleep(for: delay)
                delay = backoff.next(after: delay)
            }
        }
        throw lastError ?? ClientError.reconnectExhausted
    }
}
