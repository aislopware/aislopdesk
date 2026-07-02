import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the Slate-rename recovery for saved recipes: a pre-rename `.ottyrecipe` file must be renamed in
/// place to `.aislopdeskrecipe` on scan and returned, so a user's saved recipes don't silently vanish from
/// the Open-Recipe picker after updating past commit 37d65f2 (which changed the extension with no migration).
final class RecipeLibraryLegacyScanTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-recipelib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func sampleRecipe() -> Recipe {
        Recipe(
            name: "deploy",
            version: 1,
            scope: .window,
            window: RecipeWindow(tabs: [
                RecipeTab(title: "API", panes: [RecipePane(cwd: "{{current_folder}}", commands: ["make deploy"])]),
            ]),
        )
    }

    func testScanRenamesAndReadsLegacyOttyrecipeFiles() throws {
        let text = RecipeTOMLCodec.emit(sampleRecipe())
        let legacyURL = tempDir.appendingPathComponent("deploy.ottyrecipe", isDirectory: false)
        try Data(text.utf8).write(to: legacyURL, options: [.atomic])

        let scanned = RecipeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.count, 1, "the legacy .ottyrecipe file is scanned again")
        XCTAssertEqual(scanned.first?.recipe?.name, "deploy", "and parses back to the recipe")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path),
            "the legacy file was renamed in place (no dead duplicate)",
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("deploy.aislopdeskrecipe").path,
        ), "it now carries the new extension")
    }

    func testScanDoesNotClobberAnExistingNewExtensionRecipe() throws {
        _ = try RecipeLibrary.write(sampleRecipe(), to: tempDir, slug: "deploy")
        let legacyURL = tempDir.appendingPathComponent("deploy.ottyrecipe", isDirectory: false)
        try Data(RecipeTOMLCodec.emit(sampleRecipe()).utf8).write(to: legacyURL, options: [.atomic])

        let scanned = RecipeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.count, 1, "the new-extension recipe wins; the legacy is not clobbered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path), "the legacy file is left intact")
    }
}
