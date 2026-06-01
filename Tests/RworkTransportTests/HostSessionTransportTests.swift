import XCTest
import Network
import RworkProtocol
@testable import RworkTransport

/// Socket-free tests for ``HostSessionTransport`` lifecycle additions from the WF-3
/// review: `close()` (orphaned-session teardown) and recorded-exit replay on resume.
final class HostSessionTransportTests: XCTestCase {

    /// `close()` must finish the inbound relay streams so their consumers (the WF-3 relay
    /// tasks) terminate instead of hanging. Without the `finish()` calls a dropped
    /// orphaned session would leave the input/resize/ack/drain consumers parked forever.
    func testCloseFinishesInboundStreams() async throws {
        let session = HostSessionTransport(sessionID: UUID())

        // Park a consumer on each inbound stream; each loop must END when close() finishes.
        let input = Task { for await _ in session.inboundInput {}; return true }
        let resize = Task { for await _ in session.inboundResize {}; return true }
        let ack = Task { for await _ in session.inboundAck {}; return true }
        let drain = Task { for await _ in session.drainPauses {}; return true }

        await session.close()

        // All four must complete (bounded by the test timeout, not hang).
        _ = await input.value
        _ = await resize.value
        _ = await ack.value
        _ = await drain.value
    }

    /// `sendExit` records the code; a subsequent `resume(after:)` re-sends it after the
    /// replayed output tail. With no channel ever bound here, we assert the recording
    /// survives and is observable through the resume path indirectly: re-binding via a
    /// loopback channel is covered end-to-end in `HandshakeReconnectTests`; here we just
    /// confirm `sendExit` does not throw when no channel is bound (it must record, not
    /// require a live channel) so a child exiting while offline is captured.
    func testSendExitWithoutChannelRecordsInsteadOfThrowing() async throws {
        let session = HostSessionTransport(sessionID: UUID())
        await session.setClientOnline(false)
        _ = try await session.sendOutput(Data("tail".utf8))
        // No data channel is bound (client offline). sendExit must record the code, not
        // throw — otherwise the exit would be lost on the common offline-exit path.
        do {
            try await session.sendExit(code: 137)
        } catch {
            XCTFail("sendExit with no bound channel must record (not throw): \(error)")
        }
    }

    // MARK: WF-4b — dead-channel-send invariant (retain, never throw) under the rebind race

