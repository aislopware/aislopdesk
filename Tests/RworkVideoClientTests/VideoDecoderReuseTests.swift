#if canImport(VideoToolbox)
import XCTest
@testable import RworkVideoClient
import RworkVideoProtocol

/// BUG-I regression: the decoder must NOT tear down + recreate its VTDecompressionSession
/// on a byte-identical keyframe.
///
/// `VideoDecoder.decode()` previously called `configure(parameterSets:)` on EVERY
/// keyframe — including the ~1s heartbeat IDR and every forced-recovery IDR — which
/// invalidates and recreates the `VTDecompressionSession`, stalling an otherwise-healthy
/// stream roughly once a second. The fix gates the reconfigure on
/// `VideoDecoder.needsReconfigure(current:incoming:)`: rebuild only when the extracted
/// parameter sets actually differ. That decision is pure (`Equatable` value compare, no
/// VideoToolbox session) so it is unit-testable without driving a real decode.
final class VideoDecoderReuseTests: XCTestCase {
    private func sets(_ vps: [UInt8], _ sps: [UInt8], _ pps: [UInt8]) -> HEVCParameterSets.ParameterSets {
        HEVCParameterSets.ParameterSets(vps: Data(vps), sps: Data(sps), pps: Data(pps))
    }

    func testFirstKeyframeAlwaysReconfigures() {
        // No session yet (current == nil) → must build it.
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: nil, incoming: sets([0x40], [0x42], [0x44])))
    }

    func testIdenticalParameterSetsDoNotReconfigure() {
        let running = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        // The heartbeat / recovery IDR carries byte-identical VPS/SPS/PPS → reuse session.
        let identicalIDR = sets([0x40, 0x01], [0x42, 0x02], [0x44, 0x03])
        XCTAssertEqual(running, identicalIDR) // sanity: value equality
        XCTAssertFalse(VideoDecoder.needsReconfigure(current: running, incoming: identicalIDR))
    }

    func testChangedSPSReconfigures() {
        let running = sets([0x40], [0x42, 0x02], [0x44])
        // A real resolution change carries a different SPS → must rebuild the session.
        let resized = sets([0x40], [0x42, 0x99], [0x44])
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: resized))
    }

    func testChangedVPSOrPPSReconfigures() {
        let running = sets([0x40], [0x42], [0x44])
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: sets([0x4F], [0x42], [0x44])))
        XCTAssertTrue(VideoDecoder.needsReconfigure(current: running, incoming: sets([0x40], [0x42], [0x4F])))
    }
}
#endif
