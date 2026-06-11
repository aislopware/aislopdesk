import XCTest
@testable import AislopdeskVideoClient

/// Drop-until-anchor admission (decode-fail cascade fix, 2026-06-12). Pure value type —
/// the wrap-aware sequence discipline mirrors `LTREscalationTracker`.
final class DecodeGateTests: XCTestCase {

    // MARK: Open gate

    func testOpenSubmitsEverything() {
        let g = DecodeGate()
        XCTAssertEqual(g.mode, .open)
        XCTAssertEqual(g.verdict(frameID: 10, keyframe: false, ackedAnchored: false), .submit)
        XCTAssertEqual(g.verdict(frameID: 11, keyframe: true, ackedAnchored: false), .submit)
        XCTAssertEqual(g.verdict(frameID: 12, keyframe: false, ackedAnchored: true), .submit)
    }

    // MARK: Broken chain — the cascade scenario

    func testLossDropsNewerDeltasButNotAnchors() {
        var g = DecodeGate()
        g.noteLoss(frameID: 100)
        XCTAssertEqual(g.mode, .brokenChain)
        // Post-loss deltas: the -12909 storm frames — must never reach VT.
        XCTAssertEqual(g.verdict(frameID: 101, keyframe: false, ackedAnchored: false), .drop)
        XCTAssertEqual(g.verdict(frameID: 150, keyframe: false, ackedAnchored: false), .drop)
        // The frame AT the loss id (kfDup-style duplicate completion) is not pre-break either.
        XCTAssertEqual(g.verdict(frameID: 100, keyframe: false, ackedAnchored: false), .drop)
        // Anchors submit: keyframe, acked-anchored (ForceLTRRefresh product, bit 7).
        XCTAssertEqual(g.verdict(frameID: 102, keyframe: true, ackedAnchored: false), .submit)
        XCTAssertEqual(g.verdict(frameID: 103, keyframe: false, ackedAnchored: true), .submit)
        // A pre-break delta still in flight (references predate the loss) submits.
        XCTAssertEqual(g.verdict(frameID: 99, keyframe: false, ackedAnchored: false), .submit)
    }

    func testTwoLossesDropDeltaBetweenThem() {
        var g = DecodeGate()
        g.noteLoss(frameID: 200)
        g.noteLoss(frameID: 210)
        // A delta BETWEEN the two losses descends from the first break — must drop.
        // (A newest-loss-only gate would wrongly submit it.)
        XCTAssertEqual(g.verdict(frameID: 205, keyframe: false, ackedAnchored: false), .drop)
        XCTAssertEqual(g.verdict(frameID: 199, keyframe: false, ackedAnchored: false), .submit)
        XCTAssertEqual(g.minLostFrameID, 200)
        XCTAssertEqual(g.maxLostFrameID, 210)
    }

    func testLossOrderIrrelevantForMinMax() {
        var g = DecodeGate()
        g.noteLoss(frameID: 210)
        g.noteLoss(frameID: 200)   // older loss reported later (drain order)
        XCTAssertEqual(g.minLostFrameID, 200)
        XCTAssertEqual(g.maxLostFrameID, 210)
    }

    // MARK: Healing

    func testAckedAnchorNewerThanEveryLossReopens() {
        var g = DecodeGate()
        g.noteLoss(frameID: 100)
        g.noteLoss(frameID: 104)
        // The host's recovery refresh (LTR P-frame) decodes successfully past every loss.
        g.noteDecodeSucceeded(frameID: 106, keyframe: false)
        XCTAssertEqual(g.mode, .open)
        XCTAssertEqual(g.verdict(frameID: 107, keyframe: false, ackedAnchored: false), .submit)
    }

    func testAnchorOlderThanNewestLossDoesNotReopen() {
        var g = DecodeGate()
        g.noteLoss(frameID: 100)
        g.noteLoss(frameID: 110)
        // An anchor that only outruns the FIRST loss proves nothing about the second.
        g.noteDecodeSucceeded(frameID: 105, keyframe: false)
        XCTAssertEqual(g.mode, .brokenChain)
        XCTAssertEqual(g.verdict(frameID: 111, keyframe: false, ackedAnchored: false), .drop)
    }

