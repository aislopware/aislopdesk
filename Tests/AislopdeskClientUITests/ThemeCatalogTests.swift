// ThemeCatalog tests (E15 WI-6) — the available-themes directory + the `ThemeRef` → `OttyTheme` resolver
// ClientUI uses. Pure logic only: the built-in id table, the injected custom-scan seam, `customDocument(slug:)`
// lookup, `reloadCustom()` re-scan, and the resolve fallbacks. The folder scan is driven through the injected
// `scan` closure so NO filesystem is touched; no SCStream/VT/Metal/surface is touched either.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ThemeCatalogTests: XCTestCase {
    private static let palette = [
        "282A36", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
        "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF",
    ]

    private func dracula() -> ThemeDocument {
        ThemeDocument(
            displayName: "Dracula", slug: "dracula", mode: .dark,
            foreground: "F8F8F2", background: "282A36", palette: Self.palette,
        )
    }

    private func nord() -> ThemeDocument {
        ThemeDocument(
            displayName: "Nord", slug: "nord", mode: .dark,
            foreground: "D8DEE9", background: "2E3440", palette: Self.palette,
        )
    }

    /// A catalog whose custom-scan returns a fixed set — no filesystem.
    private func catalog(scanning documents: [ThemeDocument]) -> ThemeCatalog {
        ThemeCatalog(scan: { _ in documents })
    }

    // MARK: - resolve(builtin:)

    /// A `.builtin` ref resolves to the matching shipped `OttyTheme`; an UNKNOWN id falls back to the default.
    func testResolveBuiltinRef() {
        let cat = catalog(scanning: [])
        XCTAssertEqual(cat.resolve(.builtin("monokai-classic")).id, "monokai-classic")
        XCTAssertEqual(cat.resolve(.builtin("paper")).id, "paper")
        XCTAssertTrue(cat.resolve(.builtin("paper")).isLight)
        // Unknown built-in id ⇒ the default Monokai Pro Classic (graceful, never a crash).
        XCTAssertEqual(cat.resolve(.builtin("does-not-exist")).id, "monokai-classic")
    }

    // MARK: - resolve(custom:)

    /// A `.custom` ref resolves to `OttyTheme(document:)` ONCE the slug is scanned in — the document's terminal
    /// colours drive the resolved theme. Revert-to-confirm: before `reloadCustom()` the same ref falls back to
    /// the default, proving the scan is load-bearing.
    func testResolveCustomRefAfterReload() {
        let cat = catalog(scanning: [dracula()])
        // Pre-scan: the slug is unknown ⇒ default fallback.
        XCTAssertEqual(cat.resolve(.custom(slug: "dracula")).id, "monokai-classic")
        cat.reloadCustom()
        let resolved = cat.resolve(.custom(slug: "dracula"))
        XCTAssertEqual(resolved.id, "custom-dracula")
        XCTAssertEqual(resolved.terminalBackgroundHex, "282A36", "the document drives the terminal cells")
        XCTAssertEqual(resolved.ansiPalette, Self.palette)
    }

    /// A `.custom` ref for a slug that is NOT in the scan (since-deleted / typo) falls back to the default —
    /// never a crash.
    func testResolveCustomRefFallsBackWhenAbsent() {
        let cat = catalog(scanning: [dracula()])
        cat.reloadCustom()
        XCTAssertEqual(cat.resolve(.custom(slug: "ghost")).id, "monokai-classic")
    }

    // MARK: - list + lookup + reload

    /// `customThemes` is empty until `reloadCustom()`, then mirrors the scan; `customDocument(slug:)` looks up
    /// by slug and returns `nil` for an unknown one.
    func testCustomListAndLookup() {
        let cat = catalog(scanning: [dracula(), nord()])
        XCTAssertTrue(cat.customThemes.isEmpty, "no custom themes before a scan")
        cat.reloadCustom()
        XCTAssertEqual(cat.customThemes.map(\.slug), ["dracula", "nord"])
        XCTAssertEqual(cat.customDocument(slug: "nord")?.displayName, "Nord")
        XCTAssertNil(cat.customDocument(slug: "ghost"), "an unknown slug looks up to nil")
    }

    /// `reloadCustom()` RE-scans: a catalog whose underlying set changes between scans reflects the new set
    /// (the import → re-scan → picker-refresh path). Returns the freshly scanned list.
    func testReloadRescans() {
        var documents = [dracula()]
        let cat = ThemeCatalog(scan: { _ in documents })
        XCTAssertEqual(cat.reloadCustom().map(\.slug), ["dracula"])
        documents = [dracula(), nord()] // a new theme was imported
        let rescanned = cat.reloadCustom()
        XCTAssertEqual(rescanned.map(\.slug), ["dracula", "nord"])
        XCTAssertEqual(cat.customThemes.map(\.slug), ["dracula", "nord"])
    }

    // MARK: - built-ins

    /// The built-in id table round-trips: every shipped theme in `builtinThemes` resolves back to itself via
    /// `builtin(id:)` (catches a drift between the list and the id→theme table).
    func testBuiltinThemesRoundTrip() {
        let cat = catalog(scanning: [])
        for theme in ThemeCatalog.builtinThemes {
            XCTAssertEqual(cat.builtin(id: theme.id)?.id, theme.id, "\(theme.id) must resolve to itself")
        }
        XCTAssertNil(cat.builtin(id: "nope"), "an unknown built-in id looks up to nil")
    }
}
#endif
