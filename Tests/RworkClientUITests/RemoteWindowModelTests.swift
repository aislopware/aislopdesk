import XCTest
@testable import RworkClientUI

/// Pure-logic tests for the PATH 2 ``RemoteWindowModel``: field parsing, the `canOpen` gate,
/// and that `open()` builds a complete-endpoint ``RemoteWindowDescriptor`` (so the app factory
/// takes the LIVE `VideoWindowView(title:connection:)` path). No video frameworks involved.
@MainActor
final class RemoteWindowModelTests: XCTestCase {

    func testCanOpenRequiresHostAndWindowID() {
        let m = RemoteWindowModel()           // default ports 9000/9001, empty host + windowID
        XCTAssertFalse(m.canOpen)
        m.host = "100.64.0.2"
        XCTAssertFalse(m.canOpen, "still missing window id")
        m.windowID = "12345"
        XCTAssertTrue(m.canOpen, "host + windowID + default valid ports ⇒ can open")
    }

    func testCanOpenRejectsUnparseableFields() {
        let m = RemoteWindowModel(host: "h", mediaPort: "nope", cursorPort: "9001", windowID: "1")
        XCTAssertFalse(m.canOpen)
        m.mediaPort = "9000"; m.windowID = "notanumber"
        XCTAssertFalse(m.canOpen)
    }

    func testCanOpenRejectsZeroPort() {
        let m = RemoteWindowModel(host: "h", mediaPort: "0", cursorPort: "9001", windowID: "1")
        XCTAssertFalse(m.canOpen, "port 0 is not a usable endpoint")
    }

    func testOpenBuildsDescriptorWithFullEndpoint() {
        let m = RemoteWindowModel(host: " h.local ", mediaPort: "9000", cursorPort: "9001",
                                  windowID: "42", title: "Safari")
        m.open()
        guard let d = m.active else { return XCTFail("open() should set active") }
        XCTAssertEqual(d.windowID, 42)
        XCTAssertEqual(d.host, "h.local", "host is trimmed")
        XCTAssertEqual(d.mediaPort, 9000)
        XCTAssertEqual(d.cursorPort, 9001)
        XCTAssertEqual(d.title, "Safari")
        XCTAssertTrue(d.hasEndpoint, "descriptor carries a live endpoint ⇒ factory takes live path")
    }

    func testOpenWithInvalidFieldsIsNoOp() {
        let m = RemoteWindowModel(host: "", windowID: "x")
        m.open()
        XCTAssertNil(m.active)
    }

    func testEmptyTitleFallsBackToWindowID() {
        let m = RemoteWindowModel(host: "h", windowID: "7", title: "")
        m.open()
        XCTAssertEqual(m.active?.title, "window 7")
    }

    func testCloseClearsActive() {
        let m = RemoteWindowModel(host: "h", windowID: "1")
        m.open()
        XCTAssertNotNil(m.active)
        m.close()
        XCTAssertNil(m.active)
    }

    func testTitleOnlyDescriptorHasNoEndpoint() {
        // The placeholder/preview path: a descriptor with no host is NOT live.
        let d = RemoteWindowDescriptor(title: "x", windowID: 3)
        XCTAssertFalse(d.hasEndpoint)
    }
}
