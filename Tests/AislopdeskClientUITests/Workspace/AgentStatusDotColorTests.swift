import AislopdeskAgentDetect
import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the ``AgentStatusDot`` SEMANTIC colour mapping (P2 polish). The status → colour rule is the only
/// pure logic in the dot; both the sidebar/tab/status-bar rollups read it, so a re-tint must be a
/// deliberate, test-visible change. `.none` maps to NO dot (nil) so a plain terminal stays clean.
///
/// The mapping reverses the earlier raw-system-hue vocabulary (working=yellow/done=blue): per spec E it is
/// now working=statusBlue (in-flight), done=statusGreen (finished), needsPermission=statusRed (blocked),
/// idle=fgDim (at rest, recedes). The label/accessibility text is unchanged.
@MainActor
final class AgentStatusDotColorTests: XCTestCase {
    #if canImport(SwiftUI)
    func testSemanticColorMapping() {
        XCTAssertNil(AgentStatusDot.color(for: .none), "no agent ⇒ no dot")
        XCTAssertEqual(AgentStatusDot.color(for: .idle), AislopdeskTheme.fgDim)
        XCTAssertEqual(AgentStatusDot.color(for: .working), AislopdeskTheme.statusBlue)
        XCTAssertEqual(AgentStatusDot.color(for: .done), AislopdeskTheme.statusGreen)
        XCTAssertEqual(AgentStatusDot.color(for: .needsPermission), AislopdeskTheme.statusRed)
    }

    /// Every non-`.none` status draws a dot; `.none` is the only hidden case (so the rollup vocabulary
    /// stays: a resting/no-agent pane recedes, an active one shows).
    func testOnlyNoneIsHidden() {
        for status in ClaudeStatus.allCases {
            if status == .none {
                XCTAssertNil(AgentStatusDot.color(for: status))
            } else {
                XCTAssertNotNil(AgentStatusDot.color(for: status), "\(status) must draw a dot")
            }
        }
    }
    #endif

    /// The label/accessibility text is unaffected by the colour remap (separate source of truth).
    func testLabelsUnchanged() {
        XCTAssertEqual(AgentStatusDot.label(for: .none), "none")
        XCTAssertEqual(AgentStatusDot.label(for: .idle), "idle")
        XCTAssertEqual(AgentStatusDot.label(for: .working), "working")
        XCTAssertEqual(AgentStatusDot.label(for: .done), "done")
        XCTAssertEqual(AgentStatusDot.label(for: .needsPermission), "needs permission")
    }
}
