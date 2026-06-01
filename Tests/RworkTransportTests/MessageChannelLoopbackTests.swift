import XCTest
import Network
import RworkProtocol
@testable import RworkTransport

/// Loopback tests for ``NWMessageChannel`` over real `NWConnection`s on 127.0.0.1
/// (ephemeral port). Verifies that framing survives TCP coalescing (a burst of small
/// frames in one read) and fragmentation (one large frame split across reads).
final class MessageChannelLoopbackTests: XCTestCase {

    /// Stands up a listener on 127.0.0.1:0, connects a client, and returns the two
    /// ready ``NWMessageChannel``s (server side, client side) plus the listener to keep
    /// alive / cancel.
    private func makeLoopbackPair(
        channel: Channel = .data
    ) async throws -> (server: NWMessageChannel, client: NWMessageChannel, listener: NWListener) {
        let listener = try NWListener(using: TransportParameters.makeTCP(), on: .any)

        // Capture the first accepted connection.
        let acceptedBox = AcceptedBox()
        listener.newConnectionHandler = { connection in
            acceptedBox.set(connection)
        }
        let listenerQueue = DispatchQueue(label: "test.listener")

        // Wait for the listener to be ready and learn its port.
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ReadyBox()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        box.tryResume { continuation.resume(returning: p) }
                    }
                case let .failed(error):
                    box.tryResume { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: listenerQueue)
        }

        // Connect the client.
        let clientConn = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: TransportParameters.makeTCP())
        try await clientConn.startAndWaitReady(on: DispatchQueue(label: "test.client"))

        // Wait until the server accepted the connection.
        let serverConn = await acceptedBox.waitForConnection()

        let server = NWMessageChannel(connection: serverConn, channel: channel)
        let client = NWMessageChannel(connection: clientConn, channel: channel)
        await server.start()
        await client.start()
        try await server.waitUntilReady()
        try await client.waitUntilReady()
        return (server, client, listener)
    }

    func testSmallBurstCoalescesAndArrivesInOrder() async throws {
        let (server, client, listener) = try await makeLoopbackPair()
        defer { listener.cancel() }

        // Burst of many small frames from client → server, sent back-to-back so the
        // kernel is likely to coalesce them into one read on the server side.
        let count = 200
        for i in 0..<count {
            try await client.send(.input(Data("k\(i);".utf8)))
        }

        var received: [Data] = []
        for try await message in server.inbound {
            guard case let .input(bytes) = message else { return XCTFail("expected input, got \(message)") }
            received.append(bytes)
            if received.count == count { break }
        }
        let expected = (0..<count).map { Data("k\($0);".utf8) }
        XCTAssertEqual(received, expected, "all coalesced small frames must arrive intact and in order")
    }

    func testLargeFrameFragmentsAndReassembles() async throws {
        let (server, client, listener) = try await makeLoopbackPair()
        defer { listener.cancel() }

        // A multi-hundred-KB payload forces TCP segmentation across many reads.
        var big = Data(capacity: 512 * 1024)
        for i in 0..<(512 * 1024) { big.append(UInt8(i & 0xFF)) }
        try await client.send(.output(seq: 1, bytes: big))

        var got: WireMessage?
        for try await message in server.inbound {
            got = message
            break
        }
        guard case let .output(seq, bytes)? = got else { return XCTFail("expected output, got \(String(describing: got))") }
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(bytes.count, big.count)
        XCTAssertEqual(bytes, big, "fragmented large frame must reassemble byte-exact")
    }

    func testMixedTrafficBothDirections() async throws {
        let (server, client, listener) = try await makeLoopbackPair()
        defer { listener.cancel() }

        // Client → server: a large frame then small frames.
        var big = Data(count: 200 * 1024)
        big[0] = 0xAB; big[big.count - 1] = 0xCD
        try await client.send(.output(seq: 1, bytes: big))
        for i in 0..<50 { try await client.send(.input(Data("s\(i)".utf8))) }

        var received: [WireMessage] = []
        for try await message in server.inbound {
            received.append(message)
            if received.count == 51 { break }
        }
        guard case let .output(_, firstBytes) = received[0] else { return XCTFail("first should be the large output") }
        XCTAssertEqual(firstBytes.count, big.count)
        XCTAssertEqual(firstBytes, big)
        for i in 0..<50 {
            guard case let .input(bytes) = received[i + 1] else { return XCTFail("expected input at \(i+1)") }
            XCTAssertEqual(bytes, Data("s\(i)".utf8))
        }
    }
}

/// Thread-safe holder for the first accepted server-side `NWConnection`.
final class AcceptedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var waiter: CheckedContinuation<NWConnection, Never>?

    func set(_ connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: connection)
        } else {
            self.connection = connection
        }
    }

    func waitForConnection() async -> NWConnection {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if let connection {
                self.connection = nil
                continuation.resume(returning: connection)
            } else {
                self.waiter = continuation
            }
        }
    }
}
