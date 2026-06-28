import AislopdeskTerminal
import CoreGraphics
import Foundation

// MARK: - WindowSizeMath (E19 A29: pure window-sizing arithmetic)

/// PURE window-sizing arithmetic for the otty `window-size` modes (`grid` / `frame` / `remember`). The
/// single source of truth the (macOS-only, hang-unsafe) `NSWindow` glue calls to decide a new window's
/// initial CONTENT size; headlessly unit-testable so the math is proven apart from any AppKit instantiation.
///
/// Float discipline mirrors ``AislopdeskVideoHost``'s `WindowPlacementMath.placement` (see CLAUDE.md §2):
///   * ordered TERNARY min/max (`a < b ? a : b`), NOT `Swift.min`/`Swift.max` nor a bare `<`/`>` clamp —
///     NaN-faithful (a NaN operand propagates, exactly as `WindowPlacementMath` does);
///   * separate `*` then assignment — NEVER `addingProduct`/`fma` (extra FMA precision would diverge the
///     low bits and break the codec/controller float contract this habit guards);
///   * no force-unwrap, no trap on any input (validate-then-clamp: a 0 / negative / gigantic count or pixel
///     count is clamped into a sane band, never propagated as a 0×0 or off-screen-gigantic window).
///
/// No SwiftUI / AppKit import — `CoreGraphics` (`CGSize`/`CGRect`) + the pure ``TerminalCellMetrics`` value
/// type (the live per-cell advance the glue snapshots from the active terminal surface) only.
public enum WindowSizeMath {
    // MARK: Clamp bands (validate-then-drop — never 0, never gigantic)

    /// The inclusive column / row band: at least 1 (a 0-row window is degenerate) and capped at a sane
    /// 1000 (otty's `window-cols`/`window-rows` are small cell counts; a 5-figure value is a typo / hostile).
    public static let minCells = 1
    public static let maxCells = 1000
    /// The inclusive pixel band for `frame` mode: a 64pt floor (smaller than a usable window) up to 16384
    /// (the Metal max-texture / sane-display ceiling, matching the video path's dimension clamp).
    public static let minPx = 64
    public static let maxPx = 16384
    /// The sane CONTENT floor for ``clampToScreen`` — a window can never resolve below this even on a tiny
    /// display (200×120pt ≈ a few cells; below it the chrome would have no room).
    public static let minContentWidth: CGFloat = 200
    public static let minContentHeight: CGFloat = 120

    // MARK: Scalar clamps

    /// Clamp a raw column count into `1...1000` — never 0 (degenerate), never gigantic. Ordered `max`/`min`
    /// on `Int` (no float, no NaN concern).
    public static func clampCols(_ raw: Int) -> Int {
        max(minCells, min(raw, maxCells))
    }

    /// Clamp a raw row count into `1...1000`. See ``clampCols(_:)``.
    public static func clampRows(_ raw: Int) -> Int {
        max(minCells, min(raw, maxCells))
    }

    /// Clamp a raw pixel dimension into `64...16384` — never below a usable window, never above the sane
    /// display / texture ceiling.
    public static func clampPx(_ raw: Int) -> Int {
        max(minPx, min(raw, maxPx))
    }

    // MARK: Grid → content points

    /// The CONTENT size (points) for a `cols × rows` grid given the live per-cell advance in `cell`. The
    /// columns / rows are clamped first (so a 0 / gigantic input can never produce a 0 or absurd content
    /// size). Returns the RAW (not-yet-screen-clamped) content extent — the screen clamp is a separate step
    /// (``clampToScreen(_:visible:chromeInsets:)``).
    ///
    /// Separate `*` then assignment, NEVER `fma` (CLAUDE.md §2): `width = cellWidth * cols`,
    /// `height = cellHeight * rows`.
    public static func gridContentSize(cols: Int, rows: Int, cell: TerminalCellMetrics) -> CGSize {
        let width = cell.cellWidth * CGFloat(clampCols(cols))
        let height = cell.cellHeight * CGFloat(clampRows(rows))
        return CGSize(width: width, height: height)
    }

    // MARK: Screen clamp

    /// Clamp a desired CONTENT size so `content + chrome ≤ visible`, then floor it at the sane minimum
    /// (``minContentWidth`` × ``minContentHeight``) so a tiny request / tiny display can never resolve to a
    /// degenerate window. `chromeInsets` is the window's non-content overhead (title bar + borders) as a
    /// `CGSize` (`width` = horizontal chrome, `height` = vertical chrome).
    ///
    /// `visible.width`/`.height` are CG-STANDARDIZED (always ≥ 0). The available content extent is the
    /// visible extent minus the chrome (a separate subtraction). The cap + floor both use the ordered
    /// TERNARY form (`a < b ? a : b`) — NaN-faithful, matching `WindowPlacementMath` (a bare `<`/`>` clamp
    /// would have the wrong NaN behaviour, and `Swift.min`/`max` propagate NaN differently).
    public static func clampToScreen(_ size: CGSize, visible: CGRect, chromeInsets: CGSize) -> CGSize {
        // Available content extent = visible − chrome (separate subtraction; no fma).
        let availWidth = visible.width - chromeInsets.width
        let availHeight = visible.height - chromeInsets.height
        // Cap DOWN to the available extent — ordered min (`avail < want ? avail : want`).
        let cappedWidth = availWidth < size.width ? availWidth : size.width
        let cappedHeight = availHeight < size.height ? availHeight : size.height
        // Floor at the sane minimum — ordered max (`capped < min ? min : capped`).
        let width = cappedWidth < minContentWidth ? minContentWidth : cappedWidth
        let height = cappedHeight < minContentHeight ? minContentHeight : cappedHeight
        return CGSize(width: width, height: height)
    }

    // MARK: Resolution (the single glue entry point)

    /// Resolve the CONTENT size a newly opened window should adopt, or `nil` when the autosaved frame should
    /// stand (the `.remember` path). The ONE function the macOS `NSWindow` glue (WI-4) calls:
    ///
    /// - ``WindowSizeMode/remember`` → `nil` — let `setFrameAutosaveName` restore the last frame; apply no
    ///   explicit size.
    /// - ``WindowSizeMode/grid`` → ``clampToScreen(_:visible:chromeInsets:)`` of
    ///   ``gridContentSize(cols:rows:cell:)``.
    /// - ``WindowSizeMode/frame`` → ``clampToScreen(_:visible:chromeInsets:)`` of the clamped pixel size
    ///   (``clampPx(_:)`` on each axis).
    ///
    /// Every numeric input is clamped before it reaches the geometry, so a persisted 0 / negative / gigantic
    /// value can never yield a 0×0 or off-screen-gigantic window.
    public static func resolvedContentSize(
        mode: WindowSizeMode,
        cols: Int,
        rows: Int,
        widthPx: Int,
        heightPx: Int,
        cell: TerminalCellMetrics,
        visible: CGRect,
        chromeInsets: CGSize,
    ) -> CGSize? {
        switch mode {
        case .remember:
            return nil
        case .grid:
            let grid = gridContentSize(cols: cols, rows: rows, cell: cell)
            return clampToScreen(grid, visible: visible, chromeInsets: chromeInsets)
        case .frame:
            let desired = CGSize(width: CGFloat(clampPx(widthPx)), height: CGFloat(clampPx(heightPx)))
            return clampToScreen(desired, visible: visible, chromeInsets: chromeInsets)
        }
    }
}
