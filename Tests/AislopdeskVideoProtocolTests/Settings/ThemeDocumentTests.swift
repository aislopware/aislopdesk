// ThemeDocument / ThemeRef tests (E15 WI-1) — the leaf parsed-theme model + slot reference. Pure Foundation,
// headless: slug derivation, 6-hex / palette validation (validate-then-drop), the `"none"` background
// allowance, Codable round-trip, and the single-string ThemeRef wire form (incl. decode-fail on an unknown
// form). No SwiftUI / AppKit is touched.

import XCTest
@testable import AislopdeskVideoProtocol

final class ThemeDocumentTests: XCTestCase {
    /// A canonical 16-entry valid palette (Monokai-Pro-ish) for the happy-path documents.
    private static let validPalette = [
        "2D2A2E", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
        "727072", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
    ]

    private func makeValidDoc() -> ThemeDocument {
        ThemeDocument(
            displayName: "My Cool Theme",
            slug: "my-cool-theme",
            mode: .dark,
            foreground: "FCFCFA",
            background: "2D2A2E",
            palette: Self.validPalette,
            cursor: "78DCE8",
            cursorText: "2D2A2E",
            selectionBackground: "403E41",
            accent: "78DCE8",
        )
    }

    // MARK: slug derivation

    func testSlugFromDisplayNameMatchesDocumentedExample() {
        // The documented rule: lowercased, each non-`[a-z0-9]` → `-`.
        XCTAssertEqual(ThemeDocument.slug(from: "My Cool Theme"), "my-cool-theme")
    }

    func testSlugLowercasesAndReplacesEveryNonAlphanumeric() {
        XCTAssertEqual(ThemeDocument.slug(from: "ALLCAPS"), "allcaps")
        XCTAssertEqual(ThemeDocument.slug(from: "a1b2"), "a1b2")
        // Underscore + punctuation are NOT alphanumeric → each becomes `-` (character-for-character).
        XCTAssertEqual(ThemeDocument.slug(from: "Solarized_Dark!"), "solarized-dark-")
        XCTAssertEqual(ThemeDocument.slug(from: "A & B"), "a---b")
    }

    // MARK: hex validation

    func testIsValidHexAcceptsExactSixHexDigits() {
        XCTAssertTrue(ThemeDocument.isValidHex("FF6188"))
        XCTAssertTrue(ThemeDocument.isValidHex("ff6188")) // case-insensitive
        XCTAssertTrue(ThemeDocument.isValidHex("000000"))
    }

    func testIsValidHexRejectsMalformed() {
        XCTAssertFalse(ThemeDocument.isValidHex("#FF6188")) // leading # → wrong length / bad char
        XCTAssertFalse(ThemeDocument.isValidHex("FFF")) // too short
        XCTAssertFalse(ThemeDocument.isValidHex("FF61880")) // too long
        XCTAssertFalse(ThemeDocument.isValidHex("GGGGGG")) // non-hex letters
        XCTAssertFalse(ThemeDocument.isValidHex("")) // empty
        XCTAssertFalse(ThemeDocument.isValidHex("FF618 ")) // embedded whitespace
    }

    func testIsValidBackgroundAllowsNone() {
        XCTAssertTrue(ThemeDocument.isValidBackground("none")) // transparent
        XCTAssertTrue(ThemeDocument.isValidBackground("2D2A2E"))
        XCTAssertFalse(ThemeDocument.isValidBackground("transparent")) // not the literal token
        XCTAssertFalse(ThemeDocument.isValidBackground("#000")) // foreground rules still apply
    }

    // MARK: document validation (validate-then-drop)

    func testValidDocumentPasses() {
        XCTAssertTrue(makeValidDoc().isValid)
    }

    func testNoneBackgroundDocumentIsValid() {
        var doc = makeValidDoc()
        doc.background = "none"
        XCTAssertTrue(doc.isValid)
    }

    func testShortPaletteIsInvalid() {
        var doc = makeValidDoc()
        doc.palette = Array(Self.validPalette.prefix(8)) // only 8 entries
        XCTAssertFalse(doc.isValid)
    }

    func testOverlongPaletteIsInvalid() {
        var doc = makeValidDoc()
        doc.palette = Self.validPalette + ["FFFFFF"] // 17 entries
        XCTAssertFalse(doc.isValid)
    }

    func testBadHexInPaletteIsInvalid() {
        var doc = makeValidDoc()
        doc.palette[5] = "ZZZZZZ"
        XCTAssertFalse(doc.isValid)
    }

    func testBadForegroundIsInvalid() {
        var doc = makeValidDoc()
        doc.foreground = "#fff" // wrong shape
        XCTAssertFalse(doc.isValid)
    }

    func testBadOptionalColourIsInvalid() {
        var doc = makeValidDoc()
        doc.accent = "nope"
        XCTAssertFalse(doc.isValid)
    }

    func testNilOptionalColoursStayValid() {
        var doc = makeValidDoc()
        doc.cursor = nil
        doc.cursorText = nil
        doc.selectionBackground = nil
        doc.accent = nil
        XCTAssertTrue(doc.isValid)
    }

    // MARK: Codable round-trip

    func testCodableRoundTrip() throws {
        let doc = makeValidDoc()
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ThemeDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }

    func testCodableRoundTripWithContainerAndTokenFields() throws {
        var doc = makeValidDoc()
        doc.radius = 15
        doc.shadow = "0 1.5px 6px rgba(0,0,0,0.18)"
        doc.border = "1px solid #2A2E45"
        doc.padding = [8, 16, 8, 16]
        doc.margin = [0]
        doc.fontMono = ["JetBrains Mono", "Menlo"]
        doc.fontUI = ["-apple-system"]
        doc.fontSize = 13
        doc.adjustCellHeight = "20%"
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ThemeDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
    }
}

final class ThemeRefTests: XCTestCase {
    func testEncodedFormAndInit() {
        XCTAssertEqual(ThemeRef.builtin("monokai-classic").encoded, "builtin:monokai-classic")
        XCTAssertEqual(ThemeRef.custom(slug: "my-slug").encoded, "custom:my-slug")
        XCTAssertEqual(ThemeRef(encoded: "builtin:monokai-classic"), .builtin("monokai-classic"))
        XCTAssertEqual(ThemeRef(encoded: "custom:my-slug"), .custom(slug: "my-slug"))
    }

    func testInitRejectsUnknownOrEmptyForms() {
        XCTAssertNil(ThemeRef(encoded: "monokai-classic")) // no prefix
        XCTAssertNil(ThemeRef(encoded: "mystery:foo")) // unknown prefix
        XCTAssertNil(ThemeRef(encoded: "builtin:")) // empty payload
        XCTAssertNil(ThemeRef(encoded: "custom:")) // empty payload
        XCTAssertNil(ThemeRef(encoded: "")) // empty
    }

    func testCodableRoundTripThroughJSONArray() throws {
        // Round-trip via an array to avoid top-level-fragment edge cases; pins the exact single-string form.
        let refs: [ThemeRef] = [.builtin("monokai-classic"), .custom(slug: "my-slug")]
        let data = try JSONEncoder().encode(refs)
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "[\"builtin:monokai-classic\",\"custom:my-slug\"]")
        let decoded = try JSONDecoder().decode([ThemeRef].self, from: data)
        XCTAssertEqual(decoded, refs)
    }

    func testDecodeUnknownFormThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode([ThemeRef].self, from: Data("[\"mystery:foo\"]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode([ThemeRef].self, from: Data("[\"builtin:\"]".utf8)))
    }
}
