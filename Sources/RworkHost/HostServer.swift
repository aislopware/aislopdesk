import Foundation
import RworkProtocol
import RworkTransport

/// The host daemon's listener: accepts client connections, performs the
/// `hello`/`helloAck` handshake, and maps each connection to a new or resuming
/// ``HostSession``.
///
/// The host **decides `RETURNING_CLIENT`** (ET `Connection.cpp`): on `hello` with a
/// known non-zero `sessionID`, it resumes that session and replays
/// `seq > lastReceivedSeq`; an all-zero `sessionID` (or unknown id) starts a fresh
/// session.
///
/// - Note: Documented seam for WF-3. Drives `rwork-hostd`. Bodies are stubs.
public final class HostServer: @unchecked Sendable {
    /// TCP port the daemon listens on for the DATA channel (CONTROL is paired in WF-2/3).
    public let port: UInt16

    /// Live sessions keyed by id (for `RETURNING_CLIENT` resume).
    public private(set) var sessions: [UUID: HostSession] = [:]

    public init(port: UInt16) {
        self.port = port
    }

    /// Starts listening. Each accepted ``RworkConnection`` is handshaked and routed
    /// to a session.
    public func run() async throws {
        // TODO(WF-3): NWListener on `port`; accept DATA+CONTROL; read `hello`;
        //   decide RETURNING_CLIENT; reply `helloAck`; attach HostSession.
        throw HostError.notImplemented("HostServer.run — WF-3")
    }
}
