import AislopdeskClaudeCode
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E12 WI-3 — per-pane ``ComposerModel`` view-model, exercised headless through an injected
/// send-spy (the model owns no transport; every emitted byte funnels through ``ComposerModel/send``).
///
/// Covers the acceptance stories the model carries:
/// - ES-E12-1: `⌘⇧E` toggle visibility; `⌘↩` sends `draft + CR` once then clears + hides; a
///   bare-newline draft is preserved un-sent.
/// - ES-E12-2: `⎋` cancels keeping the draft; re-`open()` restores it.
/// - ES-E12-5: `⌥⌘↩` enqueues without sending (stays open, clears draft); each idle dispatches
///   exactly one queued item's bytes, FIFO; chips edit/remove/reorder through the model.
@MainActor
final class ComposerModelTests: XCTestCase {
    private let CR: UInt8 = 0x0D

    // MARK: Visibility — ⌘⇧E / open / ⎋

    func testToggleFlipsVisibility() {
        let model = ComposerModel()
        XCTAssertFalse(model.isVisible)
        XCTAssertTrue(model.toggle())
        XCTAssertTrue(model.isVisible)
        XCTAssertFalse(model.toggle())
        XCTAssertFalse(model.isVisible)
    }

    func testOpenShowsComposerIdempotently() {
        let model = ComposerModel()
        model.open()
        XCTAssertTrue(model.isVisible)
        model.open()
        XCTAssertTrue(model.isVisible)
    }

    // MARK: ES-E12-2 — ⎋ keeps the draft; re-open restores it

