import XCTest
@testable import AislopdeskWorkspaceCore

/// WB3 — the BEHAVIORAL dispatch of the re-run-last / jump-to-failed actions through the production
/// ``WorkspaceBindingRegistry/route(_:to:)`` seam, observed on a ``RecordingTerminalPaneSession`` that
/// carries a REAL ``TerminalViewModel``. Unlike `TreeCommandRoutingTests`'
/// `testWB3BlockActionsRouteToStoreWithoutMutatingTree` (which drives a ``FakePaneSession`` whose
/// non-terminal model makes every block op a no-op, so it can only assert tree-immutability and is blind to
/// which store hook fires), these tests assert the ACTUAL effect:
///  - re-run sends the latest command's bytes through the input path,
///  - the spec-critical `.jumpPreviousFailed → forward:false` / `.jumpNextFailed → forward:true`
///    INVERSION lands the viewport on the NEWER vs OLDER failure (a swapped mapping would fail here).
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no GhosttySurface /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class WB3BlockRoutingDispatchTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store backed by the recording (terminal-model-carrying) session seam.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The active pane's recording session.
    private func activeSession(_ store: WorkspaceStore) throws -> RecordingTerminalPaneSession {
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        return try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
    }

    /// Seeds `blocks` into the active pane's model and returns its session.
    @discardableResult
    private func seedBlocks(_ store: WorkspaceStore, _ blocks: [CommandBlock]) throws -> RecordingTerminalPaneSession {
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)
        for b in blocks {
            model.blocks.upsert(
                index: b.index, commandText: b.commandText, exitCode: b.exitCode,
                durationMS: b.durationMS, complete: b.complete, outputLen: b.outputLen,
            )
        }
        return session
    }

    private func failed(_ index: UInt32) -> CommandBlock {
        CommandBlock(index: index, commandText: "cmd\(index)", exitCode: 1, complete: true)
    }

    private func ok(_ index: UInt32) -> CommandBlock {
        CommandBlock(index: index, commandText: "cmd\(index)", exitCode: 0, complete: true)
    }

    // MARK: - Re-run last command

    /// `.reRunLastCommand` re-injects the LATEST block's command text (verbatim + 1 newline) through the
    /// pane's input path. Pins it uses `latest` (the last block), not the first.
    func testReRunLastCommandSendsLatestCommandBytes() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [
            CommandBlock(index: 0, commandText: "first", complete: true),
            CommandBlock(index: 1, commandText: "latest", complete: true),
        ])

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertEqual(session.sentInput.count, 1, "re-run sent exactly one input payload")
        XCTAssertEqual(
            session.sentInput.first, Data("latest\n".utf8),
            "re-run injects the LATEST command's bytes (not the first), verbatim + one newline",
        )
    }

    /// `.reRunLastCommand` with an empty latest command is a true no-op at the store layer (the encoder
    /// returns nil) — nothing is sent.
    func testReRunEmptyLatestIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [CommandBlock(index: 0, commandText: "   ", complete: true)])

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertTrue(session.sentInput.isEmpty, "an empty/whitespace latest command sends nothing")
    }

    /// `.reRunLastCommand` with NO blocks at all is a no-op (no latest).
    func testReRunWithNoBlocksIsANoOp() throws {
        let store = makeStore()
        let session = try activeSession(store)

        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)

        XCTAssertTrue(session.sentInput.isEmpty, "no blocks ⇒ no re-run")
    }

    // MARK: - Re-run an EXPLICIT command (E11 Open-Quickly Command-row "Re-Run in Current Pane")

    /// `reRunCommandInActivePane(_:)` re-injects an EXPLICIT command text (the picked Current Command row,
    /// not the latest block) verbatim + one newline through the pane's input path — the Open-Quickly
    /// Command-row "Re-Run in Current Pane" action. Pins it sends the PASSED text (`"git status"`), independent of the
    /// block list, and that a literal `"<Enter>"` substring is NOT parsed into a control byte (the verbatim
    /// `BlockReRunEncoder` invariant). FAILS if the action were wired to `reRunLastCommandInActivePane`
    /// (which would send the latest block "tail", not the picked row) or to a SendKeysParser path.
    func testReRunCommandInActivePaneSendsVerbatimBytes() throws {
        let store = makeStore()
        // Seed an UNRELATED latest block so a wrong wiring to `reRunLastCommand` would send "tail\n" instead.
        let session = try seedBlocks(store, [CommandBlock(index: 0, commandText: "tail", complete: true)])

        store.reRunCommandInActivePane("echo \"<Enter>\"")

        XCTAssertEqual(session.sentInput.count, 1, "exactly one input payload sent")
        XCTAssertEqual(
            session.sentInput.first, Data("echo \"<Enter>\"\n".utf8),
            "the PASSED command is re-injected verbatim + one newline (the literal <Enter> stays literal)",
        )
    }

    /// `reRunCommandInActivePane("")` (and a whitespace-only text) is a no-op — the encoder returns nil, so
    /// no bare newline is sent.
    func testReRunCommandInActivePaneEmptyTextIsANoOp() throws {
        let store = makeStore()
        let session = try activeSession(store)

        store.reRunCommandInActivePane("   ")

        XCTAssertTrue(session.sentInput.isEmpty, "an empty/whitespace command sends nothing")
    }

    // MARK: - Jump-to-failed direction inversion (the spec-critical mapping)

    /// THE direction guard. Blocks (index-ascending, so navigatorBlocks is newest-first 5,4,3,2,1):
    /// `[5 FAIL, 4 ok, 3 FAIL, 2 ok, 1 FAIL]`. With the cursor on block 3, `.jumpNextFailed` (forward:true,
    /// toward OLDER) must land on 1, and `.jumpPreviousFailed` (forward:false, toward NEWER) must land on 5.
    /// A swapped `forward:` mapping (or both true) lands the wrong way and FAILS this — pinning the
    /// `.jumpPreviousFailed → false` / `.jumpNextFailed → true` inversion the router documents.
    func testJumpNextVsPreviousFailedLandOnOlderVsNewer() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [failed(1), ok(2), failed(3), ok(4), failed(5)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)
        // Seat the cursor ON block 3 (a failure) so the search must ADVANCE past it in each direction.
        store.blockBookmarks.jumpCursor[session.id] = 3

        // navigatorBlocks newest-first: [5,4,3,2,1]. Block 5 is at pos 0; block 1 is at pos 4.
        // .jumpNextFailed = forward:true = toward OLDER = block 1 (pos 4) → delta -(4+1) = -5 (the +1
        // steps past the live empty prompt, which ghostty marks but our block list has no block for).
        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        XCTAssertEqual(store.blockBookmarks.jumpCursor[session.id], 1, "next-failed lands on the OLDER failure (1)")
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-5"],
            "older failure (pos 4) = 5 prompts up",
        )

        recorder.resetActions()
        // From the cursor now on 1, .jumpPreviousFailed = forward:false = toward NEWER = block 3 (pos 2).
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)
        XCTAssertEqual(store.blockBookmarks.jumpCursor[session.id], 3, "prev-failed steps to the NEWER failure (3)")
        XCTAssertEqual(
            recorder.actions,
            ["scroll_to_bottom", "jump_to_prompt:-3"],
            "newer failure (pos 2) = 3 prompts up",
        )
    }

    /// `.jumpPreviousFailed` from the cursor on block 3 walks toward the NEWEST failure (5), not the oldest —
    /// a second, isolated pin of the inversion that does NOT depend on the next-failed step above.
    func testJumpPreviousFailedFromMiddleReachesNewest() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [failed(1), ok(2), failed(3), ok(4), failed(5)])
        store.blockBookmarks.jumpCursor[session.id] = 3

        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store) // toward NEWER
        XCTAssertEqual(
            store.blockBookmarks.jumpCursor[session.id],
            5,
            "prev-failed from 3 reaches the newest failure 5",
        )
    }

    // MARK: - Bookmark seed wiring (model → store persistence)

    /// `seedBlockBookmarks` (run when a leaf materializes) wires the model's `onBookmarksChanged` to the
    /// store's `save` closure keyed by the session's per-session scope key, with the indices SORTED — and
    /// `load` seeds the model from persistence. Pins the model→store round-trip the store-glue composes
    /// (untested before: every prior store test routed through a non-terminal `FakePaneSession`).
    func testSeedBlockBookmarksWiresSaveAndLoad() throws {
        let store = makeStore()
        // Install the persistence seam BEFORE materializing a fresh pane, so seedBlockBookmarks wires it.
        var saved: [String: [UInt32]] = [:]
        store.blockBookmarks.load = { key in key == "preseeded" ? [7, 2] : [] }
        store.blockBookmarks.save = { key, indices in saved[key] = indices }

        // Split to materialize a NEW leaf → wireMaterializedLeaf → seedBlockBookmarks runs for it.
        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)

        // A toggle fires onBookmarksChanged → save(scopeKey, sortedIndices).
        model.blocks.toggleBookmark(index: 5)
        model.blocks.toggleBookmark(index: 1)
        XCTAssertEqual(saved[session.bookmarkScopeKey], [1, 5], "save persists the SORTED indices under the scope key")
        XCTAssertNil(saved["preseeded"], "save is keyed by the session scope key, not an arbitrary string")
    }

    /// `load` seeds the freshly-materialized model's bookmark set (the restore direction) WITHOUT firing
    /// `save` (a seed is not a user edit).
    func testSeedBlockBookmarksLoadsPersistedSet() throws {
        let store = makeStore()
        var saveCount = 0
        store.blockBookmarks.load = { _ in [3, 9] }
        store.blockBookmarks.save = { _, _ in saveCount += 1 }

        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let session = try activeSession(store)
        let model = try XCTUnwrap(session.terminalModel)

        XCTAssertEqual(model.blocks.bookmarkedIndices, [3, 9], "the model is seeded from persistence on materialize")
        XCTAssertEqual(saveCount, 0, "seeding is the restore direction — it must NOT fire save")
    }

    /// Each materialized session mints its OWN per-session bookmark scope key, so distinct sessions never
    /// share a persisted star set — the property that makes a relaunch (a brand-new segmenter numbering
    /// blocks from 0) start with no stars instead of grafting a prior run's raw indices onto unrelated
    /// commands. (The stable PaneID would survive relaunch and re-key the same set — the bug this fixes.)
    func testEachSessionHasADistinctBookmarkScopeKey() throws {
        let store = makeStore()
        let first = try activeSession(store)
        store.splitActivePane(axis: .horizontal, kind: .terminal) // real terminal (route() now mints a chooser)
        let second = try activeSession(store)
        XCTAssertNotEqual(first.id, second.id, "two distinct panes")
        XCTAssertNotEqual(
            first.bookmarkScopeKey, second.bookmarkScopeKey,
            "each session's bookmark persistence key is distinct (per-session, not per-stable-pane-id)",
        )
    }

    // MARK: - BlockJump delta math (the shared re-anchor jump — Outline / navigator / jump-to-failed)

    /// Bug-B regression. `jumpDelta` must account for the current live empty prompt, which ghostty marks
    /// (its `133;A`) but our block list has NO block for: so newest-first block position `pos` sits
    /// `pos + 1` prompts up from the bottom → delta `-(pos + 1)`. The old `-pos` was off by one (clicking
    /// the newest command jumped to the empty prompt below it). Pure pin of the corrected contract; FAILS
    /// on the pre-fix `-pos` at every position (0 → 0 vs -1, 1 → -1 vs -2, …).
    func testBlockJumpDeltaAccountsForLiveEmptyPrompt() {
        XCTAssertEqual(
            BlockJump.jumpDelta(toTargetPos: 0),
            -1,
            "the NEWEST command is one prompt up from the live prompt",
        )
        XCTAssertEqual(BlockJump.jumpDelta(toTargetPos: 1), -2)
        XCTAssertEqual(BlockJump.jumpDelta(toTargetPos: 4), -5)
    }

    // MARK: - E9: Jump to a specific Outline block (jumpToNavigatorBlockInActivePane)

    /// E9 (ES-E9-2): clicking an Outline row jumps the scrollback to that block via
    /// `jumpToNavigatorBlockInActivePane(index:)` — the load-bearing half that had ZERO coverage. It must
    /// resolve the block's NEWEST-FIRST position in `navigatorBlocks` (not use the raw index as the delta)
    /// and route through the shared absolute re-anchor (`scroll_to_bottom` then `jump_to_prompt:-(pos+1)` —
    /// the `+1` steps past the live empty prompt, which ghostty marks but our block list has no block for).
    ///
    /// ORDERING-ASYMMETRIC on its own: seed an ODD count of 7 and target an OFF-CENTRE index (3, not the
    /// pivot 4) so newest-first and oldest-first resolve to DIFFERENT positions. Blocks index-ascending →
    /// navigatorBlocks newest-first `[7,6,5,4,3,2,1]`; block index 3 is at pos 4 → delta `-5`. Under a flipped
    /// (oldest-first `[1,2,3,4,5,6,7]`) resolution index 3 would be at pos 2 → `-3`, so this case FAILS directly
    /// on a swapped ordering — it no longer relies on the separate ends test. (A regression that used the raw
    /// index as the delta would emit `jump_to_prompt:-3` and also FAIL here.)
    func testJumpToNavigatorBlockResolvesNewestFirstPositionForIndex() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3), ok(4), ok(5), ok(6), ok(7)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 3)

        XCTAssertEqual(
            recorder.actions, ["scroll_to_bottom", "jump_to_prompt:-5"],
            "block 3 is at newest-first pos 4 (delta -(4+1) = -5); oldest-first would be pos 2 (-3), so a "
                + "flipped ordering fails THIS case directly",
        )
    }

    /// The OLDEST block (index 1) is at the deepest newest-first position (pos 4) → delta `-5`; the NEWEST
    /// (index 5) is at pos 0 → delta `-1` (one prompt up from the live empty prompt, NOT a no-op). Pins
    /// both ends of the position resolution so a swapped ordering (oldest-first) would fail.
    func testJumpToNavigatorBlockHandlesOldestAndNewestEnds() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3), ok(4), ok(5)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 1) // oldest → pos 4 → -(4+1)
        XCTAssertEqual(
            recorder.actions, ["scroll_to_bottom", "jump_to_prompt:-5"],
            "the oldest block is the deepest newest-first position (5 prompts up, past the live prompt)",
        )

        recorder.resetActions()
        store.jumpToNavigatorBlockInActivePane(index: 5) // newest → pos 0 → -(0+1)
        XCTAssertEqual(
            recorder.actions, ["scroll_to_bottom", "jump_to_prompt:-1"],
            "the newest block is ONE prompt above the live empty prompt — re-anchor then a single step up",
        )
    }

    /// An evicted / never-seen index is a graceful no-op — no surface action, no trap (the Outline can hold a
    /// row whose block has since rolled out of the navigator window). FAILS if the guard that requires the
    /// index to resolve to a position were dropped (it would emit a stray re-anchor or trap).
    func testJumpToNavigatorBlockUnknownIndexIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        store.jumpToNavigatorBlockInActivePane(index: 99) // never-seen / evicted index

        XCTAssertTrue(recorder.actions.isEmpty, "an unknown/evicted index emits no surface action (never traps)")
    }

    /// Jump-to-failed with NO failures is a no-op (cursor untouched, no surface action).
    func testJumpFailedWithNoFailuresIsANoOp() throws {
        let store = makeStore()
        let session = try seedBlocks(store, [ok(1), ok(2), ok(3)])
        let recorder = try XCTUnwrap(session.surfaceRecorder)

        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)

        XCTAssertNil(store.blockBookmarks.jumpCursor[session.id], "no failures ⇒ cursor stays unset")
        XCTAssertTrue(recorder.actions.isEmpty, "no failures ⇒ no jump action emitted")
    }
}
