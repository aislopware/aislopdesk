#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

/// WB2 — the navigator per-row JUMP delta (#1/#3). The bug: `jump_to_prompt:<delta>` is viewport-RELATIVE
/// (libghostty `PageList.scrollPrompt` steps `delta` prompts from the CURRENT viewport; `delta == 0` is a
/// no-op), so a bare `jump_to_prompt:-pos` only lands correctly when the viewport already sits at the
/// newest prompt — after any prior scroll/jump it is off by the viewport offset, and the newest block
/// (pos 0) never moves. The fix RE-ANCHORS the viewport to the bottom (`scroll_to_bottom`, a real
/// libghostty binding action) first, then steps `pos` prompts UP from that known anchor.
///
/// ``CommandNavigatorView/jumpDelta(toTargetPos:)`` is the PURE delta from the bottom anchor; this pins it
/// for the newest / middle / oldest cases. Non-tautological: the asserts are hand-computed, not the
/// function's own derivation.
final class CommandNavigatorJumpTests: XCTestCase {
    func testNewestBlockIsANoOpFromTheBottomAnchor() {
        // pos 0 = the newest block. After re-anchoring to the bottom we are already AT the newest prompt,
        // so the step is zero (no-op). This is the exact case the old `-pos` got wrong: `-0` is a libghostty
        // no-op, so the newest block never jumped at all.
        XCTAssertEqual(CommandNavigatorView.jumpDelta(toTargetPos: 0), 0, "newest → no step from bottom")
    }

    func testMiddleBlockStepsThatManyPromptsUp() {
        // pos N (the Nth-newest block) is exactly N prompts UP from the bottom anchor → delta -N.
        XCTAssertEqual(CommandNavigatorView.jumpDelta(toTargetPos: 1), -1, "2nd-newest → one prompt up")
        XCTAssertEqual(CommandNavigatorView.jumpDelta(toTargetPos: 5), -5, "6th-newest → five prompts up")
    }

    func testOldestBlockStepsToTheTopOfTheKnownList() {
        // The oldest retained block in a 64-deep navigator list is 63 prompts up from the newest.
        XCTAssertEqual(CommandNavigatorView.jumpDelta(toTargetPos: 63), -63, "oldest of 64 → 63 prompts up")
    }

    func testDeltaIsIndependentOfPriorViewport() {
        // The whole point of re-anchoring: the delta for a given target is the SAME no matter where the
        // viewport was before the jump (the old relative-from-here math is what diverged after a prior
        // jump). The pure function takes only the target position, proving that independence structurally.
        for pos in 0..<10 {
            XCTAssertEqual(
                CommandNavigatorView.jumpDelta(toTargetPos: pos), -pos,
                "delta depends only on the target position, never on a prior jump",
            )
        }
    }
}
#endif