    func testCancelKeepsDraftAndReopenRestoresIt() {
        let model = ComposerModel()
        model.open()
        model.draft = "work in progress"
        model.cancel()
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.draft, "work in progress", "⎋ hides but keeps the draft")
        model.open()
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.draft, "work in progress", "re-open restores the same draft")
    }

    // MARK: ES-E12-1 — ⌘↩ sends draft + CR once, clears, hides

    func testSendDraftWritesDraftPlusCROnceThenClearsAndHides() {
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.open()
        model.draft = "build the release"
        model.sendDraft()
        XCTAssertEqual(sent.count, 1, "exactly one send")
        XCTAssertEqual(sent.first.map { Array($0) }, Array("build the release".utf8) + [CR])
        XCTAssertEqual(model.draft, "", "draft cleared after send")
        XCTAssertFalse(model.isVisible, "composer closes after ⌘↩")
    }

    func testSendDraftWrapsMultilineDraftInBracketedPasteThenCR() {
        // A real paste in this codebase IS bracketed: a multi-line draft must ride inside DEC
        // bracketed-paste markers (ESC[200~ … ESC[201~) so its embedded `\n` stays INERT and the
        // whole prompt lands as ONE block — not one command/turn per line. Direct send still does
        // NOT split per line (that's the queue's job); the single trailing CR (after the END
        // marker) submits. REVERT-TO-CONFIRM-FAIL: the un-fixed `Data(draft.utf8)+CR` path sends
        // the raw `line1\nline2` (which submits early line-by-line) and fails this.
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.draft = "line1\nline2"
        model.sendDraft()
        let expected = Array(PasteTransform.bracketed("line1\nline2").utf8) + [CR]
        XCTAssertEqual(sent.first.map { Array($0) }, expected)
    }

    func testSendDraftLeavesSingleLineDraftUnbracketed() {
        // The boundary: a single-line draft is byte-identical to a typed line — NO paste framing,
        // just `UTF-8(draft) + CR`. Guards against over-wrapping every send.
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.draft = "one liner"
        model.sendDraft()
        XCTAssertEqual(sent.first.map { Array($0) }, Array("one liner".utf8) + [CR])
    }

    func testSendDraftWithBareNewlineDraftIsPreservedUnsent() {
        // A whitespace/newline-only draft must not send (bare ↩ inserts a newline; only a
        // non-blank draft submits on ⌘↩). The draft and visibility are left untouched.
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.open()
        model.draft = "\n"
        model.sendDraft()
        XCTAssertTrue(sent.isEmpty, "a newline-only draft does not send")
        XCTAssertEqual(model.draft, "\n", "and the draft is preserved")
        XCTAssertTrue(model.isVisible, "composer stays open")
    }

    func testSendDraftWithNoSinkPreservesDraft() {
        let model = ComposerModel() // disconnected — no send sink wired
        model.open()
        model.draft = "hello"
        model.sendDraft()
        XCTAssertEqual(model.draft, "hello", "disconnected: keep the draft rather than drop it")
        XCTAssertTrue(model.isVisible)
    }

    // MARK: ES-E12-4 (WI-6) — sending / cancelling a FLOATING composer docks it back

    func testSendDraftDocksFloatBack() {
        // otty: "sending docks the float back into the pane." A real send clears isFloating so the
        // window-level / panel presentation closes. REVERT-TO-CONFIRM-FAIL: without the `isFloating = false`
        // line in `sendDraft`, this asserts true.
        let model = ComposerModel(send: { _ in })
        model.open()
        model.isFloating = true
        model.draft = "ship it"
        model.sendDraft()
        XCTAssertFalse(model.isFloating, "⌘↩ docks the floating composer back")
    }

    func testCancelDocksFloatBackKeepingDraftAndPin() {
        // ⎋ closes the float (docks back) but PRESERVES the draft, and pinning is independent (a pinned
        // composer stays pinned across a cancel).
        let model = ComposerModel()
        model.open()
        model.isFloating = true
        model.setPinned(true)
        model.draft = "in progress"
        model.cancel()
        XCTAssertFalse(model.isFloating, "⎋ docks the floating composer back")
        XCTAssertTrue(model.isPinned, "cancel does not unpin — pin is independent of float")
        XCTAssertEqual(model.draft, "in progress", "⎋ keeps the draft")
        XCTAssertFalse(model.isVisible)
    }

    func testBlankSendDoesNotDockFloatBack() {
        // A blank ⌘↩ is a no-op (nothing sent), so the float stays up — it never half-docked on an empty send.
        let model = ComposerModel(send: { _ in })
        model.open()
        model.isFloating = true
        model.draft = "   "
        model.sendDraft()
        XCTAssertTrue(model.isFloating, "a no-op (blank) send leaves the float up")
    }

    // MARK: ES-E12-5 — ⌥⌘↩ enqueues without sending; idle dispatches one item per call

    func testEnqueueDraftGrowsQueueWithoutSendingStaysOpenAndClearsDraft() {
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.open()
        model.draft = "first\nsecond"
        model.enqueueDraft()
        XCTAssertTrue(sent.isEmpty, "⌥⌘↩ enqueues but sends nothing now")
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["first", "second"], "split per line")
        XCTAssertEqual(model.draft, "", "draft cleared after enqueue")
        XCTAssertTrue(model.isVisible, "composer stays open for more queue input")
    }

    func testNotePromptIdleDispatchesHeadBytesOncePerCallInOrderThenNothingWhenEmpty() {
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.draft = "one\ntwo"
        model.enqueueDraft()

        model.notePromptIdle()
        XCTAssertEqual(sent.map { Array($0) }, [Array("one".utf8) + [CR]], "first idle → item 0")

        model.notePromptIdle()
        XCTAssertEqual(
            sent.map { Array($0) },
            [Array("one".utf8) + [CR], Array("two".utf8) + [CR]],
            "second idle → item 1, in FIFO order",
        )

        model.notePromptIdle() // queue now empty
        XCTAssertEqual(sent.count, 2, "a third idle with an empty queue sends nothing")
        XCTAssertTrue(model.promptQueue.isEmpty)
    }

    func testNotePromptIdleWithNoSinkKeepsQueueItems() {
        let model = ComposerModel() // disconnected
        model.draft = "queued"
        model.enqueueDraft()
        model.notePromptIdle()
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["queued"], "no sink: item is not lost")
    }

    // MARK: Chips — tap-edit / ✕-remove / drag-reorder route through the model

    func testEditChipLoadsTextIntoDraftOpensAndRemovesFromQueue() {
        let model = ComposerModel()
        model.draft = "a\nb"
        model.enqueueDraft()
        let first = model.promptQueue.items[0].id
        model.cancel() // hidden — editChip must re-open
        model.editChip(id: first)
        XCTAssertEqual(model.draft, "a", "tapped chip loads back into the composer")
        XCTAssertTrue(model.isVisible, "editing a chip opens the composer")
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["b"], "edited chip left the queue")
    }

    func testEditChipUnknownIdIsNoOp() {
        let model = ComposerModel()
        model.draft = "a"
        model.enqueueDraft()
        model.editChip(id: UUID())
        XCTAssertEqual(model.draft, "", "unknown id does not touch the draft")
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["a"], "queue unchanged")
    }

    func testRemoveChipDeletesById() {
        let model = ComposerModel()
        model.draft = "a\nb"
        model.enqueueDraft()
        let first = model.promptQueue.items[0].id
        model.removeChip(id: first)
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["b"])
    }

    func testMoveChipReorders() {
        let model = ComposerModel()
        model.draft = "a\nb\nc"
        model.enqueueDraft()
        model.moveChip(from: 0, to: 2)
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["b", "c", "a"])
    }

    // MARK: Paste — rich/plain append into the draft and open the composer

    func testPasteRichAppendsMarkdownAndOpens() {
        let model = ComposerModel()
        model.draft = "see: "
        model.pasteRich("# Heading")
        XCTAssertEqual(model.draft, "see: # Heading", "rich paste appends the converted Markdown")
        XCTAssertTrue(model.isVisible, "paste reveals the composer")
    }

    func testPastePlainAppendsVerbatimAndOpens() {
        let model = ComposerModel()
        model.pastePlain("literal <b>not bold</b>")
        XCTAssertEqual(model.draft, "literal <b>not bold</b>", "plain paste is verbatim, no conversion")
        XCTAssertTrue(model.isVisible)
    }

    func testPasteEmptyStringIsNoOp() {
        let model = ComposerModel()
        model.pastePlain("")
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.isVisible, "an empty paste neither edits nor opens")
    }

    // MARK: ES-E12-3 — paste splices AT THE CARET (not appended)

    func testPasteRichInsertsAtCaretMidDraft() {
        // The core ES-E12-3 fix: a paste lands at the caret, not the end. REVERT-TO-CONFIRM-FAIL: the old
        // `draft += text` append yields "abXcdZ" and fails this.
        let model = ComposerModel()
        model.draft = "abXcd"
        model.selection = NSRange(location: 2, length: 0) // caret between "ab" and "Xcd"
        model.pasteRich("Z")
        XCTAssertEqual(model.draft, "abZXcd", "rich paste splices at the caret, not appended")
        XCTAssertEqual(model.selection, NSRange(location: 3, length: 0), "caret advances past the insertion")
        XCTAssertTrue(model.isVisible)
    }

    func testPastePlainReplacesSelectedRange() {
        // A non-empty selection is REPLACED by the paste (the field's selected text is overwritten).
        let model = ComposerModel()
        model.draft = "hello world"
        model.selection = NSRange(location: 6, length: 5) // selects "world"
        model.pastePlain("there")
        XCTAssertEqual(model.draft, "hello there", "the selected run is replaced by the plain paste")
        XCTAssertEqual(model.selection, NSRange(location: 11, length: 0))
    }

    func testInsertWithNilSelectionAppendsAtEnd() {
        // No live caret (never-focused composer) → append at the end, the sensible default.
        let model = ComposerModel()
        model.draft = "see: "
        model.insert("# Heading")
        XCTAssertEqual(model.draft, "see: # Heading", "a nil selection appends at the end")
    }

    func testInsertClampsStaleOutOfBoundsSelection() {
        // Validate-then-degrade: a stale selection past the end of a now-shorter draft is clamped, never traps.
        let model = ComposerModel()
        model.draft = "abc"
        model.selection = NSRange(location: 99, length: 40) // wildly out of range
        model.insert("Z")
        XCTAssertEqual(model.draft, "abcZ", "an out-of-bounds selection clamps to the end")
    }

    // MARK: ES-E12-4 (WI-6) — pin verbs notify onPinnedChange for per-pane persistence

    func testTogglePinNotifiesOnPinnedChangeOnlyOnRealChange() {
        let model = ComposerModel()
        var changes: [Bool] = []
        model.onPinnedChange = { changes.append($0) }
        model.togglePin()
        XCTAssertTrue(model.isPinned)
        model.setPinned(true) // no-op — already pinned
        model.togglePin()
        XCTAssertFalse(model.isPinned)
        XCTAssertEqual(changes, [true, false], "onPinnedChange fires once per REAL flip, not on a no-op set")
    }

    // MARK: ES-E12-5 (WI-1) — kickstart: enqueue into an idle pane dispatches immediately

    func testEnqueueIntoIdlePaneKickstartsHeadImmediately() {
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.isIdleNow = { true } // pane is idle now
        model.draft = "go\nnext"
        model.enqueueDraft()
        XCTAssertEqual(sent.map { Array($0) }, [Array("go".utf8) + [CR]], "idle pane: the head item kickstarts now")
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["next"], "only the head kickstarts; the rest wait")
    }

    func testEnqueueIntoBusyPaneWaitsForTheTurnEdge() {
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.isIdleNow = { false } // pane is busy
        model.draft = "go"
        model.enqueueDraft()
        XCTAssertTrue(sent.isEmpty, "busy pane: nothing kickstarts")
        model.notePromptIdle() // the turn finishes
        XCTAssertEqual(sent.map { Array($0) }, [Array("go".utf8) + [CR]], "the turn-finished edge dispatches it")
    }

    func testKickstartDoesNotDoubleDispatchWhileInFlight() {
        // After a kickstart sends the head, a SECOND enqueue while the status still reads idle (status lags
        // the actual turn start) must NOT send a second prompt — the in-flight latch guards it. Only the
        // turn-finished edge releases the next.
        var sent: [Data] = []
        let model = ComposerModel(send: { sent.append($0) })
        model.isIdleNow = { true }
        model.draft = "one"
        model.enqueueDraft() // kickstarts "one", latches in-flight
        XCTAssertEqual(sent.count, 1)
        model.draft = "two"
        model.enqueueDraft() // still reads idle, but a prompt is in flight → no double-send
        XCTAssertEqual(sent.count, 1, "the in-flight latch blocks a second kickstart")
        XCTAssertEqual(model.promptQueue.items.map(\.text), ["two"], "the second item waits for the edge")
        model.notePromptIdle()
        XCTAssertEqual(sent.map { Array($0) }, [Array("one".utf8) + [CR], Array("two".utf8) + [CR]])
    }
}
