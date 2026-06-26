// TabBadgePresentationTests — pins E6 WI-4's pure view-side badge map. `StatusPresentation.tabBadge` resolves
// each `TabBadgeKind` to the correct otty glyph (spinner / accent dot / tinted SF-symbol), and `tabBadgeLabel`
// gives every kind a distinct non-empty AX/tooltip string. Headless VALUE assertions — no SwiftUI render, no
// video/Metal/SCStream. Each test fails on the pre-WI-4 code (the two helpers did not exist), so none is
// tautological. (Tints are deliberately NOT asserted here — `Color` equality is provider-fragile; the symbol
// NAME + glyph SHAPE are the load-bearing spec, locked by name, with the visual tint left to the snapshot.)

import AislopdeskWorkspaceCore
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class TabBadgePresentationTests: XCTestCase {
    /// The SF-symbol name a kind maps to, or `nil` when it renders a bespoke shape (spinner / accent dot).
    private func symbolName(of kind: TabBadgeKind) -> String? {
        if case let .symbol(name, _) = StatusPresentation.tabBadge(kind) { return name }
        return nil
    }

    private func isSpinner(_ kind: TabBadgeKind) -> Bool {
        if case .spinner = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    private func isAccentDot(_ kind: TabBadgeKind) -> Bool {
        if case .dot = StatusPresentation.tabBadge(kind) { return true }
        return false
    }

    /// `.running` ⇒ the indeterminate spinner shape (a busy shell / working agent), not an SF-symbol.
    func testRunningIsSpinner() {
        XCTAssertTrue(isSpinner(.running))
        XCTAssertNil(symbolName(of: .running), "the spinner is a bespoke shape, not an SF-symbol")
    }

    /// `.finished` ⇒ the small filled accent dot (the settled "unread output" marker), not a symbol.
    func testFinishedIsAccentDot() {
        XCTAssertTrue(isAccentDot(.finished))
        XCTAssertNil(symbolName(of: .finished))
    }

    /// `.completed` ⇒ the green filled checkmark circle (`OpenCode` row in `tab-badge.png`).
    func testCompletedIsCheckmarkSymbol() {
        XCTAssertEqual(symbolName(of: .completed), "checkmark.circle.fill")
    }

    /// `.error` ⇒ the alert triangle (`running build task` row in `tab-badge.png`).
    func testErrorIsAlertTriangleSymbol() {
        XCTAssertEqual(symbolName(of: .error), "exclamationmark.triangle.fill")
    }

    /// `.awaitingInput` ⇒ the raised hand (`plan next move` row in `tab-badge.png`).
    func testAwaitingInputIsHandSymbol() {
        XCTAssertEqual(symbolName(of: .awaitingInput), "hand.raised.fill")
    }

    /// `.caffeinate` ⇒ the coffee cup (a sleep-blocking session at rest).
    func testCaffeinateIsCoffeeSymbol() {
        XCTAssertEqual(symbolName(of: .caffeinate), "cup.and.saucer.fill")
    }

    /// `.sudo` ⇒ the shield (a privileged session at rest).
    func testSudoIsShieldSymbol() {
        XCTAssertEqual(symbolName(of: .sudo), "shield.lefthalf.filled")
    }

    /// Every kind carries a non-empty, distinct AX/tooltip label so the icon-only badge is legible/testable.
    func testEveryKindHasADistinctNonEmptyLabel() {
        let kinds: [TabBadgeKind] = [
            .running, .completed, .finished, .error, .awaitingInput, .caffeinate, .sudo,
        ]
        let labels = kinds.map { StatusPresentation.tabBadgeLabel($0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no blank badge labels")
        XCTAssertEqual(Set(labels).count, kinds.count, "labels are distinct per kind")
    }
}
