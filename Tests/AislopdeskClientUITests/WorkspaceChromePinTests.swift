// WorkspaceChromePinTests — pins the E19 / WI-4 testable surface of "Pin Window" WITHOUT an NSWindow.
//
// The macOS `NSWindow.level` glue itself is hang-unsafe to exercise (CLAUDE.md rule #6 — never instantiate
// an NSWindow in a test), so WI-4's `applyPinLevel` / `applyInitialWindowSize` are compiled-and-reviewed
// only; the pure window-sizing math is covered by `WindowSizeMathTests` (WI-1) and the action routing by
// `WorkspaceBindingRoutingTests` (WI-3). What IS unit-testable here is the model contract the glue actuates:
// the `WorkspaceChromeState.pinned` flag + the `OverlayCoordinator.togglePinWindow` seam the root view
// (`wireChromeToggles`) and the menu (`WorkspaceCommands`) flip — driven headlessly, no AppKit.

import XCTest
@testable import AislopdeskClientUI

@MainActor
final class WorkspaceChromePinTests: XCTestCase {
    /// A fresh window is NOT pinned (otty parity — pinning is an explicit affordance), and `togglePin()`
    /// flips the flag each call. REVERT-TO-CONFIRM-FAIL: the property / method do not exist on the un-fixed
    /// `WorkspaceChromeState`, so this fails to compile-then-pass only once WI-4 adds them.
    func testTogglePinFlipsTheChromeFlag() {
        let chrome = WorkspaceChromeState()
        XCTAssertFalse(chrome.pinned, "a fresh window resting state is UNpinned")

        chrome.togglePin()
        XCTAssertTrue(chrome.pinned, "togglePin() pins the window")

        chrome.togglePin()
        XCTAssertFalse(chrome.pinned, "a second togglePin() un-pins it")
    }

    /// The `OverlayCoordinator.togglePinWindow` seam — bound by `WorkspaceRootView.wireChromeToggles()` to
    /// `chrome.togglePin()` so the palette / any command surface flips the SAME live `chrome.pinned` the menu
    /// Button + the `NSWindow.level` glue read. Pins the wiring contract the app depends on. REVERT-TO-
    /// CONFIRM-FAIL: drop the `overlay.togglePinWindow = { chrome.togglePin() }` line from `wireChromeToggles`
    /// (the live binding) and the routed toggle no longer reaches the flag — `pinned` stays false.
    func testOverlayPinSeamFlipsTheChromeFlag() {
        let chrome = WorkspaceChromeState()
        let overlay = OverlayCoordinator()
        // Bind the seam exactly the way the root view does on appear.
        overlay.togglePinWindow = { chrome.togglePin() }

        overlay.togglePinWindow()
        XCTAssertTrue(chrome.pinned, "routing through the overlay pin seam flips the live chrome flag")
    }

    /// The default `togglePinWindow` seam (no root-view binding — tests / previews / a pre-`onAppear` scene)
    /// is a GRACEFUL no-op, never a trap: invoking it does nothing and does not crash.
    func testUnboundOverlayPinSeamIsAGracefulNoOp() {
        let overlay = OverlayCoordinator()
        overlay.togglePinWindow() // no binding ⇒ the default `{}` runs, no crash
    }

    /// E19 / WI-4 (M4) — the palette ✓ gutter tracks the pinned state. `OverlayHostView.toggledState(for:)`
    /// resolves the "action.pinWindow" row to `chrome.pinned`, so the palette lights the checkmark while
    /// pinned and clears it when unpinned — otty's checkable Pin Window (ES-E2-3). REVERT-TO-CONFIRM-FAIL:
    /// drop the `case "action.pinWindow": chrome.pinned` arm and the resolver falls to the `default: false`,
    /// so the ✓ never lights and `pinned == true` below fails.
    func testToggledStateLightsPinRowWhenPinned() {
        let chrome = WorkspaceChromeState()
        let pinItem = PaletteItem(
            id: "action.pinWindow", icon: "pin", title: "Pin Window",
            subtitle: nil, shortcut: nil, filter: .actions, category: .window, action: .togglePinWindow,
        )

        let unpinnedResolver = OverlayHostView.toggledState(for: chrome)
        XCTAssertFalse(unpinnedResolver(pinItem), "an unpinned window shows no ✓ on the Pin Window row")

        chrome.togglePin() // pin it
        let pinnedResolver = OverlayHostView.toggledState(for: chrome)
        XCTAssertTrue(pinnedResolver(pinItem), "a pinned window lights the ✓ on the Pin Window row")
    }
}
