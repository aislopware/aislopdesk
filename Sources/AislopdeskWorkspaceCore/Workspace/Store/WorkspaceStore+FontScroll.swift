import AislopdeskTerminal
import Foundation

// MARK: - ScrollAction (the named viewport-scroll the E1 ⇧PageUp/Down + ⇧Home/End chords route through)

/// The four viewport-scroll intents the E1 keymap binds to the named scroll keys (⇧PageUp/PageDown →
/// page up/down, ⇧Home/End → buffer top/bottom). A framework-neutral enum (no AppKit / no libghostty
/// import) so the routing + the store hook stay headless; the libghostty action string each maps to is the
/// single source of the mapping (``libghosttyAction``).
///
/// Scroll-sign convention (libghostty `Binding.zig`, mirrored by ``TerminalViewModel/handleCopyModeKey(_:)``):
/// NEGATIVE = UP toward OLDER scrollback. So `.pageUp` is `scroll_page_fractional:-0.9` and `.pageDown` is
/// `scroll_page_fractional:0.9`. `0.9` (≈ one page minus a sliver of overlap context) is the same "≈ a page"
/// fraction the E1 plan pins — distinct from copy-mode's half-page `±0.5` (Ctrl-D/U), which is a different
/// gesture.
public enum ScrollAction: Equatable, Sendable {
    /// ⇧PageUp — one page toward OLDER scrollback (negative sign).
    case pageUp
    /// ⇧PageDown — one page toward NEWER output (positive sign).
    case pageDown
    /// ⇧Home — jump to the very top of the scrollback buffer.
    case top
    /// ⇧End — jump to the very bottom (newest) of the scrollback buffer.
    case bottom

    /// The libghostty named binding action this scroll intent fires through
    /// ``TerminalSurfaceActions/performBindingAction(_:)`` — the SINGLE source of the intent→action mapping
    /// (so the store hook and any test pin the same string). `0.9` ≈ one page; the sign follows the
    /// negative-is-up convention.
    var libghosttyAction: String {
        switch self {
        case .pageUp: "scroll_page_fractional:-0.9"
        case .pageDown: "scroll_page_fractional:0.9"
        case .top: "scroll_to_top"
        case .bottom: "scroll_to_bottom"
        }
    }
}

// MARK: - WorkspaceStore × Font size + viewport scroll (E1 ES-E1-3 / ES-E1-4 store hooks)

/// The E1 active-pane font-size + viewport-scroll store hooks, split into their own extension so the
/// (already large) ``WorkspaceStore`` body stays under the lint type-body ceiling — the same reason
/// ``WorkspaceStore+Blocks`` exists. Each one mirrors ``WorkspaceStore/jumpToBlockInActivePane(delta:)``:
/// resolve the active pane's live ``TerminalViewModel`` (``activeTerminalModel``), probe its `surface` for
/// the ``TerminalSurfaceActions`` capability seam, and fire the matching libghostty named binding action.
///
/// All four are a clean no-op for a non-terminal active pane (`.remoteGUI` / `.systemDialog`), an empty
/// shell, or a headless / placeholder surface that does not conform to ``TerminalSurfaceActions`` (no seam) —
/// the same graceful degradation the block hooks use. None instantiate a renderer, so the whole surface is
/// unit-testable against a recording ``TerminalSurfaceActions`` fake (the hang-safety rule: no real
/// `GhosttySurface` in a test).
public extension WorkspaceStore {
    /// ⌘= (and the auto-shifted ⌘+) — bumps the active pane's render font size one step via libghostty's
    /// `increase_font_size`. A larger font fits FEWER cells in the same pane pixel box, so the PTY grid
    /// (cols/rows) shrinks and the remote PTY IS reflowed via SIGWINCH (correcting ES-E1-4's earlier
    /// "without reflowing the PTY grid" note — a font step is NOT grid-preserving). A no-op for a
    /// non-terminal pane / no seam.
    func increaseFontInActivePane() {
        performActiveSurfaceAction("increase_font_size")
    }

    /// ⌘- — shrinks the active pane's render font size one step (`decrease_font_size`). Same reflow property
    /// as ``increaseFontInActivePane()`` (a smaller font fits MORE cells → the grid grows → SIGWINCH). A
    /// no-op for a non-terminal pane / no seam.
    func decreaseFontInActivePane() {
        performActiveSurfaceAction("decrease_font_size")
    }

    /// ⌘0 — resets the active pane's render font size to the configured default (`reset_font_size`). A no-op
    /// for a non-terminal pane / no seam.
    func resetFontInActivePane() {
        performActiveSurfaceAction("reset_font_size")
    }

    /// Scrolls the active pane's viewport per the named ``ScrollAction`` (⇧PageUp/Down → page up/down,
    /// ⇧Home/End → buffer top/bottom). Routes the action's ``ScrollAction/libghosttyAction`` string through
    /// the active surface's ``TerminalSurfaceActions`` seam — the SAME lever jump-to-prompt / copy-mode scroll
    /// use. A no-op for a non-terminal pane, an empty shell, or a headless / placeholder surface (no seam).
    func scrollActivePane(_ action: ScrollAction) {
        performActiveSurfaceAction(action.libghosttyAction)
    }

    /// The shared resolve-then-fire used by the font + scroll hooks: resolve the active terminal model,
    /// probe its `surface` for ``TerminalSurfaceActions``, and fire `action`. Mirrors
    /// ``WorkspaceStore/jumpToBlockInActivePane(delta:)`` exactly so the font/scroll path can't drift from the
    /// block-jump path on how it reaches the seam. A no-op when any link is absent (non-terminal / no seam).
    private func performActiveSurfaceAction(_ action: String) {
        guard let model = activeTerminalModel,
              let actions = model.surface as? TerminalSurfaceActions else { return }
        actions.performBindingAction(action)
    }
}
