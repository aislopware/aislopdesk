import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskHost

/// WB1 — the host ``CommandBlockTracker``: the live glue between the pure ``CommandBlockSegmenter``
/// and the wire. Proves it (a) emits a type-28 `commandBlock` METADATA update per block create /
/// update / complete, DEDUPED; (b) retains each completed block's output in a BOUNDED ring and
/// serves it as type-29 `blockOutput`; (c) evicts oldest-first under both bounds; (d) returns an
/// EMPTY response for an evicted / unknown index — never traps.
///
/// Non-tautological: the OSC 133 fixtures are built from STRING literals, and the asserts pin the
/// extracted metadata + served bytes back to those literals, never to the tracker's own output.
final class CommandBlockTrackerTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    private func a() -> String { "\(ESC)]133;A\(BEL)" }
    private func b() -> String { "\(ESC)]133;B\(BEL)" }
    private func c() -> String { "\(ESC)]133;C\(BEL)" }
    private func d(_ exit: Int) -> String { "\(ESC)]133;D;\(exit)\(BEL)" }
    private func cycle(prompt: String, command: String, output: String, exit: Int) -> String {
        a() + prompt + b() + command + c() + output + d(exit)
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    /// One `commandBlock` metadata update extracted from an emit (named so asserts read clearly).
    private struct Meta {
        var index: UInt32
        var exit: Int32?
        var dur: UInt32?
        var complete: Bool
        var outLen: UInt32
        var cmd: String
    }

    /// All `commandBlock` metadata emitted by ingesting `stream` in one chunk.
    private func metas(_ stream: String, _ tracker: inout CommandBlockTracker) -> [Meta] {
        tracker.ingest(bytes(stream)).compactMap {
            guard case let .commandBlock(index, exit, dur, complete, outLen, cmd) = $0 else { return nil }
            return Meta(index: index, exit: exit, dur: dur, complete: complete, outLen: outLen, cmd: cmd)
        }
    }

    // MARK: 1. A completed command → a complete type-28 metadata update

    func testCompletedCommandEmitsMetadata() {
        var tracker = CommandBlockTracker()
        let m = metas(cycle(prompt: "$ ", command: "echo hi", output: "hi\n", exit: 0), &tracker)
        // At least one COMPLETE metadata for index 0 pinned to the literal command + output length.
        let complete = m.filter(\.complete)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete[0].index, 0)
        XCTAssertEqual(complete[0].cmd, "echo hi")
        XCTAssertEqual(complete[0].exit, 0)
        XCTAssertEqual(complete[0].outLen, 3) // "hi\n" = 3 bytes
    }

    // MARK: 2. A running command → a RUNNING (incomplete) metadata update

    func testRunningCommandEmitsIncompleteMetadata() {
        var tracker = CommandBlockTracker()
        // A→B→C→partial output, NO D yet.
        let m = metas(a() + "$ " + b() + "tail -f log" + c() + "line 1\n", &tracker)
        let running = m.filter { !$0.complete }
        XCTAssertEqual(running.last?.index, 0)
        XCTAssertEqual(running.last?.cmd, "tail -f log")
        XCTAssertNil(running.last?.exit)
        XCTAssertNil(running.last?.dur)
        XCTAssertEqual(running.last?.outLen, 7) // "line 1\n"
    }

    // MARK: 3. Dedup — re-ingesting nothing-changing emits nothing

    func testIdenticalMetadataNotReEmitted() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "true", output: "", exit: 0)))
        // Feed a chunk with NO new marks and no open block → no metadata at all.
        let again = tracker.ingest(bytes("plain banner text with no marks\n"))
        XCTAssertTrue(again.isEmpty, "no block changed → nothing re-emitted")
    }

    // MARK: 4. Serve the retained output for a completed block (type 29)

    func testServeOutputReturnsRetainedBytes() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cat f", output: "alpha\nbeta\n", exit: 0)))
        guard case let .blockOutput(index, output) = tracker.serveOutput(index: 0) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(index, 0)
        // Pinned to the literal output fed for that command.
        XCTAssertEqual(String(data: output, encoding: .utf8), "alpha\nbeta\n")
    }

    func testServeUnknownIndexReturnsEmptyNotTrap() {
        var tracker = CommandBlockTracker()
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "ls", output: "x\n", exit: 0)))
        guard case let .blockOutput(index, output) = tracker.serveOutput(index: 999) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(index, 999)
        XCTAssertTrue(output.isEmpty, "unknown index → empty output, never a trap")
    }

    func testRawControlSequencesPreservedInServedOutput() {
        var tracker = CommandBlockTracker()
        let colored = "\(ESC)[31mRED\(ESC)[0m\n"
        _ = tracker.ingest(bytes(a() + "$ " + b() + "ls --color" + c() + colored + d(0)))
        guard case let .blockOutput(_, output) = tracker.serveOutput(index: 0) else {
            XCTFail("expected blockOutput")
            return
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), colored)
        XCTAssertTrue(output.contains(0x1B), "ESC bytes preserved verbatim")
    }

    // MARK: 5. Ring eviction — oldest-first under the block-COUNT bound

    func testRingEvictsOldestPastBlockCap() {
        var tracker = CommandBlockTracker(maxBlocks: 3)
        // Run 5 commands index 0..4; only the last 3 (2,3,4) stay retained.
        for i in 0..<5 {
            _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "cmd\(i)", output: "out\(i)\n", exit: 0)))
        }
        XCTAssertEqual(tracker.retainedIndicesForTesting, [2, 3, 4])
        // Evicted blocks serve empty; retained ones serve their bytes.
        guard case let .blockOutput(_, evicted) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertTrue(evicted.isEmpty, "evicted block 0 → empty")
        guard case let .blockOutput(_, kept) = tracker.serveOutput(index: 4) else { XCTFail()
            return
        }
        XCTAssertEqual(String(data: kept, encoding: .utf8), "out4\n")
    }

    // MARK: 6. Ring eviction — oldest-first under the total-BYTES bound

    func testRingEvictsOldestPastByteCap() {
        // Byte cap of 10; each command outputs 8 bytes ("xxxxxxx\n") so two blocks (16B) exceed it.
        var tracker = CommandBlockTracker(maxBlocks: 100, maxTotalOutputBytes: 10)
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "c0", output: "AAAAAAA\n", exit: 0)))
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "c1", output: "BBBBBBB\n", exit: 0)))
        // 8 + 8 = 16 > 10 → oldest (block 0) evicted; block 1 (8B ≤ 10) kept.
        XCTAssertEqual(tracker.retainedIndicesForTesting, [1])
        XCTAssertLessThanOrEqual(tracker.totalOutputBytesForTesting, 10)
        guard case let .blockOutput(_, evicted) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertTrue(evicted.isEmpty)
    }

    func testByteCapKeepsAtLeastTheNewestBlock() {
        // A single block whose output alone exceeds the byte cap is still retained + servable.
        var tracker = CommandBlockTracker(maxBlocks: 100, maxTotalOutputBytes: 4)
        _ = tracker.ingest(bytes(cycle(prompt: "$ ", command: "big", output: "0123456789\n", exit: 0)))
        XCTAssertEqual(tracker.retainedIndicesForTesting, [0])
        guard case let .blockOutput(_, output) = tracker.serveOutput(index: 0) else { XCTFail()
            return
        }
        XCTAssertEqual(String(data: output, encoding: .utf8), "0123456789\n")
    }

    // MARK: 7. Chunk-boundary invariance — split anywhere = same retained output

    func testChunkSplitDoesNotChangeRetainedOutput() {
        let stream = cycle(prompt: "$ ", command: "echo one", output: "one\ntwo\n", exit: 0)
        let raw = Array(stream.utf8)

        var whole = CommandBlockTracker()
        _ = whole.ingest(Data(raw))

        var split = CommandBlockTracker()
        for byte in raw { _ = split.ingest(Data([byte])) } // one byte at a time

        guard case let .blockOutput(_, a) = whole.serveOutput(index: 0),
              case let .blockOutput(_, b) = split.serveOutput(index: 0)
        else { XCTFail()
            return
        }
        XCTAssertEqual(a, b)
        XCTAssertEqual(String(data: a, encoding: .utf8), "one\ntwo\n")
    }
}
