import XCTest
@testable import AislopdeskVideoClient

/// PURE modifier-latch tracking. Regression: a modifier forwarded to the host as "down" whose release
/// `flagsChanged` is swallowed by a focus change stays latched in the host's shared event source, so a
/// later plain scroll rides ⌘ (zoom). The tracker lets the view synthesize the missing key-ups on blur.
final class ModifierLatchTrackerTests: XCTestCase {
    func testStartsEmpty() {
        let t = ModifierLatchTracker()
        XCTAssertTrue(t.isEmpty)
        XCTAssertFalse(t.isDown(55))
    }

    func testNoteDownThenUpClears() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 55, down: true) // ⌘ left down
        XCTAssertTrue(t.isDown(55))
        XCTAssertFalse(t.isEmpty)
        t.note(keyCode: 55, down: false) // ⌘ left up
        XCTAssertFalse(t.isDown(55))
        XCTAssertTrue(t.isEmpty)
    }

    // The core fix: a ⌘ that went down but whose release was never seen (focus moved) must be drained so
    // the caller can emit a host key-up — otherwise the host latches ⌘ and scroll becomes zoom.
    func testDrainReturnsLatchedAndClears() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 55, down: true) // ⌘
        t.note(keyCode: 58, down: true) // ⌥
        let released = t.drainForRelease()
        XCTAssertEqual(released, [55, 58], "ascending, deterministic order")
        XCTAssertTrue(t.isEmpty, "draining clears the tracker so a re-forward doesn't double-count")
        XCTAssertTrue(t.drainForRelease().isEmpty, "a second drain finds nothing latched")
    }

    func testDrainIgnoresAlreadyReleasedModifiers() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 56, down: true) // ⇧ down
        t.note(keyCode: 56, down: false) // ⇧ up (release seen normally)
        t.note(keyCode: 59, down: true) // ⌃ down, no release
        XCTAssertEqual(t.drainForRelease(), [59], "only the still-held ⌃ needs a synthesized release")
    }
}
