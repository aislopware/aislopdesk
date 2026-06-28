import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E18 WI-2 — the additive `PaneKind.web` discriminator (a LOCAL WKWebView pane).
///
/// Pins the untrusted-persisted-data contract for the new case (CLAUDE.md §3 / forward-tolerant decode):
///  1. `.web` has the stable raw value `"web"` (the persisted JSON discriminator).
///  2. The synthesized `rawValue` init knows `"web"` → `.web`.
///  3. `.web` round-trips through the custom `PaneKind.init(from:)` (raw `"web"` decodes back to `.web`).
///  4. A genuinely-unknown raw value STILL throws (only the one retired `"claudeCode"` value is repaired;
///     a `.web` addition must not widen the tolerant path into "accept anything").
///
/// Revert-to-confirm-fail: on the un-fixed enum (no `.web` case) (2) and (3) fail — `PaneKind(rawValue:
/// "web")` is `nil` and the keyed decode of `"web"` throws — so these assertions are load-bearing, not
/// tautological. (1) pins the wire string against an accidental rename.
final class PaneKindWebDecodeTests: XCTestCase {
    /// A minimal keyed wrapper so the decode exercises `PaneKind.init(from:)` (single-value container)
    /// without relying on top-level JSON-fragment encoding.
    private struct Box: Codable, Equatable {
        var kind: PaneKind
    }

    // MARK: - 1. Stable raw discriminator

    func testWebRawValueIsWeb() {
        XCTAssertEqual(PaneKind.web.rawValue, "web", "the persisted discriminator for a web pane is \"web\"")
    }

    // MARK: - 2. Synthesized rawValue init knows web

    func testWebRawValueInitResolves() {
        XCTAssertEqual(PaneKind(rawValue: "web"), .web, "the synthesized rawValue init maps \"web\" → .web")
    }

    // MARK: - 3. Round-trip through the custom tolerant decode

    func testWebRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(Box(kind: .web))
        let restored = try JSONDecoder().decode(Box.self, from: data)
        XCTAssertEqual(restored.kind, .web, "a `.web` kind encodes to \"web\" and decodes back to `.web`")
    }

    func testWebRawDecodesViaPaneSpec() throws {
        // The exact bytes a persisted `.web` leaf spec carries.
        let json = Data(#"{ "kind": "web", "title": "Web" }"#.utf8)
        let spec = try JSONDecoder().decode(PaneSpec.self, from: json)
        XCTAssertEqual(spec.kind, .web, "a persisted `.web` spec decodes to the web kind")
    }

    // MARK: - 4. Unknown raw value still throws (the tolerant path did NOT widen)

    func testUnknownRawValueStillThrows() {
        let json = Data(#"{ "kind": "wormhole", "title": "x" }"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PaneSpec.self, from: json),
            "an unknown kind is still corruption — adding `.web` must not make the decode accept anything",
        )
    }
}
