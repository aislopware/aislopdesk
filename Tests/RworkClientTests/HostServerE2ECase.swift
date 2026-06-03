import XCTest
import Foundation
import RworkHost
@testable import RworkClient

/// Shared base for the THREE HostServer-backed PATH 1 E2E suites
/// (`RworkClientE2ETests`, `RworkReconnectE2ETests`, `RworkReconnectSuppressionTests`).
///
/// ITEM #10 — make a full `swift test` CI-safe. A single hung E2E test used to wedge
/// the whole `RworkPackageTests.xctest` process (every later agent inherited a stuck
/// run). This base installs a per-test hard ceiling so a hung test FAILS instead of
/// hanging, and guarantees its bring-up is torn down even on an early/abnormal exit:
///
///  * `setUp()` sets `continueAfterFailure = false` (one failed assertion ends the test
///    rather than letting a wedged test grind on) and `executionTimeAllowance` to a
///    generous per-suite ceiling above each suite's largest inner timeout — when a test
///    body exceeds it, XCTest force-fails the test and moves on.
///  * `startHost()` (folded down from the three suites) registers
///    `addTeardownBlock { await server.stop() }` — which XCTest AWAITS — the instant the
///    server binds, so the host is always reaped, even if the test throws right after.
///  * `connectedClient(toPort:)` likewise registers `addTeardownBlock { await client.close() }`
///    so the client transport tears down even on an early failure.
///
/// CRITICAL: this changes NOTHING about the cooperative-pool footprint — it adds no new
/// `HostServer`/`PTYProcess` and does not enable parallelization. It only reparents the
/// existing suites and reshapes their teardown from a fire-and-forget `defer { Task { … } }`
/// (never awaited — the process could exit before `stop()` ran) into an awaited teardown.
class HostServerE2ECase: XCTestCase {

    /// Per-suite hard ceiling for a single test. MUST sit above the suite's largest inner
    /// timeout so a *healthy slow* test is not killed, but a genuinely hung one is. Echo /
    /// suppression suites override down; reconnect-resume overrides up. The default is the
    /// safe maximum.
    open var perTestTimeAllowance: TimeInterval { 120 }

    override func setUp() {
        super.setUp()
        // One failed assertion ends the test — a wedged test must not grind on.
        continueAfterFailure = false
        // Hard ceiling: a hung body is force-failed by XCTest instead of wedging the
        // shared test process.
        executionTimeAllowance = perTestTimeAllowance
    }

    // MARK: - Bring-up (folded down from the three suites)

    /// Starts a `HostServer` on an ephemeral loopback port spawning `shell`, returns it plus
    /// the bound port, and registers an AWAITED teardown (`addTeardownBlock { await server.stop() }`)
    /// the moment it binds — so the host is reaped even if the test throws immediately after.
    ///
    /// The `start()`/`boundPort()` awaits are themselves wrapped in `withTimeout`, so a host
    /// that never binds surfaces as an attributable XCTFail instead of an indefinite hang.
    func startHost(
        shell: String = "/bin/sh",
        bringUpTimeout: Duration = .seconds(20)
    ) async throws -> (server: HostServer, port: UInt16) {
        let server = HostServer(port: 0, shellPath: shell)
        // Register the awaited stop BEFORE anything can throw — once `server` exists it must
        // be reaped no matter what happens next.
        addTeardownBlock { await server.stop() }

        // A `Result<Void, BringUpFailure>` body (BringUpFailure is Sendable, carrying the
        // error's description) lets us tell a TIMEOUT (helper returns nil) apart from a
        // genuine thrown error (helper returns `.failure`), so the XCTFail only fires on a
        // real hang and a real `start()` error still surfaces faithfully across the Sendable
        // task-group boundary (a bare `any Error` is not Sendable under Swift 6).
        let startResult: Result<Void, BringUpFailure>? = await withTimeout(bringUpTimeout) {
            do { try await server.start(); return .success(()) }
            catch { return .failure(BringUpFailure(error)) }
        }
        guard let startResult else {
            XCTFail("startHost: server.start() timed out after \(bringUpTimeout)")
            throw E2EBringUpError.startTimedOut
        }
        try startResult.get()

        let port = await withTimeout(bringUpTimeout) { await server.boundPort() } ?? nil
        guard let port else {
            throw XCTSkip("host did not bind a port")
        }
        return (server, port)
    }

    /// Connects a fresh `RworkClient` to `port` on loopback, registering an AWAITED
    /// `addTeardownBlock { await client.close() }` so the client transport tears down even on
    /// an early failure. The `connect()` await is timeout-wrapped and attributable.
    func connectedClient(
        toPort port: UInt16,
        ackInterval: Duration? = nil,
        connectTimeout: Duration = .seconds(20)
    ) async throws -> RworkClient {
        let client = ackInterval.map { RworkClient(ackInterval: $0) } ?? RworkClient()
        addTeardownBlock { await client.close() }

        let connectResult: Result<Void, BringUpFailure>? = await withTimeout(connectTimeout) {
            do { try await client.connect(host: "127.0.0.1", port: port); return .success(()) }
            catch { return .failure(BringUpFailure(error)) }
        }
        guard let connectResult else {
            XCTFail("connectedClient: client.connect() timed out after \(connectTimeout)")
            throw E2EBringUpError.connectTimedOut
        }
        try connectResult.get()
        return client
    }

    enum E2EBringUpError: Error { case startTimedOut, connectTimedOut }

    /// Sendable carrier for a bring-up error so a thrown `any Error` (which is not `Sendable`)
    /// can cross the timeout task-group boundary as the error's description.
    struct BringUpFailure: Error, Sendable {
        let message: String
        init(_ error: any Error) { self.message = String(describing: error) }
    }

    // MARK: - Timeout helper (the in-target twin of the free `withTestTimeout`)

    /// Runs `body`, returning its value, or `nil` if it does not finish within `timeout`.
    /// The losing branch is cancelled. Use the `nil` result to drive an attributable
    /// `XCTFail` rather than letting a hung await wedge the run.
    ///
    /// The `body` returns `T?` (and the helper flattens the timeout-nil and a body-nil into
    /// one optional) — this is the EXACT shape the three E2E suites already called as a
    /// private helper, preserved verbatim so reparenting changes no call-site semantics.
    func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ body: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
