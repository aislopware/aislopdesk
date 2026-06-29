// ThemeImportSwitchTests — Batch-4 item 6: a theme import ADDS to the library WITHOUT switching the active
// theme by default; ticking "Switch to it now" activates it (themes spec §Import). The activation decision is
// the pure `ThemeEditorView.importOutcome` seam (no `NSOpenPanel` / disk import / `ThemeStore` singleton),
// so the default-no-auto-switch contract is pinned headlessly. Revert-to-confirm-fail: the pre-fix
// `importTheme` ALWAYS called `activate(slug:)`, so `importOutcome(...).activate` would be unconditionally
// true.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class ThemeImportSwitchTests: XCTestCase {
    func testImportDoesNotAutoSwitchByDefault() {
        let outcome = ThemeEditorView.importOutcome(slug: "nord", switchToImported: false)
        XCTAssertFalse(outcome.activate, "import ADDS only by default — it must not switch the active theme")
        XCTAssertTrue(
            outcome.statusMessage.contains("nord"),
            "the status line names the imported slug so the user can find it in the library",
        )
    }

    func testSwitchToItNowActivatesTheImportedSlug() {
        let outcome = ThemeEditorView.importOutcome(slug: "nord", switchToImported: true)
        XCTAssertTrue(outcome.activate, "ticking 'Switch to it now' activates the imported theme")
    }
}
#endif
