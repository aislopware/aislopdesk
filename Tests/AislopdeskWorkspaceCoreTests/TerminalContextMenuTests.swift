import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

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

    /// Cut (⌘X) — like Copy — needs a selection: it always copies the run and (only at an editable prompt)
    /// deletes it, so it greys out with nothing selected.
    func testCutRequiresSelection() {
        let withSel = TerminalContextMenu.Context(hasSelection: true, clipboardHasText: false)
        let noSel = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.cut, context: withSel))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.cut, context: noSel))
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
            [
                .copy, .cut, .paste, .pasteAsKeystrokes, .selectAll, .clear, .copyOutput,
                // E13 WI-5: "Send to Chat" sits in the blocks/agent group (after Copy Command Output).
                .sendToChat, .splitRight, .splitDown, .find,
            ],
        )
    }

    /// E13 WI-5 (ES-E13-5): "Send to Chat" is live ONLY when the dialog hook is wired (`canSendToChat`) AND
    /// there is something to quote (a selection OR a completed command block) — otherwise it greys out
    /// honestly (mirroring `pasteToComposer`'s `hasComposer` gate). Never a dead row.
    func testSendToChatRequiresWiringAndAQuote() {
        // Hook unwired (headless / preview) ⇒ always disabled, even with a selection.
        let unwired = TerminalContextMenu.Context(hasSelection: true, clipboardHasText: false, canSendToChat: false)
        XCTAssertFalse(TerminalContextMenu.isEnabled(.sendToChat, context: unwired))

        // Wired but nothing to quote ⇒ disabled.
        let nothing = TerminalContextMenu.Context(
            hasSelection: false, clipboardHasText: false, hasCommandOutput: false, canSendToChat: true,
        )
        XCTAssertFalse(TerminalContextMenu.isEnabled(.sendToChat, context: nothing))

        // Wired + a selection ⇒ enabled; wired + a command block ⇒ enabled.
        let withSel = TerminalContextMenu.Context(hasSelection: true, clipboardHasText: false, canSendToChat: true)
        let withOut = TerminalContextMenu.Context(
            hasSelection: false, clipboardHasText: false, hasCommandOutput: true, canSendToChat: true,
        )
        XCTAssertTrue(TerminalContextMenu.isEnabled(.sendToChat, context: withSel))
        XCTAssertTrue(TerminalContextMenu.isEnabled(.sendToChat, context: withOut))
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

    // MARK: Paste as… (E8 / ES-E8-4)

    func testPasteAsItemsAreNotInTopLevelMenu() {
        // The "Paste as…" variants hang off the submenu, never the flat top-level list (so adding them as
        // Item cases must not leak into `items`).
        for item in TerminalContextMenu.pasteAsItems {
            XCTAssertFalse(TerminalContextMenu.items.contains(item), "\(item) must not be top-level")
        }
    }

    func testPasteAsSubmenuOrderMatchesSlate() {
        XCTAssertEqual(
            TerminalContextMenu.pasteAsItems,
            [.pasteSelection, .pasteFileBase64, .pasteEscaped, .pasteBracketed, .pasteToComposer],
        )
    }

    func testPasteSelectionRequiresSelection() {
        let withSel = TerminalContextMenu.Context(hasSelection: true, clipboardHasText: false)
        let noSel = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteSelection, context: withSel))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteSelection, context: noSel))
    }

    func testPasteFileBase64IsAlwaysEnabled() {
        // It picks its own file via NSOpenPanel, so it never depends on selection / clipboard / composer.
        let empty = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteFileBase64, context: empty))
    }

    func testPasteEscapedAndBracketedRequireClipboardText() {
        let hasClip = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: true)
        let noClip = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteEscaped, context: hasClip))
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteBracketed, context: hasClip))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteEscaped, context: noClip))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteBracketed, context: noClip))
    }

    func testPasteToComposerRequiresClipboardTextAndComposer() {
        let both = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: true, hasComposer: true)
        let clipOnly = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: true, hasComposer: false)
        let composerOnly = TerminalContextMenu.Context(hasSelection: false, clipboardHasText: false, hasComposer: true)
        XCTAssertTrue(TerminalContextMenu.isEnabled(.pasteToComposer, context: both))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteToComposer, context: clipOnly))
        XCTAssertFalse(TerminalContextMenu.isEnabled(.pasteToComposer, context: composerOnly))
    }
}
