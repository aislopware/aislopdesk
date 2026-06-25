import XCTest
@testable import AislopdeskWorkspaceCore

/// E1 WI-3 — the BEHAVIORAL dispatch of the active-pane font-size + viewport-scroll store hooks
/// (``WorkspaceStore/increaseFontInActivePane()`` / `decreaseFontInActivePane` / `resetFontInActivePane` /
/// ``WorkspaceStore/scrollActivePane(_:)``), observed on a ``RecordingTerminalPaneSession`` that carries a
/// REAL ``TerminalViewModel`` whose `surface` is a recording ``TerminalSurfaceActions``.
///
/// These pin the EXACT libghostty named binding action each hook fires (`increase_font_size`,
/// `scroll_page_fractional:-0.9`, `scroll_to_top`, …) — a swapped sign on page up/down or a wrong action
/// string would fail here. They drive the store methods DIRECTLY (the registry actions + routing land in a
/// later E1 work item); the hooks are the WI-3 deliverable, so the direct call is the right seam to pin.
///
/// HANG-SAFE: the recording session uses a headless ``RecordingSurfaceActions`` (no `GhosttySurface` /
/// VideoToolbox / Metal / SCStream) — the hang-safety rule holds.
@MainActor
final class FontScrollHookTests: XCTestCase {
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

    /// The recording surface backing the active pane's terminal model.
    private func activeRecorder(_ store: WorkspaceStore) throws -> RecordingSurfaceActions {
        try XCTUnwrap(activeSession(store).surfaceRecorder)
    }

    // MARK: - Font size (ES-E1-4)

    /// The three font hooks fire the matching libghostty action strings, in call order — pins ⌘=/⌘-/⌘0 →
    /// `increase_font_size` / `decrease_font_size` / `reset_font_size`. A wrong/misspelled string would fail.
    func testFontHooksFireTheLibghosttyFontActions() throws {
        let store = makeStore()
        let recorder = try activeRecorder(store)

        store.increaseFontInActivePane()
        store.decreaseFontInActivePane()
        store.resetFontInActivePane()

        XCTAssertEqual(
            recorder.actions,
            ["increase_font_size", "decrease_font_size", "reset_font_size"],
            "font hooks fire the libghostty font-size binding actions in order",
        )
    }

    // MARK: - Viewport scroll (ES-E1-3)

    /// Each ``ScrollAction`` fires its mapped action string — pins the page up/down SIGN (negative = up
    /// toward older scrollback) and the top/bottom buffer-end actions. A swapped page sign fails here.
    func testScrollHooksFireMappedActionsWithCorrectPageSign() throws {
        let store = makeStore()
        let recorder = try activeRecorder(store)

        store.scrollActivePane(.pageUp)
        store.scrollActivePane(.pageDown)
        store.scrollActivePane(.top)
        store.scrollActivePane(.bottom)

        XCTAssertEqual(
            recorder.actions,
            [
                "scroll_page_fractional:-0.9", // pageUp = negative = older
                "scroll_page_fractional:0.9", // pageDown = positive = newer
                "scroll_to_top",
                "scroll_to_bottom",
            ],
            "scroll hooks map to the page-fractional (≈ a page) + buffer-end actions with the up=negative sign",
        )
    }

    /// The ``ScrollAction/libghosttyAction`` mapping is the single source of truth — pin it independently of
    /// the store so a refactor of the store hook can't silently re-map the intent.
    func testScrollActionMappingIsStable() {
        XCTAssertEqual(ScrollAction.pageUp.libghosttyAction, "scroll_page_fractional:-0.9")
        XCTAssertEqual(ScrollAction.pageDown.libghosttyAction, "scroll_page_fractional:0.9")
        XCTAssertEqual(ScrollAction.top.libghosttyAction, "scroll_to_top")
        XCTAssertEqual(ScrollAction.bottom.libghosttyAction, "scroll_to_bottom")
    }

    // MARK: - Graceful no-op (non-terminal active pane)

    /// A non-terminal active pane (`.remoteGUI`) has no terminal model / no seam, so every font + scroll hook
    /// is a clean no-op — nothing is recorded and nothing traps. Mirrors the block hooks' graceful
    /// degradation; this is what makes the hooks safe to bind unconditionally.
    func testFontScrollAreNoOpOnNonTerminalActivePane() throws {
        let store = makeStore()
        // Replace the active leaf's session with a non-terminal one by splitting in a `.remoteGUI` pane and
        // focusing it; the recorder of the ORIGINAL terminal pane must stay empty after we act on the GUI pane.
        store.splitActivePane(axis: .horizontal, kind: .remoteGUI)
        let active = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let guiSession = try XCTUnwrap(store.handle(for: active) as? RecordingTerminalPaneSession)
        XCTAssertNil(guiSession.terminalModel, "the active pane is non-terminal (no model)")

        // None of these trap or touch a (non-existent) seam.
        store.increaseFontInActivePane()
        store.decreaseFontInActivePane()
        store.resetFontInActivePane()
        store.scrollActivePane(.pageUp)
        store.scrollActivePane(.pageDown)
        store.scrollActivePane(.top)
        store.scrollActivePane(.bottom)

        XCTAssertNil(guiSession.surfaceRecorder, "a non-terminal pane has no recording surface to fire into")
    }
}
