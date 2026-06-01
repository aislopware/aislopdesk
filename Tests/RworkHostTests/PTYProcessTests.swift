#if canImport(Darwin)
import Darwin
#endif
import XCTest
import RworkProtocol
import RworkTransport
@testable import RworkHost

/// WF-3 PTY-level tests: deterministic, headless, no client networking. They drive the
/// `PTYProcess` master fd directly and assert on the bytes the shell produces.
final class PTYProcessTests: XCTestCase {

    // MARK: read helpers

    /// Reads from `fd` until `needle` appears in the accumulated output or `deadline`
    /// passes. Returns the full output read so far. Uses a background blocking read so
    /// the test has a hard timeout independent of the fd.
    private func readUntil(
        fd: Int32,
        needle: String,
        timeout: TimeInterval = 5.0
    ) -> String {
        let sink = ByteSink()
        let done = DispatchSemaphore(value: 0)
        let needleData = Data(needle.utf8)

        let queue = DispatchQueue(label: "test.pty.read")
        queue.async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    let hit = sink.append(buf[0..<n], contains: needleData)
                    if hit { done.signal(); return }
                } else {
                    done.signal(); return
                }
            }
        }

        _ = done.wait(timeout: .now() + timeout)
        return sink.string()
    }

    private func curatedEnv() -> [String: String] {
        // Force a deterministic TERM and locale for the tests.
        var env = HostEnvironment.curated()
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: Tests

    func testPTYRoundTripPrintf() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "printf rwork-ok"], environment: curatedEnv())
        XCTAssertGreaterThanOrEqual(pty.masterFD, 0)
        XCTAssertGreaterThan(pty.pid, 0)

        let output = readUntil(fd: pty.masterFD, needle: "rwork-ok")
        XCTAssertTrue(output.contains("rwork-ok"), "expected 'rwork-ok', got: \(output)")

        let exp = expectation(description: "exit")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testPTYInteractiveEcho() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv())

        // Cooked-mode line discipline echoes and the shell evaluates the command.
        let cmd = "echo HELLO_$((1+1))\n"
        PTYProcessTests.write(pty.masterFD, cmd)

        let output = readUntil(fd: pty.masterFD, needle: "HELLO_2")
        XCTAssertTrue(output.contains("HELLO_2"), "expected 'HELLO_2', got: \(output)")
        pty.terminate()
    }

    func testControllingTTY() throws {
        // 40 rows x 132 cols at spawn; `tty` must be a real /dev/ttys* and `stty size`
        // must reflect the openpty winsize — proving the slave is the controlling
        // terminal AND TIOCSWINSZ/openpty winsize plumbing works.
        let pty = PTYProcess()
        try pty.spawn(
            "/bin/sh",
            arguments: ["-c", "tty; stty size"],
            environment: curatedEnv(),
            cols: 132, rows: 40
        )

        let output = readUntil(fd: pty.masterFD, needle: "40 132")
        XCTAssertTrue(
            output.contains("/dev/ttys"),
            "expected a controlling tty path /dev/ttys*, got: \(output)")
        XCTAssertFalse(
            output.lowercased().contains("not a tty"),
            "tty reported 'not a tty' — slave is NOT the controlling terminal: \(output)")
        XCTAssertTrue(
            output.contains("40 132"),
            "expected 'stty size' = '40 132', got: \(output)")
    }

    func testResizeAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", environment: curatedEnv(), cols: 80, rows: 24)

        pty.setWindowSize(cols: 80, rows: 24)
        PTYProcessTests.write(pty.masterFD, "stty size\n")
        let first = readUntil(fd: pty.masterFD, needle: "24 80")
        XCTAssertTrue(first.contains("24 80"), "expected '24 80', got: \(first)")

        pty.setWindowSize(cols: 120, rows: 40)
        PTYProcessTests.write(pty.masterFD, "stty size\n")
        let second = readUntil(fd: pty.masterFD, needle: "40 120")
        XCTAssertTrue(second.contains("40 120"), "expected '40 120' after resize, got: \(second)")

        pty.terminate()
    }

    func testExitCode() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 7"], environment: curatedEnv())

        let exp = expectation(description: "exit7")
        Task {
            let code = await pty.waitForExit()
            XCTAssertEqual(code, 7, "expected exit code 7")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testMasterFDIsBlockingAfterSpawn() throws {
        let pty = PTYProcess()
        try pty.spawn("/bin/sh", arguments: ["-c", "exit 0"], environment: curatedEnv())
        let flags = fcntl(pty.masterFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & O_NONBLOCK, 0, "O_NONBLOCK must be cleared on the master fd")
        _ = readUntil(fd: pty.masterFD, needle: "\u{04}", timeout: 1) // drain until EOF
    }

    // MARK: util

    static func write(_ fd: Int32, _ string: String) {
        let data = Array(string.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else { break }
        }
    }
}

/// Thread-safe accumulator for the background PTY read in tests.
final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    /// Appends `bytes` and returns whether `needle` now appears in the accumulation.
    func append(_ bytes: ArraySlice<UInt8>, contains needle: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        data.append(contentsOf: bytes)
        return data.range(of: needle) != nil
    }
    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
