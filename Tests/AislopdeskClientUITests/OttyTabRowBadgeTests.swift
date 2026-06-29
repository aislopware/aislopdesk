// OttyTabRowBadgeTests — pins the sidebar tab row's trailing SWITCH-SHORTCUT badge (Batch-5 fidelity). otty's
// ground-truth sidebar (`find.png`, `workspace-tabs.png`) renders each tab row's trailing chip as the `⌘N`
// select-tab shortcut (`otty ⌘1` / `OC | Reviewing todos ⌘2` / …), NOT a `#N` hash-index. ``OttyTabRow``'s
// pure ``OttyTabRow/shortcutBadge(for:)`` formats that chip, gated to the nine tabs that actually have a ⌘N
// chord (⌘1…⌘9); overflow tabs (10+) have no shortcut, so they get no badge rather than a misleading number.
//
// Revert-to-confirm-fail: the pre-Batch-5 row rendered `"#\(number)"` for every `number > 0`. Each assertion
// below pins the exact `⌘N` string and the 1…9 gate, so reverting the formatter to `#N` (or dropping the
// overflow gate) fails these — none is tautological.

#if canImport(SwiftUI)
import XCTest
@testable import AislopdeskClientUI

final class OttyTabRowBadgeTests: XCTestCase {
    /// Tabs 1…9 render the `⌘N` switch-shortcut badge (otty `find.png` / `workspace-tabs.png`).
    func testShortcutBadgeIsCommandNumberForFirstNineTabs() {
        XCTAssertEqual(OttyTabRow.shortcutBadge(for: 1), "⌘1")
        XCTAssertEqual(OttyTabRow.shortcutBadge(for: 2), "⌘2")
        XCTAssertEqual(OttyTabRow.shortcutBadge(for: 9), "⌘9")
    }

    /// The badge is the `⌘N` switch-shortcut, never the old `#N` hash-index (the explicit divergence anchor).
    func testShortcutBadgeIsNotHashIndex() {
        XCTAssertNotEqual(OttyTabRow.shortcutBadge(for: 2), "#2")
    }

    /// Overflow tabs (10+) have NO ⌘-shortcut, so they render no badge (not a misleading `⌘10`).
    func testNoShortcutBadgeForOverflowTabs() {
        XCTAssertNil(OttyTabRow.shortcutBadge(for: 10))
        XCTAssertNil(OttyTabRow.shortcutBadge(for: 99))
    }

    /// A zero / unset tab number renders no badge (the default keeps non-tab call sites clean).
    func testNoShortcutBadgeForZero() {
        XCTAssertNil(OttyTabRow.shortcutBadge(for: 0))
    }
}
#endif
