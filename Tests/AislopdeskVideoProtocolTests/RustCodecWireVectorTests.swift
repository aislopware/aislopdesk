import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Pins the Rust-backed video wire codecs (cursor / window-geometry / input-event) to their exact
/// on-wire byte layout. The Rust core is the single source of truth — there is no native Swift
/// codec to diff against any more — so these hand-computed vectors independently verify the Swift
/// FFI marshaling (field order + endianness) in BOTH directions. A round-trip test alone could miss
/// a *symmetric* marshaling bug (a field swapped on both encode and decode); a known vector cannot.
///
/// The `f64` constants are chosen to be power-of-two-exact so their big-endian IEEE-754 bytes are
/// transparent: 2.0=0x4000…, 1.0=0x3FF0…, 0.5=0x3FE0…, 0.25=0x3FD0….
final class RustCodecWireVectorTests: XCTestCase {
    // MARK: cursor

    func testCursorWireVector() throws {
        let update = CursorUpdate(
            position: VideoPoint(x: 2.0, y: 1.0),
            shapeID: 42,
            hotspot: VideoPoint(x: 0.5, y: 0.25),
            visible: true,
        )
        let expected: [UInt8] = [
            0x01, // type = cursorUpdate
            0x00, 0x2A, // shapeID 42 (u16 BE)
            0x01, // visible
            0x40, 0, 0, 0, 0, 0, 0, 0, // x = 2.0
            0x3F, 0xF0, 0, 0, 0, 0, 0, 0, // y = 1.0
            0x3F, 0xE0, 0, 0, 0, 0, 0, 0, // hotspotX = 0.5
            0x3F, 0xD0, 0, 0, 0, 0, 0, 0, // hotspotY = 0.25
        ]
        XCTAssertEqual(Array(update.encode()), expected)
        XCTAssertEqual(try CursorUpdate.decode(Data(expected)), update)
    }

    // MARK: window_geometry

    func testWindowGeometryWireVectors() throws {
        let cases: [(WindowGeometryMessage, [UInt8])] = [
            (
                .move(VideoPoint(x: 2.0, y: 1.0)),
                [0x01, 0x40, 0, 0, 0, 0, 0, 0, 0, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .resize(VideoSize(width: 0.5, height: 0.25)),
                [0x02, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0x3F, 0xD0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .bounds(VideoRect(x: 1.0, y: 2.0, width: 0.5, height: 0.25)),
                [
                    0x03,
                    0x3F,
                    0xF0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x40,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ],
            ),
            (.title("Hi"), [0x04, 0x48, 0x69]),
            (.title(""), [0x04]),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(Array(message.encode()), expected, "encode \(message)")
            XCTAssertEqual(try WindowGeometryMessage.decode(Data(expected)), message, "decode \(message)")
        }
    }

    // MARK: input_event

    func testInputEventWireVectors() throws {
        let cases: [(InputEvent, [UInt8])] = [
            (
                .mouseMove(normalized: VideoPoint(x: 0.5, y: 0.25), tag: 1),
                [0x01, 0, 0, 0, 1, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0, 0x3F, 0xD0, 0, 0, 0, 0, 0, 0],
            ),
            (
                .mouseDown(
                    button: .right,
                    normalized: VideoPoint(x: 0.5, y: 0.25),
                    clickCount: 2,
                    modifiers: [.shift, .command],
                    tag: 9,
                ),
                [
                    0x02,
                    0,
                    0,
                    0,
                    9,
                    0x01,
                    0x02,
                    0x09,
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ],
            ),
            (
                .scroll(
                    dx: 2.0,
                    dy: 1.0,
                    normalized: VideoPoint(x: 0.5, y: 0.25),
                    scrollPhase: 2,
                    momentumPhase: 0,
                    continuous: true,
                    tag: 7,
                ),
                [
                    0x04,
                    0,
                    0,
                    0,
                    7,
                    0x40,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // dx = 2.0
                    0x3F,
                    0xF0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // dy = 1.0
                    0x3F,
                    0xE0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // x = 0.5
                    0x3F,
                    0xD0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0, // y = 0.25
                    0x02,
                    0x00,
                    0x01,
                ],
            ), // scrollPhase, momentumPhase, continuous
            (
                .key(keyCode: 0x0035, down: true, modifiers: .option, tag: 4),
                [0x05, 0, 0, 0, 4, 0x00, 0x35, 0x01, 0x04],
            ),
            (.text("Hi", tag: 3), [0x06, 0, 0, 0, 3, 0x48, 0x69]),
        ]
        for (event, expected) in cases {
            XCTAssertEqual(Array(event.encode()), expected, "encode \(event)")
            XCTAssertEqual(try InputEvent.decode(Data(expected)), event, "decode \(event)")
        }
    }

    // MARK: fuzz — arbitrary bytes must never crash the Rust-backed decoders.

    func testDecodersNeverCrashOnRandomBytes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let len = Int.random(in: 0...48, using: &rng)
            let data = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? CursorUpdate.decode(data)
            _ = try? WindowGeometryMessage.decode(data)
            _ = try? InputEvent.decode(data)
        }
    }
}
