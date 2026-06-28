import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-3 (ES-E13-2): the pure ``AgentBadgeGates`` gating policy that layers the otty "Agent Behaviour"
/// badge toggles on top of the (unchanged) ``TabBadgeResolver`` output. Each toggle OFF must drop ONLY its
/// own badge family; the always-on families (error / sudo / caffeinate) must survive every gate.
final class AgentBadgeGatesTests: XCTestCase {
    // MARK: All-on default is a pass-through

    func testAllOnIsIdentity() {
        for kind in allKinds {
            XCTAssertEqual(AgentBadgeGates.gated(kind, by: .allOn), kind, "all-on must not drop \(kind)")
        }
        XCTAssertNil(AgentBadgeGates.gated(nil, by: .allOn), "nil passes through as nil")
    }

    // MARK: whileProcessing OFF drops ONLY .running

    func testWhileProcessingOffDropsOnlyRunning() {
        let gates = AgentBadgeGates(badgeWhileProcessing: false)
        XCTAssertNil(AgentBadgeGates.gated(.running, by: gates), "spinner dropped")
        // Every other family is untouched.
        for kind in allKinds where kind != .running {
            XCTAssertEqual(AgentBadgeGates.gated(kind, by: gates), kind, "\(kind) must survive whileProcessing OFF")
        }
    }

    // MARK: whenComplete OFF drops .completed AND .finished

    func testWhenCompleteOffDropsCompletedAndFinished() {
        let gates = AgentBadgeGates(badgeWhenComplete: false)
        XCTAssertNil(AgentBadgeGates.gated(.completed, by: gates))
        XCTAssertNil(AgentBadgeGates.gated(.finished, by: gates))
        for kind in allKinds where kind != .completed && kind != .finished {
            XCTAssertEqual(AgentBadgeGates.gated(kind, by: gates), kind, "\(kind) must survive whenComplete OFF")
        }
    }

    // MARK: whenAwaitingInput OFF drops ONLY .awaitingInput

    func testWhenAwaitingInputOffDropsOnlyAwaitingInput() {
        let gates = AgentBadgeGates(badgeWhenAwaitingInput: false)
        XCTAssertNil(AgentBadgeGates.gated(.awaitingInput, by: gates), "hand dropped")
        for kind in allKinds where kind != .awaitingInput {
            XCTAssertEqual(AgentBadgeGates.gated(kind, by: gates), kind, "\(kind) must survive whenAwaitingInput OFF")
        }
    }

    // MARK: error / sudo / caffeinate survive even with EVERY toggle off

    func testAlwaysOnFamiliesSurviveAllGatesOff() {
        let allOff = AgentBadgeGates(
            badgeWhileProcessing: false, badgeWhenComplete: false, badgeWhenAwaitingInput: false,
        )
        XCTAssertEqual(AgentBadgeGates.gated(.error, by: allOff), .error, "an error is never an opt-out badge")
        XCTAssertEqual(AgentBadgeGates.gated(.sudo, by: allOff), .sudo, "a privilege badge is never opt-out")
        XCTAssertEqual(AgentBadgeGates.gated(.caffeinate, by: allOff), .caffeinate)
        // The three agent families are all dropped at once.
        XCTAssertNil(AgentBadgeGates.gated(.running, by: allOff))
        XCTAssertNil(AgentBadgeGates.gated(.completed, by: allOff))
        XCTAssertNil(AgentBadgeGates.gated(.finished, by: allOff))
        XCTAssertNil(AgentBadgeGates.gated(.awaitingInput, by: allOff))
    }

    // MARK: toggling flips exactly one bit

    func testTogglingFlipsExactlyOneGate() {
        let base = AgentBadgeGates.allOn
        let flipped = base.toggling(.whenComplete)
        XCTAssertFalse(flipped.badgeWhenComplete, "the targeted bit flips")
        XCTAssertTrue(flipped.badgeWhileProcessing, "the other two are preserved")
        XCTAssertTrue(flipped.badgeWhenAwaitingInput)
        XCTAssertEqual(flipped.toggling(.whenComplete), base, "a second flip restores the original")
    }

    private let allKinds: [TabBadgeKind] = [
        .running, .completed, .finished, .error, .awaitingInput, .caffeinate, .sudo,
    ]
}
