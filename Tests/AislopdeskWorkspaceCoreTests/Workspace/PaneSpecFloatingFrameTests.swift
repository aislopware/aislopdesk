import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// The additive `PaneSpec.floatingFrame` persistence field (P5a, schema v11 — no version bump).
///
/// Contract:
/// (a) A `PaneSpec` carrying a `floatingFrame` round-trips `==` (the four `CGRect` doubles survive).
/// (b) A spec WITHOUT the key (a pre-feature / tiled pane) decodes `floatingFrame == nil` — never traps.
/// (c) A whole `TreeWorkspace` with a floated pane round-trips the frame through the Session spec table.
///
/// Revert-to-confirm-fail: the unmodified `PaneSpec` has no `floatingFrame` field, so (a) fails (the
/// round-trip drops the rect → unequal) and (c) fails (the restored spec has no frame to read).
final class PaneSpecFloatingFrameTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private let decoder = JSONDecoder()

    // MARK: (a) round-trip

    func testPaneSpecRoundTripsFloatingFrame() throws {
        let frame = CGRect(x: 12, y: 34, width: 567, height: 432)
        let spec = PaneSpec(kind: .terminal, title: "scratch", floatingFrame: frame)
        let restored = try decoder.decode(PaneSpec.self, from: makeEncoder().encode(spec))
        XCTAssertEqual(restored, spec)
        XCTAssertEqual(restored.floatingFrame, frame)
    }

    // MARK: (b) absent key decodes nil

    func testPaneSpecWithoutFloatingFrameDecodesNil() throws {
        // A minimal v10-era spec JSON: kind + title only, NO floatingFrame key.
        let json = #"{ "kind": "terminal", "title": "Terminal" }"#
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        XCTAssertNil(spec.floatingFrame, "an old spec without the key decodes nil (tiled)")
        XCTAssertEqual(spec.kind, .terminal)
    }

    // MARK: (c) survives a TreeWorkspace round-trip

    func testFloatedPaneSurvivesWorkspaceRoundTrip() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let ws0 = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "a"))
        let a = ws0.allPaneIDs()[0]
        let (ws1, b) = WorkspaceTreeOps.splitPane(
            a, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "b"), in: ws0,
        )
        let frame = CGRect(x: 100, y: 120, width: 400, height: 320)
        let ws = WorkspaceTreeOps.toggleFloating(b, defaultFrame: frame, bounds: bounds, in: ws1)

        let data = try makeEncoder().encode(ws)
        let restored = try decoder.decode(TreeWorkspace.self, from: data)

        XCTAssertEqual(restored.spec(for: b)?.floatingFrame, frame, "the floated frame survives persistence")
        let tab = try XCTUnwrap(restored.activeSession?.activeTab)
        XCTAssertTrue(tab.floatingPanes.contains(b), "the pane stays in the floating layer after reload")
        XCTAssertFalse(tab.root.contains(b), "and stays out of the tiled tree")
    }
}
