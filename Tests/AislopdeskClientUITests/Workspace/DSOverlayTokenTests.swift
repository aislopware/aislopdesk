import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// P4 overlay-unification pins: the THREE ad-hoc scrim copies collapse to ONE `DSColor.scrim`, the THREE
/// inline shadow profiles collapse to the TWO `DSElevation` tokens, and the command-palette selection stays
/// legible under ANY accent (the `accentForeground` contrast helper, never literal white). All pure values
/// — no NSWindow / Ghostty / SCStream / VT is instantiated (the hang-safety rule); the SwiftUI LAYOUT
/// (640×464, top placement, glass look) is HW-verified by the parent via check-macos.sh.
@MainActor
final class DSOverlayTokenTests: XCTestCase {
    #if canImport(SwiftUI) && canImport(AppKit)
    /// Resolves a SwiftUI `Color` to its sRGB (r,g,b,a) components (same resolution as DSColorHexParseTests).
    private func srgb(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (
            Double(ns.redComponent),
            Double(ns.greenComponent),
            Double(ns.blueComponent),
            Double(ns.alphaComponent),
        )
    }

    // MARK: - Scrim token identity (the ONE overlay-backdrop colour)

    /// `DSColor.scrim` is black·0.40 — the single token the three `.black.opacity(0.18)` scrim copies in
    /// CommandPalette / PeekReply / CheatSheet migrated to. Resolved to sRGB so the value can't drift.
    func testScrimIsBlack040() {
        guard let c = srgb(DSColor.scrim) else { XCTFail("could not resolve scrim")
            return
        }
        XCTAssertEqual(c.r, 0, accuracy: 0.001, "scrim is pure black")
        XCTAssertEqual(c.g, 0, accuracy: 0.001)
        XCTAssertEqual(c.b, 0, accuracy: 0.001)
        XCTAssertEqual(c.a, 0.40, accuracy: 0.001, "scrim alpha is 0.40 (deeper than the old 0.18)")
    }
    #endif

    // MARK: - Shadow token identity (exactly TWO profiles on the 6 overlays)

    #if canImport(SwiftUI)
    /// Restore the shared multiplier after any test mutates it, so order-independence holds.
    override func tearDown() {
        DSScale.shared.multiplier = 1.0
        DSThemeStore.shared.accent = nil
        super.tearDown()
    }

    /// `DSElevation.shadowOverlay` is the L4 overlay profile: radius 24, y 8 at multiplier 1.0 (palette /
    /// peek / cheat-sheet / floating layer). The radius/y scale with `DSScale`.
    func testShadowOverlaySpec() {
        DSScale.shared.multiplier = 1.0
        let s = DSElevation.shadowOverlay
        XCTAssertEqual(s.radius, 24, accuracy: 1e-9, "shadowOverlay radius is 24 at multiplier 1.0")
        XCTAssertEqual(s.y, 8, accuracy: 1e-9, "shadowOverlay y is 8 at multiplier 1.0")
        XCTAssertEqual(s.x, 0, accuracy: 1e-9, "shadowOverlay has no horizontal offset")
    }

    /// `DSElevation.shadowModal` is the hard-modal profile: radius 28, y 10 at multiplier 1.0 (connection
    /// gate / settings sheet) — heavier than the overlay profile.
    func testShadowModalSpec() {
        DSScale.shared.multiplier = 1.0
        let s = DSElevation.shadowModal
        XCTAssertEqual(s.radius, 28, accuracy: 1e-9, "shadowModal radius is 28 at multiplier 1.0")
        XCTAssertEqual(s.y, 10, accuracy: 1e-9, "shadowModal y is 10 at multiplier 1.0")
    }

