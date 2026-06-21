import XCTest
@testable import AislopdeskClientUI
#if canImport(AppKit)
import AppKit
#endif

/// Pins the deduped contrast helper ``DSPalette.contrastingForeground(for:)`` — black on a light colour,
/// white on a dark one, threshold 0.6 on the sRGB relative luminance (0.2126·r + 0.7152·g + 0.0722·b,
/// separated products, never FMA). Also asserts the legacy ``AislopdeskTheme.contrastingForeground(for:)``
/// shim forwards to it identically (the one helper that was dedup-and-forwarded in P1).
final class DSContrastHelperTests: XCTestCase {
    #if canImport(AppKit)
    /// A clearly LIGHT colour (systemYellow, luminance ≫ 0.6) → black foreground.
    func testLightColorPicksBlack() {
        XCTAssertEqual(DSPalette.contrastingForeground(for: .white), .black)
        XCTAssertEqual(DSPalette.contrastingForeground(for: NSColor.systemYellow), .black)
    }

    /// A clearly DARK colour → white foreground.
    func testDarkColorPicksWhite() {
        XCTAssertEqual(DSPalette.contrastingForeground(for: .black), .white)
        XCTAssertEqual(
            DSPalette.contrastingForeground(for: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)),
            .white,
        )
    }

    /// Pin the 0.6 threshold boundary. The rule is `luminance > 0.6 ? .black : .white`, so the boundary is
    /// OPEN on the black side: exactly 0.6 is NOT > 0.6 ⇒ white. A pure grey has luminance == its component
    /// value, so 0.59 → white, 0.60 → white (the open-boundary case), 0.61 → black.
    func testThresholdBoundary() {
        let justBelow = NSColor(srgbRed: 0.59, green: 0.59, blue: 0.59, alpha: 1)
        let exactly = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        let justAbove = NSColor(srgbRed: 0.61, green: 0.61, blue: 0.61, alpha: 1)
        XCTAssertEqual(DSPalette.contrastingForeground(for: justBelow), .white, "0.59 < 0.6 ⇒ white")
        XCTAssertEqual(DSPalette.contrastingForeground(for: exactly), .white, "0.6 is NOT > 0.6 ⇒ white")
        XCTAssertEqual(DSPalette.contrastingForeground(for: justAbove), .black, "0.61 > 0.6 ⇒ black")
    }

    /// The legacy shim forwards to the DS helper — identical output for the same inputs (the dedup must be
    /// transparent).
    func testLegacyShimForwardsIdentically() {
        for color in [NSColor.white, .black, .systemYellow, .systemBlue, .systemGreen, .systemRed] {
            XCTAssertEqual(
                AislopdeskTheme.contrastingForeground(for: color),
                DSPalette.contrastingForeground(for: color),
                "the AislopdeskTheme shim must match the deduped DSPalette helper",
            )
        }
    }
    #endif
}