    func testKeyframeNewerThanLossesReopens() {
        var g = DecodeGate()
        g.noteLoss(frameID: 100)
        g.noteDecodeSucceeded(frameID: 101, keyframe: true)
        XCTAssertEqual(g.mode, .open)
        XCTAssertNil(g.minLostFrameID)
        XCTAssertNil(g.maxLostFrameID)
    }

    func testStaleKeyframeDowngradesToBrokenChain() {
        var g = DecodeGate()
        g.noteLoss(frameID: 100)
        var g2 = g
        g2.noteHardDecodeFailure()
        XCTAssertEqual(g2.mode, .needKeyframe)
        // An in-flight keyframe OLDER than the newest loss decodes: the session is alive again
        // (needKeyframe → brokenChain) but the chain past the keyframe is still broken.
        g2.noteDecodeSucceeded(frameID: 90, keyframe: true)
        XCTAssertEqual(g2.mode, .brokenChain)
        XCTAssertEqual(g2.verdict(frameID: 101, keyframe: false, ackedAnchored: false), .drop)
        XCTAssertEqual(g2.verdict(frameID: 102, keyframe: false, ackedAnchored: true), .submit)
    }

    // MARK: needKeyframe (dead session)

    func testHardFailureAcceptsOnlyKeyframes() {
        var g = DecodeGate()
        g.noteLoss(frameID: 50)
        g.noteHardDecodeFailure()
        XCTAssertEqual(g.mode, .needKeyframe)
        // Even an acked-anchored refresh can't help — invalidateSession wiped the DPB.
        XCTAssertEqual(g.verdict(frameID: 60, keyframe: false, ackedAnchored: true), .drop)
        XCTAssertEqual(g.verdict(frameID: 49, keyframe: false, ackedAnchored: false), .drop)
        XCTAssertEqual(g.verdict(frameID: 61, keyframe: true, ackedAnchored: false), .submit)
        g.noteDecodeSucceeded(frameID: 61, keyframe: true)
        XCTAssertEqual(g.mode, .open)
    }

    func testAwaitingKeyframeGatesPreIDRDeltas() {
        var g = DecodeGate()
        g.noteAwaitingKeyframe()
        XCTAssertEqual(g.mode, .needKeyframe)
        XCTAssertEqual(g.verdict(frameID: 1, keyframe: false, ackedAnchored: false), .drop)
        XCTAssertEqual(g.verdict(frameID: 2, keyframe: true, ackedAnchored: false), .submit)
    }

    func testLossWhileNeedKeyframeStaysNeedKeyframe() {
        var g = DecodeGate()
        g.noteHardDecodeFailure()
        g.noteLoss(frameID: 300)
        XCTAssertEqual(g.mode, .needKeyframe)
        XCTAssertEqual(g.verdict(frameID: 301, keyframe: false, ackedAnchored: true), .drop)
        // The keyframe that finally lands must still outrun the recorded loss to fully reopen.
        g.noteDecodeSucceeded(frameID: 301, keyframe: true)
        XCTAssertEqual(g.mode, .open)
    }

    // MARK: Wrap-awareness

    func testWrapAwareLossAndHealing() {
        var g = DecodeGate()
        let nearWrap = UInt32.max - 1
        g.noteLoss(frameID: nearWrap)
        // Post-wrap delta is NEWER than the loss → drop.
        XCTAssertEqual(g.verdict(frameID: 2, keyframe: false, ackedAnchored: false), .drop)
        // Pre-wrap older delta submits.
        XCTAssertEqual(g.verdict(frameID: nearWrap - 1, keyframe: false, ackedAnchored: false), .submit)
        // Post-wrap anchor heals.
        g.noteDecodeSucceeded(frameID: 3, keyframe: false)
        XCTAssertEqual(g.mode, .open)
    }

    func testNonKeyframeSuccessWhileOpenIsNoOp() {
        var g = DecodeGate()
        g.noteDecodeSucceeded(frameID: 7, keyframe: false)
        XCTAssertEqual(g.mode, .open)
        XCTAssertNil(g.maxLostFrameID)
    }
}
