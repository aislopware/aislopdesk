import Foundation
import Network
import RworkProtocol

/// Async bridges over the raw `NWConnection` callback API, used only during the
/// pre-framing association/handshake phase (reading the fixed-size preamble and
/// writing raw preamble bytes). Once the preamble is consumed, the connection is
/// handed to ``NWMessageChannel`` which owns all further I/O.
extension NWConnection {
    /// Starts the connection on `queue` and suspends until it reaches `.ready`.
    /// Throws ``RworkTransportError/connectionFailed(_:)`` if it fails/cancels first.
    func startAndWaitReady(on queue: DispatchQueue) async throws {
        // A small box so the state handler and the continuation share completion state
        // without racing: only the first terminal transition resumes.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
            func tryResume(_ body: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let box = Box()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    box.tryResume { continuation.resume() }
                case let .failed(error):
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.connectionFailed(String(describing: error)))
                    }
                case .cancelled:
                    box.tryResume {
                        continuation.resume(throwing: RworkTransportError.connectionFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            start(queue: queue)
        }
        // Detach the temporary handler; NWMessageChannel installs its own.
        stateUpdateHandler = nil
    }

    /// Writes raw bytes (used for the association preamble) and suspends until the OS
    /// accepts them.
    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RworkTransportError.sendFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads **exactly** `count` bytes (used for the fixed-size association preamble),
    /// suspending until they arrive. Throws if the peer closes first or on I/O error.
    ///
    /// `NWConnection.receive(minimumIncompleteLength:maximumLength:)` with both set to
    /// `count` returns exactly `count` bytes in one shot once they are available, so a
    /// single call suffices for the small fixed preambles.
    func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RworkTransportError.receiveFailed(String(describing: error)))
                    return
                }
                if let data, data.count == count {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: RworkTransportError.connectionFailed("peer closed during preamble"))
                    return
                }
                // Short read without completion shouldn't happen given min==count, but be safe.
                continuation.resume(throwing: RworkTransportError.receiveFailed("short preamble read"))
            }
        }
    }
}
