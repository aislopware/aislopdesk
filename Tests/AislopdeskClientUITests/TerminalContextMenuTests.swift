import Foundation
import XCTest
@testable import AislopdeskClientUI

/// The pure terminal right-click menu model (docs/42 W14 #10): item ordering, separators, and — the
/// load-bearing piece — per-item enablement for the pane state (copy needs a selection; paste needs
/// clipboard text; select-all / clear / splits / find are always live). No view.
final class TerminalContextMenuTests: XCTestCase {
    func testCopyRequiresSelection() {
        let withSel = TerminalContextMenu.Context(hasSelection: true, clipboardHasText: false)
        let noSel = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.copy, context: withSel))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.copy, context: noSel))
    }

    func testPasteRequiresClipboardText() {
        let hasClip = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: true)
        let noClip = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.paste, context: hasClip))
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteAsKeystrokes, context: hasClip))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.paste, context: noClip))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteAsKeystrokes, context: noClip))
    }

    func testAlwaysEnabledItems() {
        let empty = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        for item in [TerminalContextMenu.Item.selectAll, .clear, .splitRight, .splitDown, .find] {
            XCTAssertTrue(TerminalContextMenu.isEnabled(item, context: empty), "\(item) should be always-enabled")
        }
    }

    func testItemOrderAndCoverage() {
        XCTAssertEqual(
            TerminalContextMenu.items,
            [.copy, .paste, .pasteAsKeystrokes, .selectAll, .clear, .copyOutput, .splitRight, .splitDown, .find],
        )
    }

    func testSeparatorsGroupClipboardEditBlocksSplitFind() {
        // A separator above Select All, Copy Command Output (WB2 blocks group), Split Right, and Find —
        // four group boundaries (clipboard | edit | blocks | split | find).
        let withSeparator = TerminalContextMenu.items.filter(\.separatorBefore)
        XCTAssertEqual(withSeparator, [.selectAll, .copyOutput, .splitRight, .find])
    }

    func testCopyOutputRequiresCommandOutput() {
        let withOutput = TerminalContextMenu.Context(
            hasSelection: false, clipboardHasText: false, hasCommandOutput: true,
        )
        let noOutput = TerminalContextMenu.Context(
            hasSelection: false, clipboardHasText: false, hasCommandOutput: false,
        )
        XCTAssertTrue(TerminalContextMenu.isEnabled(.copyOutput, context: withOutput))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.copyOutput, context: noOutput))
    }

    func testEveryItemHasTitleAndSymbol() {
        for item in TerminalContextMenu.Item.allCases {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.symbol.isEmpty)
        }
    }
}
