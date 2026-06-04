import Foundation

/// Errors thrown by the transport layer (distinct from ``RworkProtocol/RworkError``,
/// which is decode-time). These wrap `Network.framework` failures and handshake faults.
public enum RworkTransportError: Error, Equatable, Sendable {
    /// The underlying `NWConnection` failed or was cancelled before/while in use.
    case connectionFailed(String)
    /// A send was attempted on a channel/link that is already `.cancelled`/`.failed` (it is
    /// gone, not a transient send fault). Distinct from ``sendFailed(_:)`` so the relay can
    /// treat it as "client offline → replay on next reconnect" rather than a fatal error.
    case notConnected(String)
    /// `NWConnection.send` reported an error.
    case sendFailed(String)
    /// `NWConnection.receive` reported an error.
    case receiveFailed(String)
    /// The listener failed to start (e.g. port in use).
    case listenerFailed(String)
    /// The handshake did not complete as required (wrong/missing message, version mismatch).
    case handshakeFailed(String)
    /// An operation was attempted on a connection in the wrong state.
    case invalidState(String)
    /// A bounded wait (handshake / readiness) timed out.
    case timedOut(String)
}
