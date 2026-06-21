#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - PaneTokens (LAYER 3 — component token struct; the only thing a component file imports)

/// The pane-component token alias set: the ONLY design-system surface ``PaneChromeView`` will import once
/// it migrates (P2). Each token aliases a ``DSColor`` / ``DSSpace`` / ``DSRadius`` role so the component
/// never reaches a primitive. Landed in P1 as a tiny vocabulary stub (no component refactor); the other
/// LAYER-3 token structs (Tab/Sidebar/StatusBar/Palette) arrive with their component refactors in P3/P4.
///
/// ⚠️ LIVE-SCALE CONTRACT: `focusRingWidth` / `radius` are `static var` getters that route through
/// ``DSScale/scaled(_:)`` (a singleton read inside a static var, which SwiftUI cannot observe). A width
/// read straight into `.strokeBorder(lineWidth: PaneTokens.focusRingWidth)` will NOT live-repaint on a P5
/// density flip — consume via a tracked `@Environment(DSScale.self)`-reading modifier when it must reflow
/// live. See the ``DSSpace`` contract note.
@preconcurrency @MainActor
public enum PaneTokens {
    /// The pane focus-ring colour (== accent).
    public static var focusRingColor: Color { DSColor.focusRing }
    /// The pane focus-ring width — 1.5pt scaled. Single `*` inside ``DSScale.scaled`` (no FMA).
    public static var focusRingWidth: CGFloat { DSScale.scaled(1.5) }
    /// The pane border at rest (idle, unfocused).
    public static var idleBorder: Color { DSColor.borderSubtle }
    /// The per-pane card radius.
    public static var radius: CGFloat { DSRadius.pane }
}
#endif
