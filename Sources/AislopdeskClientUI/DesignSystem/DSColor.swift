#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - DSColor (LAYER 2 — semantic role tokens; the only colour layer views read)

/// Role-named colour tokens aliasing ``DSPalette`` primitives (Radix 12-step convention). View code reads
/// THESE (never `DSPalette.n3`), so a palette swap or a future light theme touches one layer.
///
/// P1 STATUS: every token here holds its TARGET spec value (the new cool ink ramp + indigo accent + the
/// recalibrated surface tints). NO view consumes `DSColor` in P1 — the components migrate in P2..P4. The
/// legacy ``AislopdeskTheme`` accessors keep their CURRENT literals (the compatibility shim), so the
/// screenshot is pixel-identical. `accentForeground` is the ONE helper the legacy accessor forwards to.
@preconcurrency @MainActor
public enum DSColor {
    // MARK: Surfaces (the elevation ladder, color side)

    /// window bg (L1)
    public static var bg: Color { DSPalette.n1 }
    /// sunken gutter behind panes (L0)
    public static var bgSunken: Color { DSPalette.n0 }
    /// terminal/content pane card bg (L2)
    public static var paneBg: Color { DSPalette.n2 }
    /// sidebar / tab strip / status bar (L3)
    public static var chrome: Color { DSPalette.n3 }
    /// overlay bg (L4 base, behind glass/material)
    public static var overlayBg: Color { DSPalette.n5 }

    // MARK: Text ladder (opacity-driven at a stable size, recalibrated on the new base)

    /// primary text — off-white, NOT #FFF
    public static var textPrimary: Color { DSPalette.n12 }
    /// secondary text (≈ fg·0.78 on the old base)
    public static var textSecondary: Color { DSPalette.n11 }
    /// tertiary text / section eyebrows (≈ fg·0.58)
    public static var textTertiary: Color { DSPalette.n10 }
    /// disabled glyph (≈ fg·0.32)
    public static var textDisabled: Color { DSPalette.n9 }

    // MARK: Interactive surface tints (white-over-bg for theme-portability)

    /// row hover fill
    public static var hoverFill: Color { .white.opacity(0.05) }
    /// active / pressed fill
    public static var activeFill: Color { .white.opacity(0.08) }
    /// selected-row wash — accent·0.18 so 'selected' clearly beats 'hover'
    public static var selectionWash: Color { accentSolid.opacity(0.18) }

    // MARK: Borders (hairlines — the elevation signal, not shadow)

    /// subtle hairline / pane border / divider at rest
    public static var borderSubtle: Color { .white.opacity(0.07) }
    /// component border / chrome-meets-content
    public static var borderComponent: Color { .white.opacity(0.11) }
    /// strong border / input edge
    public static var borderStrong: Color { .white.opacity(0.18) }

    // MARK: Accent (a SCARCE resource — focus ring, active-tab line, primary fill)

    /// solid accent — focus ring / primary fill. Overridable via ``DSThemeStore``; defaults to the DS
    /// indigo (``DSPalette.a9``). P1: the store's `accent` is `nil`, so this resolves to `a9`.
    public static var accentSolid: Color { DSThemeStore.shared.accent ?? DSPalette.a9 }
    /// hovered accent fill
    public static var accentSolidHover: Color { DSPalette.a10 }
    /// accent text on dark
    public static var accentText: Color { DSPalette.a11 }
    /// the pane / control focus ring (== accentSolid)
    public static var focusRing: Color { accentSolid }

    /// A contrasting foreground for glyphs painted ON an accent fill — black on a light accent, white on a
    /// dark one (threshold 0.6). The SINGLE contrast helper (``DSPalette.contrastingForeground(for:)``).
    public static var accentForeground: Color {
        #if canImport(AppKit)
        Color(nsColor: DSPalette.contrastingForeground(for: NSColor.controlAccentColor))
        #else
        .white
        #endif
    }

    // MARK: Status (forward the fixed-hue literals)

    public static var statusBlue: Color { DSPalette.statusBlue }
    public static var statusGreen: Color { DSPalette.statusGreen }
    public static var statusRed: Color { DSPalette.statusRed }
    public static var statusYellow: Color { DSPalette.statusYellow }

    // MARK: Scrim (the single overlay-backdrop token, target-only in P1)

    /// The shared modal/overlay scrim — black·0.40 (unifies the three ad-hoc `.black.opacity(0.18/0.35)`
    /// copies in P4).
    public static var scrim: Color { .black.opacity(0.40) }
}
#endif
