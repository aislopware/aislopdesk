// SidebarAutoHideWiringTests — pins the E19 / WI-7 view-side ACTUATION of the `auto-hide-tabs-panel` policy
// WITHOUT a live view or an NSWindow.
//
// The pure decision (`SidebarAutoHidePolicy.desiredCollapsed`) is pinned headlessly in
// `SidebarAutoHidePolicyTests` (WI-2). What this suite pins is the thin view-side glue WI-7 adds in
// `WorkspaceRootView`: the static `applyAutoHide(mode:tabCount:chrome:)` that the `.onChange(of:)` observers
// call, and the iOS `sidebarVisibility(sidebarCollapsed:)` column mapping that makes the shared
// `chrome.sidebarCollapsed` flag honored on iPad (not a dead toggle). Both are pure + cross-platform so the
// contract is unit-tested in the macOS `swift test` Gate, never instantiating a view / split / NSWindow.

import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class SidebarAutoHideWiringTests: XCTestCase {
    // MARK: - applyAutoHide: the `.auto` mode actuates `chrome.sidebarCollapsed` on the policy's opinion

    /// `.auto` COLLAPSES the sidebar when the active session drops to ≤1 tab. Start REVEALED, apply the policy
    /// at one tab, and the live chrome flag flips to collapsed — the actuation the `.onChange(of:)` observer
    /// performs on a tab-close transition. REVERT-TO-CONFIRM-FAIL: `applyAutoHide` does not exist on the
    /// un-fixed `WorkspaceRootView`, so this fails to compile-then-pass only once WI-7 adds it.
    func testAutoModeCollapsesWhenDownToOneTab() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // resting: sidebar revealed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto at 1 tab collapses the TABS panel")
    }

    /// `.auto` REVEALS the sidebar when the active session grows past one tab. Start COLLAPSED, apply at two
    /// tabs, and the flag flips back to revealed — the actuation on a tab-open transition. Asserts against the
    /// independent truth (`>1 tab ⇒ revealed`), not the function's own derivation.
    func testAutoModeRevealsWhenMoreThanOneTab() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // resting: sidebar collapsed

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".auto at 2 tabs reveals the TABS panel")
    }

    /// An empty active session (0 tabs) collapses under `.auto` — there is nothing to switch between (parity
    /// with `SidebarAutoHidePolicy`'s `tabCount <= 1`).
    func testAutoModeCollapsesAtZeroTabs() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 0, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto at 0 tabs collapses (nothing to switch between)")
    }

    /// THE launch-path pin (M2): a fresh window rests with `sidebarCollapsed == false` (revealed), so a launch
    /// with a persisted `.auto` mode + a single-tab session must collapse the TABS panel AT LAUNCH — not wait
    /// for a tab add/remove. This pins what the `.onChange(of: activeTabCount, initial: true)` observer drives on
    /// first render: starting from the DEFAULT chrome state, applying the policy at one tab collapses it.
    /// REVERT-TO-CONFIRM-FAIL: without `initial: true` the observer never fires on first appearance, so the
    /// launch state stays revealed — this test models the desired-collapsed the initial path must compute.
    func testAutoModeAtLaunchCollapsesSingleTabFromDefaultState() {
        let chrome = WorkspaceChromeState() // a fresh window: sidebarCollapsed defaults to false (revealed)
        XCTAssertFalse(chrome.sidebarCollapsed, "precondition: a fresh window rests revealed")

        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".auto + a single-tab session collapses the TABS panel at launch")
    }

    // MARK: - applyAutoHide: `.default` / `.always` NEVER fight a manual collapse (no opinion)

    /// THE "never fight a manual ⌘⇧L" pin: in `.default` the policy has NO opinion, so a manual collapse the
    /// user set with ⌘⇧L SURVIVES regardless of the tab count. Start MANUALLY collapsed with several tabs (a
    /// count `.auto` would WANT to reveal) and assert `applyAutoHide` leaves it collapsed. REVERT-TO-CONFIRM-
    /// FAIL: an implementation that ignored the `nil` opinion and forced `tabCount <= 1` would REVEAL here
    /// (set `false`), failing the assertion — exactly the manual-toggle-fighting regression this guards.
    func testDefaultModeLeavesManualCollapseAlone() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = true // the user manually collapsed it (⌘⇧L)

        WorkspaceRootView.applyAutoHide(mode: .default, tabCount: 5, chrome: chrome)
        XCTAssertTrue(chrome.sidebarCollapsed, ".default has no opinion — a manual collapse is never fought")
    }

    /// The mirror of the above: in `.default` a manually REVEALED sidebar at one tab also stands (a count
    /// `.auto` would WANT to collapse). The no-opinion mode never touches the flag in either direction.
    func testDefaultModeLeavesManualRevealAlone() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false // manually revealed

        WorkspaceRootView.applyAutoHide(mode: .default, tabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".default never collapses a manually-revealed sidebar")
    }

    /// `.always` is also a no-opinion mode in the vertical-tabs-only clone (both non-`auto` modes mean "never
    /// auto-hide"). A revealed sidebar at one tab stays revealed; a fighting implementation would collapse it.
    func testAlwaysModeHasNoOpinion() {
        let chrome = WorkspaceChromeState()
        chrome.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .always, tabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.sidebarCollapsed, ".always never auto-hides (no opinion)")
    }

    // MARK: - applyAutoHide: already-satisfied states are left as-is (the guard)

    /// When the live flag ALREADY matches the policy's opinion, `applyAutoHide` is a no-op — the guard against
    /// re-applying the same value (so the wiring reacts to a transition, never re-asserts a steady state). Both
    /// directions: `.auto` at 2 tabs already-revealed stays revealed; `.auto` at 1 tab already-collapsed stays
    /// collapsed.
    func testAlreadySatisfiedStateIsLeftAsIs() {
        let revealed = WorkspaceChromeState()
        revealed.sidebarCollapsed = false
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 2, chrome: revealed)
        XCTAssertFalse(revealed.sidebarCollapsed, "already-revealed at >1 tab stays revealed")

        let collapsed = WorkspaceChromeState()
        collapsed.sidebarCollapsed = true
        WorkspaceRootView.applyAutoHide(mode: .auto, tabCount: 1, chrome: collapsed)
        XCTAssertTrue(collapsed.sidebarCollapsed, "already-collapsed at ≤1 tab stays collapsed")
    }

    // MARK: - sidebarVisibility: the iOS column mapping makes the shared flag honored on iPad

    /// The pure map the iOS `sidebarColumnVisibility` binding uses: a collapsed sidebar hides the leading TABS
    /// column (`.doubleColumn` = content + detail), a revealed sidebar shows `.all`. Pins that the WI-7 policy
    /// (which sets `chrome.sidebarCollapsed`) actually hides/reveals the panel on iPad — the shared flag is not
    /// a dead toggle there. Cross-platform (`NavigationSplitViewVisibility` exists on macOS) so it runs in the
    /// macOS Gate.
    func testSidebarVisibilityMapping() {
        XCTAssertEqual(
            WorkspaceRootView.sidebarVisibility(sidebarCollapsed: true), .doubleColumn,
            "a collapsed sidebar hides the leading TABS column on iPad (content + detail remain)",
        )
        XCTAssertEqual(
            WorkspaceRootView.sidebarVisibility(sidebarCollapsed: false), .all,
            "a revealed sidebar shows all columns on iPad",
        )
    }
}