    /// Both shadow tokens scale with `DSScale` (single `*`, no FMA) — a density flip moves the radius/offset
    /// in lockstep, which a raw inline `.shadow(radius: 24)` could never do.
    func testShadowTokensScaleWithDensity() {
        defer { DSScale.shared.multiplier = 1.0 }
        DSScale.shared.multiplier = 1.5
        XCTAssertEqual(DSElevation.shadowOverlay.radius, 24 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(DSElevation.shadowOverlay.y, 8 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(DSElevation.shadowModal.radius, 28 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(DSElevation.shadowModal.y, 10 * 1.5, accuracy: 1e-9)
    }
    #endif

    #if canImport(SwiftUI) && canImport(AppKit)
    /// Both shadow profiles share the ONE scrim-deep colour (black·0.40) — there is no third inline colour.
    func testShadowTokensShareBlack040Color() {
        for shadow in [DSElevation.shadowOverlay, DSElevation.shadowModal] {
            guard let c = srgb(shadow.color) else { XCTFail("could not resolve shadow colour")
                return
            }
            XCTAssertEqual(c.r, 0, accuracy: 0.001)
            XCTAssertEqual(c.g, 0, accuracy: 0.001)
            XCTAssertEqual(c.b, 0, accuracy: 0.001)
            XCTAssertEqual(c.a, 0.40, accuracy: 0.001, "shadow colour is black·0.40")
        }
    }

    // MARK: - Palette-selection legibility (the spec-named Color.white-on-light-accent bug)

    /// THE legibility fix: `DSColor.accentForeground` is the CONTRAST helper's output for the resolved
    /// accent, NEVER a literal white. On a light system accent the helper returns BLACK — so a glyph painted
    /// on an accent fill stays legible. Asserts `accentForeground` tracks the contrast helper (the dedup),
    /// not a hardcoded `.white`. (The new palette goes further — it uses selectionWash + textPrimary, no
    /// solid-accent fill at all — but the helper must still be contrast-driven for any future solid fill.)
    func testAccentForegroundIsContrastDrivenNotLiteralWhite() {
        let expected = Color(nsColor: DSPalette.contrastingForeground(for: NSColor.controlAccentColor))
        XCTAssertEqual(
            srgb(DSColor.accentForeground).map { [$0.r, $0.g, $0.b, $0.a] },
            srgb(expected).map { [$0.r, $0.g, $0.b, $0.a] },
            "accentForeground must equal the contrast helper output, never a hardcoded white",
        )
    }

    /// The selection WASH is accent·0.18 over the resolved accent — a translucent tint, NOT a solid accent
    /// fill (the spec rule that keeps the selected row legible under any accent). Pin alpha 0.18 and prove
    /// the RGB tracks the active accent (here the default indigo a9, since the store override is nil).
    func testSelectionWashIsAccentAt018NotSolidFill() {
        DSThemeStore.shared.accent = nil // resolve to the DS default indigo a9
        guard let wash = srgb(DSColor.selectionWash), let a9 = srgb(DSPalette.a9) else {
            XCTFail("could not resolve selectionWash / a9")
            return
        }
        XCTAssertEqual(wash.a, 0.18, accuracy: 0.001, "selectionWash is a 0.18 translucent tint, not a solid fill")
        XCTAssertEqual(wash.r, a9.r, accuracy: 0.001, "selectionWash hue follows the active accent (a9)")
        XCTAssertEqual(wash.g, a9.g, accuracy: 0.001)
        XCTAssertEqual(wash.b, a9.b, accuracy: 0.001)
    }

    /// Flipping the theme accent to a LIGHT colour drives `selectionWash` to that accent at 0.18 (it tracks
    /// the override) — and the contrast helper for a light accent returns black, so even a hypothetical
    /// solid-accent fill would paint black-on-light, never the illegible white-on-light of the old bug.
    func testSelectionWashTracksLightAccentOverrideAndContrastIsLegible() {
        defer { DSThemeStore.shared.accent = nil }
        // A clearly LIGHT accent (luminance ≫ 0.6).
        DSThemeStore.shared.accent = Color(nsColor: .systemYellow)
        guard let wash = srgb(DSColor.selectionWash), let yellow = srgb(Color(nsColor: .systemYellow)) else {
            XCTFail("could not resolve")
            return
        }
        XCTAssertEqual(wash.a, 0.18, accuracy: 0.001, "wash stays a 0.18 tint under a light accent")
        XCTAssertEqual(wash.r, yellow.r, accuracy: 0.01, "wash hue follows the light accent override")
        XCTAssertEqual(wash.g, yellow.g, accuracy: 0.01)
        XCTAssertEqual(wash.b, yellow.b, accuracy: 0.01)
        // The contrast helper for the light accent is BLACK (the legibility guarantee).
        XCTAssertEqual(
            DSPalette.contrastingForeground(for: .systemYellow), .black,
            "a light accent yields a BLACK contrast foreground — never the old illegible white",
        )
    }
    #endif
}
