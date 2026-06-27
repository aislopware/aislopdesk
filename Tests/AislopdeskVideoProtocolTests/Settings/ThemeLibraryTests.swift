// ThemeLibrary tests (E15 WI-4) — the themes-folder engine. Pure parts (slug collision, directory URL,
// serialise round-trip) run everywhere; the filesystem scan/write parts are macOS-only (iOS has no
// `~/.config`). The FS tests use a unique temp directory and clean it up. No SwiftUI / AppKit is touched.

import XCTest
@testable import AislopdeskVideoProtocol

final class ThemeLibraryTests: XCTestCase {
    // A canonical fully-populated document used for the serialise round-trip.
    private static func richDocument() -> ThemeDocument {
        ThemeDocument(
            displayName: "My Cool Theme",
            slug: "my-cool-theme",
            mode: .dark,
            foreground: "FCFCFA",
            background: "2D2A2E",
            palette: [
                "2D2A2E", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
                "727072", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
            ],
            cursor: "78DCE8",
            cursorText: "2D2A2E",
            selectionBackground: "403E41",
            accent: "78DCE8",
            window: "1A181B",
            sidebar: "221F22",
            titlebar: "19171A",
            tab: "2D2A2E",
            panel: "201E21",
            radius: 12,
            shadow: "0 1.5px 6px rgba(0,0,0,0.18)",
            border: "1px solid #2A2E45",
            padding: [8, 16, 8, 16],
            margin: [0],
            fontMono: ["JetBrains Mono", "Menlo"],
            fontUI: ["-apple-system"],
            fontSize: 13,
            adjustCellHeight: "20%",
        )
    }

    private static func minimalDocument(name: String) -> ThemeDocument {
        ThemeDocument(
            displayName: name,
            slug: ThemeDocument.slug(from: name),
            mode: .dark,
            foreground: "FFFFFF",
            background: "000000",
            palette: [
                "000000", "FF5555", "55FF55", "FFFF55", "5555FF", "FF55FF", "55FFFF", "BBBBBB",
                "444444", "FF8888", "88FF88", "FFFF88", "8888FF", "FF88FF", "88FFFF", "FFFFFF",
            ],
        )
    }

    // MARK: slug collision (pure)

    func testUniqueSlugReturnsBaseWhenFree() {
        XCTAssertEqual(ThemeLibrary.uniqueSlug("foo-bar", existing: []), "foo-bar")
    }

    func testUniqueSlugSuffixesOnCollision() {
        XCTAssertEqual(ThemeLibrary.uniqueSlug("foo-bar", existing: ["foo-bar"]), "foo-bar-1")
        XCTAssertEqual(ThemeLibrary.uniqueSlug("foo-bar", existing: ["foo-bar", "foo-bar-1"]), "foo-bar-2")
    }

    func testUniqueSlugEmptyBaseFallsBackToTheme() {
        XCTAssertEqual(ThemeLibrary.uniqueSlug("", existing: []), "theme")
        XCTAssertEqual(ThemeLibrary.uniqueSlug("", existing: ["theme"]), "theme-1")
    }

    func testResolveCollisionsPreservesOrderAndDistinguishesSlugs() {
        let a = Self.minimalDocument(name: "Theme A") // slug theme-a
        let b = Self.minimalDocument(name: "Theme!A") // slug also theme-a
        let resolved = ThemeLibrary.resolveCollisions([a, b])
        XCTAssertEqual(resolved.map(\.slug), ["theme-a", "theme-a-1"])
    }

    // MARK: directory URL (pure)

    func testThemesDirectoryURLHonoursXDG() {
        let url = ThemeLibrary.themesDirectoryURL(environment: ["XDG_CONFIG_HOME": "/x/config"])
        XCTAssertEqual(url?.path, "/x/config/aislopdesk/themes")
    }

    func testThemesDirectoryURLFallsBackToHome() {
        let url = ThemeLibrary.themesDirectoryURL(environment: ["HOME": "/Users/me"])
        XCTAssertEqual(url?.path, "/Users/me/.config/aislopdesk/themes")
    }

    func testThemesDirectoryURLNilWithoutBase() {
        XCTAssertNil(ThemeLibrary.themesDirectoryURL(environment: [:]))
    }

    // MARK: serialise round-trip (pure)

    func testSerialiseRoundTripPreservesEveryField() {
        let original = Self.richDocument()
        let text = ThemeLibrary.serialize(original)
        guard let reparsed = ThemeTOMLParser.parse(text, fallbackName: original.slug) else {
            XCTFail("serialised theme failed to re-parse")
            return
        }
        XCTAssertEqual(reparsed, original)
    }

    func testSerialiseRoundTripWithNoneBackground() {
        var original = Self.minimalDocument(name: "Ghost")
        original.background = "none"
        let reparsed = ThemeTOMLParser.parse(ThemeLibrary.serialize(original), fallbackName: original.slug)
        XCTAssertEqual(reparsed, original)
    }

    #if os(macOS)

