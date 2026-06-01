import Foundation
import RworkProtocol

/// Drives reconnection for a ``ClientConnection`` after the transport drops.
///
/// iOS tears down TCP a few seconds after backgrounding; on `.failed` we build a
/// fresh connection and re-`hello` with the last `sessionID` and `lastReceivedSeq`,
/// so the host's ``ReplayBuffer`` replays the missing tail and the resume is
/// byte-exact (no tmux).
///
/// Lifecycle hooks (UIKit `didEnterBackground` + `beginBackgroundTask`) belong to
/// the client app target; this type owns only the retry policy and resume state.
///
/// - Note: Documented seam for WF-4. Bodies are stubs.
public final class ReconnectManager: @unchecked Sendable {
    /// Exponential-backoff schedule between reconnect attempts.
    public struct Backoff: Sendable, Equatable {
        public var initial: Duration
        public var maximum: Duration
        public var multiplier: Double

        public init(
            initial: Duration = .milliseconds(250),
            maximum: Duration = .seconds(10),
            multiplier: Double = 2.0
        ) {
            self.initial = initial
            self.maximum = maximum
            self.multiplier = multiplier
        }
    }

    public let backoff: Backoff
    private let connection: ClientConnection

    public init(connection: ClientConnection, backoff: Backoff = Backoff()) {
        self.connection = connection
        self.backoff = backoff
    }

    /// Attempts to reconnect to `host:port`, reusing the existing `sessionID` and
    /// `lastReceivedSeq` so the host replays the tail. Retries with ``Backoff``.
    public func reconnect(host: String, port: UInt16) async throws {
        // TODO(WF-4): loop with backoff; connection.connect(host:port:resume:)
        //   using the existing sessionID; surface success / give-up.
        throw ClientError.notImplemented("ReconnectManager.reconnect — WF-4")
    }
}
