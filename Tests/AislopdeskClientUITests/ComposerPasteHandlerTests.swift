// ComposerPasteHandlerTests (E12 / ES-E12-3) — the in-field `⌘V` / `⇧⌘V` paste pipeline, proven headlessly.
// The fix replaced the SwiftUI `TextField` with a hosted `ComposerTextView` whose `paste(_:)` override runs
// `ComposerPasteHandler` so `⌘V` actually converts (HTML/RTF→Markdown) and splices AT THE CARET, instead of
// the conversion being dead on macOS (the Edit ▸ Paste menu owns `⌘V` and preempts `.onKeyPress`). This pins
// that pipeline against `NSPasteboard.general` (no window, no responder, no VT/Metal — hang-safe).
//
// Revert-to-confirm-fail: change `ComposerPasteHandler.paste` to append (drop the `at: range`) and
// `testRichPasteConvertsAndLandsAtCaret` flips ("A**bold**C" → "AC**bold**"). Not a tautology — it asserts
// the converted bytes land between the existing characters, not at the end.

#if os(macOS)
import AislopdeskWorkspaceCore
import AppKit
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ComposerPasteHandlerTests: XCTestCase {
    /// `⌘V` converts the clipboard HTML to Markdown AND splices it at the caret (UTF-16 location 1, between
    /// "A" and "C"), with the model's caret advanced to just past the inserted Markdown.
    func testRichPasteConvertsAndLandsAtCaret() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>bold</b>", forType: .html)

        let composer = ComposerModel()
        composer.draft = "AC"

        let didPaste = ComposerPasteHandler.paste(rich: true, at: NSRange(location: 1, length: 0), into: composer)

        XCTAssertTrue(didPaste, "a non-empty pasteboard pastes")
        XCTAssertEqual(composer.draft, "A**bold**C", "⌘V converts HTML→Markdown and splices at the caret")
        XCTAssertEqual(
            composer.selection?.location,
            1 + "**bold**".utf16.count,
            "the caret advances to just past the inserted Markdown",
        )
    }

    /// `⇧⌘V` inserts the plain-text flavour VERBATIM (no HTML→Markdown conversion) at the caret.
    func testPlainPasteInsertsVerbatimAtCaret() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>x</b>", forType: .string)

        let composer = ComposerModel()
        composer.draft = "AC"

        _ = ComposerPasteHandler.paste(rich: false, at: NSRange(location: 1, length: 0), into: composer)

        XCTAssertEqual(composer.draft, "A<b>x</b>C", "⇧⌘V pastes plain text verbatim (no conversion) at the caret")
    }

    /// An empty pasteboard is a no-op that returns `false` (so the host can fall back to the system paste)
    /// and never touches the draft.
    func testEmptyPasteboardIsNoOpReturningFalse() {
        let pb = NSPasteboard.general
        pb.clearContents()

        let composer = ComposerModel()
        composer.draft = "keep"

        XCTAssertFalse(ComposerPasteHandler.paste(rich: true, at: nil, into: composer), "nothing to paste → false")
        XCTAssertEqual(composer.draft, "keep", "an empty paste leaves the draft untouched")
    }

    /// RICH-ONLY clipboard (HTML present, NO plain `.string` flavour — some apps copy rich-only): `⌘V` still
    /// reads the HTML and runs the HTML→Markdown conversion rather than falling through to an empty paste.
    func testRichOnlyPasteboardConvertsWhenNoPlainString() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>bold</b>", forType: .html)
        XCTAssertNil(pb.string(forType: .string), "precondition: the clipboard carries NO plain-string flavour")

        let composer = ComposerModel()
        composer.draft = ""

        XCTAssertTrue(ComposerPasteHandler.paste(rich: true, at: nil, into: composer), "rich-only paste runs")
        XCTAssertEqual(composer.draft, "**bold**", "⌘V converts the rich-only HTML even without a plain string")
    }

    /// The hosted field advertises the rich/image flavours in `readablePasteboardTypes` so AppKit ENABLES
    /// Edit ▸ Paste (and routes `⌘V` into `paste(_:)`) for a rich-only clipboard. Without the override a
    /// plain-text field (`isRichText == false`) would advertise only `.string`, leaving Paste disabled.
    func testReadablePasteboardTypesAdvertiseRichFlavours() {
        let (textView, _) = makeTextView(draft: "")
        XCTAssertTrue(textView.readablePasteboardTypes.contains(.html), "HTML is advertised as readable")
        XCTAssertTrue(textView.readablePasteboardTypes.contains(.rtf), "RTF is advertised as readable")
    }

    /// A converted `⌘V` paste is applied through the text view's edit path (`shouldChangeText`/`didChangeText`)
    /// so it registers with the undo manager and `⌘Z` undoes it as ONE edit. Revert-to-confirm-fail: apply the
    /// paste by setting `string` directly (bypassing `shouldChangeText`) and `canUndo` goes false.
    func testConvertedPasteIsUndoableAsOneEdit() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<b>bold</b>", forType: .html)

        let (textView, coordinator) = makeTextView(draft: "")
        XCTAssertTrue(textView.insertConvertedPaste(rich: true), "the paste runs")
        XCTAssertEqual(textView.string, "**bold**", "the converted Markdown lands in the field")
        XCTAssertTrue(coordinator.textUndoManager.canUndo, "the converted paste registered an undo step")

        coordinator.textUndoManager.undo()
        XCTAssertEqual(textView.string, "", "⌘Z undoes the converted paste as one edit")
    }

    /// PLACEHOLDER repaint decision: a placeholder change (e.g. `⌘⇧M` flipping queue-mode while the field is
    /// open and empty) needs a redraw ONLY while empty and only when it actually changed (kept cheap — no
    /// per-keystroke redraw).
    func testPlaceholderRedrawOnlyWhenChangedAndEmpty() {
        XCTAssertTrue(
            ComposerTextView.placeholderNeedsRedraw(old: "Message…", new: "Add to Prompt Queue…", isEmpty: true),
            "queue-mode flip while empty → repaint the new placeholder",
        )
        XCTAssertFalse(
            ComposerTextView.placeholderNeedsRedraw(old: "Message…", new: "Add to Prompt Queue…", isEmpty: false),
            "a non-empty field draws no placeholder → no repaint",
        )
        XCTAssertFalse(
            ComposerTextView.placeholderNeedsRedraw(old: "Message…", new: "Message…", isEmpty: true),
            "unchanged placeholder → no repaint",
        )
    }

    /// Builds a hosted ``ComposerTextView`` + its ``ComposerTextEditor/Coordinator`` (the undo-manager vendor)
    /// WITHOUT a window — the hang-safety rule forbids an `NSWindow`, not a bare `NSTextView`.
    private func makeTextView(draft: String) -> (ComposerTextView, ComposerTextEditor.Coordinator) {
        let composer = ComposerModel()
        composer.draft = draft
        let editor = ComposerTextEditor(
            text: draft,
            composer: composer,
            chrome: ComposerLeafChrome(),
            placeholder: "",
            minLines: 1,
            maxLines: 12,
            onSend: {},
            onEnqueue: {},
            onCancel: {},
        )
        let coordinator = editor.makeCoordinator()
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40), textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.string = draft
        coordinator.textView = textView
        return (textView, coordinator)
    }
}
#endif