    // MARK: filesystem scan / write (macOS)

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-themelib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func writeFile(_ name: String, _ contents: String) throws {
        try contents.write(
            to: tempDir.appendingPathComponent("\(name).ottytheme", isDirectory: false),
            atomically: true, encoding: .utf8,
        )
    }

    func testWriteThenScanRoundTrip() throws {
        let original = Self.richDocument()
        let result = try ThemeLibrary.write(original, to: tempDir)
        XCTAssertEqual(result.slug, "my-cool-theme")
        XCTAssertEqual(result.url.lastPathComponent, "my-cool-theme.ottytheme")

        let scanned = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first, original)
    }

    func testScanMissingDirectoryReturnsEmpty() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertTrue(ThemeLibrary.scan(directory: missing).isEmpty)
    }

    func testScanEmptyDirectoryReturnsEmpty() {
        XCTAssertTrue(ThemeLibrary.scan(directory: tempDir).isEmpty)
    }

    func testScanDropsInvalidFilesButKeepsValidOnes() throws {
        try ThemeLibrary.write(Self.minimalDocument(name: "Good"), to: tempDir)
        try writeFile("bad", "[meta]\nname = \"Bad\"\n") // no [terminal] → invalid
        let scanned = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.map(\.slug), ["good"])
    }

    func testScanDeduplicatesCollidingFileNameSlugs() throws {
        // Two distinct files whose FILE NAMES (the `.ottytheme` basenames — the slug source of truth) slug to
        // the same value get de-collided. The display names inside are irrelevant to the slug.
        try writeFile("Theme A", ThemeLibrary.serialize(Self.minimalDocument(name: "First")))
        try writeFile("Theme!A", ThemeLibrary.serialize(Self.minimalDocument(name: "Second")))
        let scanned = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(Set(scanned.map(\.slug)), ["theme-a", "theme-a-1"])
        XCTAssertEqual(scanned.count, 2)
    }

    /// INTEGRATION (the SLUG-STABILITY guarantee): a custom theme's persisted slug is the on-disk FILE NAME and
    /// must SURVIVE a display-name rename, so a stored `customLightSlug`/`customDarkSlug` keeps resolving. Drives
    /// the real serialise → write → scan → parse path. REVERT-TO-CONFIRM-FAIL: on the pre-fix `scan()` (which
    /// re-slugged from the display name) the first slug is `"original-name"`, not the file name `"stable-id"`,
    /// and the post-rename slug becomes `"a-totally-different-name"` — both assertions fail.
    func testScanSlugSurvivesDisplayNameRename() throws {
        // The file name deliberately differs from the display-name slug ("Original Name" → "original-name").
        try writeFile("stable-id", ThemeLibrary.serialize(Self.minimalDocument(name: "Original Name")))

        let firstScan = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(firstScan.count, 1)
        guard let slug = firstScan.first?.slug else {
            XCTFail("expected the custom theme to scan")
            return
        }
        XCTAssertEqual(slug, "stable-id", "slug is the file name, not the display-name slug")

        // The user renames ONLY the display name; the on-disk file name (and thus its identity) is unchanged.
        let renamed = Self.minimalDocument(name: "A Totally Different Name")
        try writeFile("stable-id", ThemeLibrary.serialize(renamed))

        let secondScan = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(secondScan.count, 1)
        XCTAssertEqual(secondScan.first?.displayName, "A Totally Different Name")
        XCTAssertEqual(secondScan.first?.slug, slug, "the persisted slug must survive a display-name rename")
        // The previously-persisted slug still resolves to a theme (the slot would not silently fall back).
        XCTAssertTrue(secondScan.contains { $0.slug == slug })
    }

    func testScanResolvesInheritsAcrossFiles() throws {
        let parent = Self.minimalDocument(name: "Base") // slug base
        try ThemeLibrary.write(parent, to: tempDir)
        let child = """
        inherits = "Base"

        [meta]
        name = "Child"

        [terminal]
        foreground = "#123456"
        """
        try writeFile("child", child)

        let scanned = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.count, 2)
        guard let resolvedChild = scanned.first(where: { $0.slug == "child" }) else {
            XCTFail("expected the inheriting child theme to resolve")
            return
        }
        XCTAssertEqual(resolvedChild.foreground, "123456") // overridden
        XCTAssertEqual(resolvedChild.background, parent.background) // inherited
        XCTAssertEqual(resolvedChild.palette, parent.palette) // inherited (not restated)
    }

    func testScanResolvesInheritsFromBuiltin() throws {
        let builtin = Self.minimalDocument(name: "Shipped") // not on disk
        let child = """
        inherits = "Shipped"

        [meta]
        name = "Derived"

        [terminal]
        foreground = "#ABCDEF"
        """
        try writeFile("derived", child)

        let scanned = ThemeLibrary.scan(directory: tempDir, builtins: [builtin])
        XCTAssertEqual(scanned.count, 1) // the built-in is NOT returned, only the on-disk derived theme
        XCTAssertEqual(scanned.first?.slug, "derived")
        XCTAssertEqual(scanned.first?.foreground, "ABCDEF")
        XCTAssertEqual(scanned.first?.palette, builtin.palette) // inherited from the built-in
    }
    #endif
}
