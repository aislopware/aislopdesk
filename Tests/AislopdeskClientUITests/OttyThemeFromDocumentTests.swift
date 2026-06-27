// OttyTheme ← ThemeDocument tests (E15 WI-1) — the built-in ANSI palettes + the `init(document:)` bridge
// that turns a scanned custom `.ottytheme` into a full chrome theme. Asserts on the STRING/Bool-typed fields
// (palette, terminal hexes, slot id, selection/cursor hexes, isLight) — the load-bearing "the document's
// colours actually reach the theme" contract — not on derived SwiftUI `Color` chrome (GUI-verified). Pure
// logic; no SCStream/VT/Metal/surface is touched.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class OttyThemeFromDocumentTests: XCTestCase {
    private static let palette = [
        "2D2A2E", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
        "727072", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
    ]

    private func darkDoc() -> ThemeDocument {
        ThemeDocument(
            displayName: "My Cool Theme",
            slug: "my-cool-theme",
            mode: .dark,
            foreground: "FCFCFA",
            background: "2D2A2E",
            palette: Self.palette,
            cursor: "78DCE8",
            cursorText: "2D2A2E",
            selectionBackground: "403E41",
            accent: "78DCE8",
        )
    }

    // MARK: init(document:)

    func testDarkDocumentDataFlowsIntoTheTheme() {
        let theme = OttyTheme(document: darkDoc())
        XCTAssertFalse(theme.isLight, ".dark mode ⇒ a dark theme")
        XCTAssertEqual(theme.ansiPalette, Self.palette, "the 16-entry palette passes through verbatim")
        XCTAssertEqual(theme.terminalBackgroundHex, "2D2A2E")
        XCTAssertEqual(theme.terminalForegroundHex, "FCFCFA")
        XCTAssertEqual(theme.id, "custom-my-cool-theme", "the slot id is custom-<slug>")
        XCTAssertEqual(theme.selectionBackgroundHex, "403E41")
        XCTAssertEqual(theme.cursorHex, "78DCE8")
        XCTAssertEqual(theme.cursorTextHex, "2D2A2E")
    }

    func testLightModeProducesALightTheme() {
        var doc = darkDoc()
        doc.mode = .light
        doc.slug = "solar"
        let theme = OttyTheme(document: doc)
        XCTAssertTrue(theme.isLight)
        XCTAssertEqual(theme.id, "custom-solar")
    }

    func testNilOptionalColoursStayNilOnTheTheme() {
        var doc = darkDoc()
        doc.cursor = nil
        doc.cursorText = nil
        doc.selectionBackground = nil
        let theme = OttyTheme(document: doc)
        XCTAssertNil(theme.cursorHex)
        XCTAssertNil(theme.cursorTextHex)
        XCTAssertNil(theme.selectionBackgroundHex)
    }

    /// A `"none"` (transparent) background still yields a VALID 6-hex terminal-cell pin — the dark fallback
    /// black — so the libghostty `background` override is never the bare token `none`.
    func testNoneBackgroundFallsBackToAValidTerminalHex() {
        var doc = darkDoc()
        doc.background = "none"
        let theme = OttyTheme(document: doc)
        XCTAssertEqual(theme.terminalBackgroundHex, "000000")
    }

    /// A `#`-prefixed / lowercase background is tolerated by the parse path and re-emitted as a clean
    /// UPPERCASE `#`-less 6-hex (proves rgb24 strips `#` and hex6 normalises) — what libghostty + the swatch
    /// grid expect.
    func testHashPrefixedLowercaseBackgroundNormalises() {
        var doc = darkDoc()
        doc.background = "#2d2a2e"
        let theme = OttyTheme(document: doc)
        XCTAssertEqual(theme.terminalBackgroundHex, "2D2A2E")
    }

    // MARK: built-in canonical palettes

    func testBuiltInThemesShipA16EntryPalette() {
        for theme in [
            OttyTheme.monokaiProClassic, .monokaiProClassicLight, .monokaiProOctagon,
            .monokaiProMachine, .monokaiProRistretto, .monokaiProSpectrum, .paper, .dark,
        ] {
            XCTAssertEqual(theme.ansiPalette.count, 16, "\(theme.id) must declare all 16 ANSI colours")
            XCTAssertTrue(
                theme.ansiPalette.allSatisfy(ThemeDocument.isValidHex),
                "\(theme.id) palette entries must be clean 6-hex",
            )
        }
    }

    /// The Monokai Pro Classic ANSI palette is the canonical filter palette: color0 = background, the filter
    /// chromatics in ANSI order (red/green/yellow, orange in the "blue" slot, purple, cyan), white = fg.
    func testMonokaiClassicPaletteIsCanonical() {
        let p = OttyTheme.monokaiProClassic.ansiPalette
        XCTAssertEqual(p[0], "2D2A2E", "color0 = background (Monokai's quirk)")
        XCTAssertEqual(p[1], "FF6188", "red")
        XCTAssertEqual(p[2], "A9DC76", "green")
        XCTAssertEqual(p[3], "FFD866", "yellow")
        XCTAssertEqual(p[4], "FC9867", "orange in the ANSI blue slot")
        XCTAssertEqual(p[5], "AB9DF2", "purple/magenta")
        XCTAssertEqual(p[6], "78DCE8", "cyan/accent")
        XCTAssertEqual(p[7], "FCFCFA", "white = foreground")
        XCTAssertEqual(p[8], "727072", "bright-black = dimmed grey")
        // The bright chromatics repeat the normal ones (Monokai Pro's bright == normal).
        XCTAssertEqual(Array(p[9...14]), Array(p[1...6]))
    }
}
#endif
