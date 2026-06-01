import XCTest
@testable import RworkInspector

/// Tool-card pairing edge cases: out-of-order result, missing result (stays pending),
/// error result (isError true).
final class ToolCardPairingTests: XCTestCase {
    private func toolUseLine(id: String, name: String = "Bash") -> TranscriptLine {
        .assistant(AssistantLine(
            identity: LineIdentity(uuid: "u-\(id)"),
            toolUses: [ToolUseBlock(id: id, name: name, input: .object(["x": .string("y")]))]
        ))
    }

    private func toolResultLine(id: String, output: String, isError: Bool) -> TranscriptLine {
        .user(UserLine(
            identity: LineIdentity(uuid: "r-\(id)"),
            toolResults: [ToolResultBlock(toolUseID: id, content: output, isError: isError)]
        ))
    }

    private func cards(_ events: [InspectorEvent]) -> [ToolCard] {
        events.compactMap { if case let .toolCard(c) = $0 { return c } else { return nil } }
    }

    func testInOrderResultCompletesCard() {
        var b = EventBuilder()
        var events = b.ingest(line: toolUseLine(id: "a"))
        events += b.ingest(line: toolResultLine(id: "a", output: "ok", isError: false))
        let c = cards(events)
        XCTAssertEqual(c.map(\.status), [.pending, .completed])
        XCTAssertEqual(c.last?.output, "ok")
    }

    func testOutOfOrderResultBeforeUseResolvesOnce() {
        var b = EventBuilder()
        // Result arrives FIRST (no card yet) → held, emits nothing.
        var events = b.ingest(line: toolResultLine(id: "a", output: "early", isError: false))
        XCTAssertTrue(cards(events).isEmpty, "result before tool_use must emit no card")
        // tool_use arrives → card emitted ALREADY resolved (single emission, completed).
        events += b.ingest(line: toolUseLine(id: "a"))
        let c = cards(events)
        XCTAssertEqual(c.count, 1, "card emitted exactly once, already resolved")
        XCTAssertEqual(c[0].status, .completed)
        XCTAssertEqual(c[0].output, "early")
    }

    func testMissingResultStaysPending() {
        var b = EventBuilder()
        let events = b.ingest(line: toolUseLine(id: "a"))
        let c = cards(events)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].status, .pending, "no result → stays pending, no crash")
        XCTAssertNil(c[0].output)
    }

    func testErrorResultMarksErrored() {
        var b = EventBuilder()
        var events = b.ingest(line: toolUseLine(id: "a"))
        events += b.ingest(line: toolResultLine(id: "a", output: "boom", isError: true))
        XCTAssertEqual(cards(events).last?.status, .errored)
    }

    func testDuplicateLineIsDeduped() {
        var b = EventBuilder()
        let use = toolUseLine(id: "a")
        var events = b.ingest(line: use)
        events += b.ingest(line: use) // same uuid → second ingest emits nothing
        XCTAssertEqual(cards(events).count, 1, "re-read tail must not double-emit")
    }
}
