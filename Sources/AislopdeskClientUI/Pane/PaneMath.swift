// PaneMath — pure, testable helpers for the L3 pane layer (divider drag→weight-delta + cwd truncation).
// Kept free of SwiftUI so `AislopdeskClientUITests` can pin them without a view (the house float idiom:
// ordered `>` guards over a finite span; no fma/addingProduct).

import CoreGraphics

enum PaneMath {
    /// Convert an incremental pixel drag along the split axis into a flex-weight delta over the parent
    /// span. Returns 0 for a non-finite / non-positive span (the divider then sends nothing). The drag is
    /// the INCREMENT since the last `onChanged` (the view tracks the running translation).
    static func weightDelta(pixelIncrement: CGFloat, axisSpan: CGFloat) -> Double {
        guard axisSpan.isFinite, axisSpan > 0, pixelIncrement.isFinite else { return 0 }
        return Double(pixelIncrement) / Double(axisSpan)
    }

    /// Truncate a cwd path from the BEGINNING (keep the trailing leaf dirs visible), max `maxChars`
    /// glyphs incl. the leading ellipsis (spec §5.1 `truncate_from_beginning`, max 40).
    static func truncatedCwd(_ cwd: String, maxChars: Int = 40) -> String {
        guard cwd.count > maxChars else { return cwd }
        guard maxChars > 1 else { return String(cwd.suffix(maxChars)) }
        return "…" + String(cwd.suffix(maxChars - 1))
    }
}