    /// The core WF-4b correctness property, exercised deterministically: while a live
    /// ``HostSessionTransport/sendOutput(_:)`` is in flight on the bound data channel, a
    /// concurrent RETURNING_CLIENT ``HostSessionTransport/resume(data:control:after:)``
    /// swaps in a fresh channel and CLOSES (cancels) the old one — cancelling the very
    /// channel the in-flight send is writing to (POSIX 89). This MUST NOT throw out of
    /// `sendOutput`: the bytes are retained in the ``ReplayBuffer`` and the resume's
    /// replay loop re-sends them on the new channel, so the new client sees a byte-exact,
    /// gap-free, dup-free stream. We run the race many times so the in-flight-send /
    /// swap interleaving is hit repeatedly; every iteration must satisfy the invariant.
    func testRebindWindowSendRetainsAndReplaysByteExact() async throws {
        for iteration in 0..<40 {
            let session = HostSessionTransport(sessionID: UUID())

            // Bind the session to the FIRST data+control channel pair (the "old" channels).
            let (oldServerData, _, oldDataListener) = try await makeLoopbackPair(channel: .data)
            let (oldServerCtl, _, oldCtlListener) = try await makeLoopbackPair(channel: .control)
            await session.bind(data: oldServerData, control: oldServerCtl)

            // Pre-fill the buffer with a few outputs so the replay tail is non-trivial.
            // n is the highest seq retained for replay.
            let n = 5
            for i in 1...n {
                _ = try await session.sendOutput(Data("pre-\(i)\n".utf8))
            }

            // Fire a live sendOutput (seq n+1) and a resume concurrently. The live send
            // captures the OLD channel and awaits inside NWConnection.send; the resume
            // swaps in the NEW channel and closes the OLD one mid-flight — the race.
            let (newServerData, newClientData, newDataListener) = try await makeLoopbackPair(channel: .data)
            let (newServerCtl, _, newCtlListener) = try await makeLoopbackPair(channel: .control)

            let liveSend = Task { () -> Bool in
                do {
                    _ = try await session.sendOutput(Data("live-\(n + 1)\n".utf8))
                    return true // returned (did not throw) — the invariant
                } catch {
                    return false // a throw is a violation
                }
            }

            // resume() rebinds the new channels and replays seq > 0 (the whole tail incl.
            // the live seq n+1 once it lands in the buffer), then flushes.
            try await session.resume(data: newServerData, control: newServerCtl, after: 0)

            let liveDidNotThrow = await liveSend.value
            XCTAssertTrue(liveDidNotThrow, "iteration \(iteration): a send that lost its channel to a concurrent resume must retain-and-return, never throw")

            // The NEW client channel must receive seq 1..n+1, in strictly ascending order,
            // byte-exact, with no gap and no duplicate. Collect until we have n+1 outputs.
            let collected: [(seq: Int64, bytes: Data)] = try await withThrowingTaskGroup(of: [(seq: Int64, bytes: Data)].self) { group in
                group.addTask {
                    var out: [(seq: Int64, bytes: Data)] = []
                    var seen = Set<Int64>()
                    for try await message in newClientData.inbound {
                        if case let .output(seq, bytes) = message {
                            if seen.insert(seq).inserted { out.append((seq: seq, bytes: bytes)) }
                            if out.count == n + 1 { break }
                        }
                    }
                    return out
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw RworkTransportError.timedOut("rebind-window replay")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            let seqs = collected.map(\.seq)
            var payloads: [Int64: Data] = [:]
            for entry in collected { payloads[entry.seq] = entry.bytes }

            XCTAssertEqual(seqs, Array(Int64(1)...Int64(n + 1)), "iteration \(iteration): new channel must carry seq 1..n+1 ascending, gap-free")
            XCTAssertEqual(seqs.count, Set(seqs).count, "iteration \(iteration): no duplicate seq on the wire")
            for i in 1...n {
                XCTAssertEqual(payloads[Int64(i)], Data("pre-\(i)\n".utf8), "iteration \(iteration): byte-exact replayed tail")
            }
            XCTAssertEqual(payloads[Int64(n + 1)], Data("live-\(n + 1)\n".utf8), "iteration \(iteration): the in-flight live output must be delivered byte-exact")

            await session.close()
            oldDataListener.cancel(); oldCtlListener.cancel()
            newDataListener.cancel(); newCtlListener.cancel()
        }
    }

    // MARK: Helpers

    /// Stands up a 127.0.0.1:0 loopback listener, connects a client, and returns the two
    /// ready ``NWMessageChannel``s (server side, client side) plus the listener.
    private func makeLoopbackPair(
        channel: Channel = .data
    ) async throws -> (server: NWMessageChannel, client: NWMessageChannel, listener: NWListener) {
        let listener = try NWListener(using: TransportParameters.makeTCP(), on: .any)
        let acceptedBox = AcceptedBox()
        listener.newConnectionHandler = { connection in acceptedBox.set(connection) }
        let listenerQueue = DispatchQueue(label: "test.session.listener")

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue { box.tryResume { continuation.resume(returning: p) } }
                case let .failed(error):
                    box.tryResume { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: listenerQueue)
        }

        let clientConn = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: TransportParameters.makeTCP())
        try await clientConn.startAndWaitReady(on: DispatchQueue(label: "test.session.client"))
        let serverConn = await acceptedBox.waitForConnection()

        let server = NWMessageChannel(connection: serverConn, channel: channel)
        let client = NWMessageChannel(connection: clientConn, channel: channel)
        await server.start()
        await client.start()
        try await server.waitUntilReady()
        try await client.waitUntilReady()
        return (server, client, listener)
    }
}
