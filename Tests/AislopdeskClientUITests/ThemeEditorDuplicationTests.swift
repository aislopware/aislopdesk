// ThemeEditorView Duplicate materialisation tests (E15 WI-7) — the pure piece behind the Theme editor's
// "Duplicate" button: turning a resolved built-in ``OttyTheme`` into a writable custom ``ThemeDocument`` so a
// read-only built-in can be copied into an editable `.ottytheme`. The UI itself (swatch grid / ColorPickers /
// open panel) is GUI-verified (`scripts/check-macos.sh`); this pins the materialisation + the round-trip that
// guarantees the duplicated theme is a VALID, re-readable file. Pure logic; no SCStream/VT/Metal/surface.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ThemeEditorDuplicationTests: XCTestCase {
    // MARK: materialise(builtin) → ThemeDocument

    /// A dark built-in materialises into a valid document whose TERMINAL palette is byte-identical to the
    /// theme's canonical ANSI set (so the copy renders the same cells), in the dark slot.
    func testMaterializeDarkBuiltinCarriesPaletteAndMode() {
        let theme = OttyTheme.monokaiProClassic
        let doc = ThemeDocument(materializing: theme, displayName: "Monokai Pro Classic", slug: "monokai-pro-classic")

        XCTAssertTrue(doc.isValid, "a materialised built-in must be a writable, valid document")
        XCTAssertEqual(doc.mode, .dark, "Monokai Pro Classic is a dark theme")
        XCTAssertEqual(doc.palette, theme.ansiPalette, "the 16-entry ANSI palette passes through verbatim")
        XCTAssertEqual(doc.foreground, theme.terminalForegroundHex)
        XCTAssertEqual(doc.background, theme.terminalBackgroundHex)
        XCTAssertEqual(doc.cursor, theme.cursorHex)
        XCTAssertEqual(doc.cursorText, theme.cursorTextHex)
        XCTAssertEqual(doc.selectionBackground, theme.selectionBackgroundHex)
    }

    /// A light built-in materialises into the LIGHT slot (so Duplicate of a light theme stays light).
    func testMaterializeLightBuiltinIsLightMode() {
        let doc = ThemeDocument(
            materializing: .monokaiProClassicLight,
            displayName: "Monokai Pro Light",
            slug: "monokai-pro-light",
        )
        XCTAssertEqual(doc.mode, .light)
        XCTAssertTrue(doc.isValid)
    }

    /// EVERY shipped built-in materialises into a VALID document (16 clean-hex palette + valid fg/bg) — the
    /// Duplicate button must never produce an unwritable theme regardless of which built-in is active.
    func testEveryBuiltinMaterialisesValid() {
        for theme in ThemeCatalog.builtinThemes {
            let doc = ThemeDocument(materializing: theme, displayName: theme.id, slug: theme.id)
            XCTAssertTrue(doc.isValid, "\(theme.id) must materialise into a valid document")
            XCTAssertEqual(doc.palette.count, 16, "\(theme.id) must carry all 16 ANSI colours")
        }
    }

    // MARK: round-trip through the on-disk serialiser

    /// The materialised document round-trips through the SAME serialiser/parser the editor writes with
    /// (`ThemeLibrary.serialize` → `ThemeTOMLParser.parse`) back to an EQUAL document — proving Duplicate
    /// writes a `.ottytheme` the scan can read back. This FAILS if materialisation emitted a short/invalid
    /// palette or a malformed hex (the parser would then drop it to `nil`).
    func testMaterialisedDocumentRoundTripsThroughDisk() throws {
        let name = "Monokai Pro Classic"
        let original = ThemeDocument(
            materializing: .monokaiProClassic,
            displayName: name,
            slug: ThemeDocument.slug(from: name),
        )

        let toml = ThemeLibrary.serialize(original)
        let parsed = try XCTUnwrap(
            ThemeTOMLParser.parse(toml, fallbackName: name),
            "the serialised duplicate must parse back to a valid theme",
        )
        XCTAssertEqual(parsed, original, "Duplicate must write a faithfully re-readable theme")
    }

    // MARK: friendly display names (Duplicate base name)

    /// The Duplicate base name maps a built-in id → its picker label, and a custom id → its slug.
    func testFriendlyNameMapsBuiltinsAndCustoms() {
        XCTAssertEqual(ThemeEditorView.friendlyName(for: .monokaiProClassic), "Monokai Pro (Classic)")
        XCTAssertEqual(ThemeEditorView.friendlyName(for: .paper), "Paper")
        XCTAssertEqual(ThemeEditorView.friendlyName(for: .dark), "Dark")

        let custom = OttyTheme(document: ThemeDocument(
            displayName: "My Theme", slug: "my-theme", mode: .dark,
            foreground: "FFFFFF", background: "000000",
            palette: Array(repeating: "808080", count: 16),
        ))
        XCTAssertEqual(ThemeEditorView.friendlyName(for: custom), "my-theme", "a custom id drops the custom- prefix")
    }
}
#endif
