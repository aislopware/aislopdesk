// SettingsSectionHeaderTests (Batch-5 UI fidelity) — pins the otty Settings section-header CASING.
//
// otty renders in-page Settings SECTION labels UPPERCASE (`mouse-option.png` "MOUSE" / "SECURE INPUT",
// `notification-setting.png` "NOTIFICATION" / "TAB BADGE", `all-settings.png` "ALL SETTINGS"). The clone
// previously rendered them in macOS's native Title-Case via `Section("Title")`. `ottyFormSection` now routes
// the label through `OttySettingsSectionHeader.label`, which UPPERCASES it. This pins that transform so a
// refactor can't silently regress the header back to the raw Title-Case title.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class SettingsSectionHeaderTests: XCTestCase {
    /// Mixed-case section titles from the live Settings pages map to all-UPPERCASE headers. The expectations
    /// are an INDEPENDENT hand-written table (not `input.uppercased()`), matching the otty screenshots.
    func testSectionHeaderLabelIsUppercased() {
        XCTAssertEqual(OttySettingsSectionHeader.label("Copy & Paste"), "COPY & PASTE")
        XCTAssertEqual(OttySettingsSectionHeader.label("Secure Input"), "SECURE INPUT")
        XCTAssertEqual(OttySettingsSectionHeader.label("Tab Badge"), "TAB BADGE")
        // Through a real Settings-page section constant, proving live titles are re-cased.
        XCTAssertEqual(OttySettingsSectionHeader.label(GeneralSettingsLayout.closeConfirmation), "CLOSE CONFIRMATION")
    }

    /// The revert-to-confirm-fail guard: the header must NOT pass the raw Title-Case title through (which is
    /// exactly what the native `Section("…")` initializer rendered on macOS grouped Forms). Dropping the
    /// `.uppercased()` re-casing fails here.
    func testSectionHeaderIsNotRawTitleCaseTitle() {
        for title in ["Selection", "Mouse", "Notification", "Window"] {
            XCTAssertNotEqual(
                OttySettingsSectionHeader.label(title), title,
                "otty renders section headers UPPERCASE, not the raw Title-Case title",
            )
        }
    }
}
#endif
