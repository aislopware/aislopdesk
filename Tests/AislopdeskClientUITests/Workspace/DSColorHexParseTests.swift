import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Pins the `Color(hex:)` primitive (validate-then-clamp, no trap) the DS ink/accent ramps are authored
/// with, and the DSPalette ramp hex values. The hex initializer is the load-bearing helper: a one-bit
/// drift in channel math silently shifts the whole palette, so the channel arithmetic is pinned by
/// resolving the SwiftUI `Color` to sRGB components on macOS.
@MainActor
final class DSColorHexParseTests: XCTestCase {
    #if canImport(SwiftUI) && canImport(AppKit)
    /// Resolves a SwiftUI `Color` to its sRGB (r,g,b,a) components — the only way to assert the hex math
    /// landed the right channels without depending on `Color`'s opaque `Equatable` representation.
    private func srgb(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (
            Double(ns.redComponent),
            Double(ns.greenComponent),
            Double(ns.blueComponent),
            Double(ns.alphaComponent),
        )
    }

    private func assertChannels(
        _ color: Color,
        _ r: Double,
        _ g: Double,
        _ b: Double,
        _ a: Double = 1,
        accuracy: Double = 0.001,
        line: UInt = #line,
    ) {
        guard let c = srgb(color) else { XCTFail("could not resolve color to sRGB", line: line)
            return
        }
        XCTAssertEqual(c.r, r, accuracy: accuracy, "red", line: line)
        XCTAssertEqual(c.g, g, accuracy: accuracy, "green", line: line)
        XCTAssertEqual(c.b, b, accuracy: accuracy, "blue", line: line)
        XCTAssertEqual(c.a, a, accuracy: accuracy, "alpha", line: line)
    }

    /// The canonical example: `0x0C0D0F` → (12/255, 13/255, 15/255), alpha 1.
    func testHexChannelMath() {
        assertChannels(Color(hex: 0x0C0D0F), 12.0 / 255, 13.0 / 255, 15.0 / 255)
    }

    /// The opacity argument rides through.
    func testHexOpacityPassesThrough() {
        assertChannels(Color(hex: 0xFFFFFF, opacity: 0.5), 1, 1, 1, 0.5)
    }

    /// validate-then-clamp, NO trap: a stray high byte (alpha) is masked off — `0xFF0C0D0F` resolves to
    /// the SAME channels as `0x0C0D0F` (the `& 0xFF` masks drop it).
    func testHexMasksHighByteNoTrap() {
        assertChannels(Color(hex: 0xFF0C_0D0F), 12.0 / 255, 13.0 / 255, 15.0 / 255)
    }

    /// Opacity is clamped into 0...1 with ordered min/max (never a bare ternary) — out-of-range inputs do
    /// not trap and do not escape the valid alpha range.
    func testHexOpacityClamps() {
        assertChannels(Color(hex: 0x000000, opacity: 2.0), 0, 0, 0, 1)
        assertChannels(Color(hex: 0x000000, opacity: -1.0), 0, 0, 0, 0)
    }

    /// Pin the full ink ramp n0..n12 to its spec hex (channel-resolved, so the representation can't drift).
    func testInkRampPinned() {
        assertChannels(DSPalette.n0, 0x0C / 255, 0x0D / 255, 0x0F / 255)
        assertChannels(DSPalette.n1, 0x12 / 255, 0x13 / 255, 0x16 / 255)
        assertChannels(DSPalette.n2, 0x17 / 255, 0x18 / 255, 0x1C / 255)
        assertChannels(DSPalette.n3, 0x1D / 255, 0x1F / 255, 0x24 / 255)
        assertChannels(DSPalette.n4, 0x24 / 255, 0x26 / 255, 0x2C / 255)
        assertChannels(DSPalette.n5, 0x2B / 255, 0x2E / 255, 0x35 / 255)
        assertChannels(DSPalette.n6, 0x34 / 255, 0x37 / 255, 0x3F / 255)
        assertChannels(DSPalette.n7, 0x3E / 255, 0x42 / 255, 0x4B / 255)
        assertChannels(DSPalette.n8, 0x4C / 255, 0x51 / 255, 0x5B / 255)
        assertChannels(DSPalette.n9, 0x6B / 255, 0x72 / 255, 0x80 / 255)
        assertChannels(DSPalette.n10, 0x9A / 255, 0xA0 / 255, 0xAB / 255)
        assertChannels(DSPalette.n11, 0xC3 / 255, 0xC7 / 255, 0xCE / 255)
        assertChannels(DSPalette.n12, 0xEC / 255, 0xEE / 255, 0xF1 / 255)
    }

    /// Pin the accent ramp a7..a11 to its spec hex.
    func testAccentRampPinned() {
        assertChannels(DSPalette.a7, 0x3A / 255, 0x4F / 255, 0xB0 / 255)
        assertChannels(DSPalette.a8, 0x45 / 255, 0x5D / 255, 0xC8 / 255)
        assertChannels(DSPalette.a9, 0x5E / 255, 0x6A / 255, 0xD2 / 255)
        assertChannels(DSPalette.a10, 0x6E / 255, 0x7A / 255, 0xE0 / 255)
        assertChannels(DSPalette.a11, 0x9E / 255, 0xB1 / 255, 0xFF / 255)
    }

    /// Pin the status ramp to today's fixed-hue values (kept identical; theme-independent).
    func testStatusRampPinned() {
        assertChannels(DSPalette.statusBlue, 0x57 / 255, 0xC1 / 255, 0xFF / 255)
        assertChannels(DSPalette.statusGreen, 0x59 / 255, 0xD4 / 255, 0x99 / 255)
        assertChannels(DSPalette.statusRed, 0xFF / 255, 0x61 / 255, 0x61 / 255)
        assertChannels(DSPalette.statusYellow, 0xFF / 255, 0xC5 / 255, 0x33 / 255)
    }
    #endif
}
