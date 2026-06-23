// WarpTheme — the DEFAULT `Theme`, seeded to match the user's LIVE Warp window.
//
// Warp's *code* default ("Dark") seeds background #000000 (default_themes.rs:264). But the user's
// live window renders a dark SLATE — panes ≈ #1D2022, top bar ≈ #282B2D, footer pills ≈ #565B5E —
// which the seed+derive model reproduces exactly from a #1D2022 base (ORCH-DECISIONS, L7 polish
// BG-TONE finding). #1D2022 is itself a literal in Warp's bundled themes
// (`ColorU::from_u32(0x1D2022FF)` in app/src/themes/default_themes.rs — the bundled/chrome surface),
// so the live look is the bundled-chrome slate, NOT pure black. Seeding #000000 made every surface
// ~30 levels too dark vs the live window and was the root cause of the recurring odiff bg-tone delta.
//
// So the SHIPPING default seeds background #1D2022 to match what the user SEES; everything else
// (foreground #FFFFFF, terminal accent #19AAD8 teal, Details=Darker, the Dark ANSI palette) is
// Warp's verbatim Dark seed set. The pure-black "Dark" literal default is preserved as the
// `PureBlackDark` alternate `Theme` (same derivation, bg #000000) so the abstraction still offers it.
//
// NOTE (future option): we deliberately keep the base an OPAQUE #1D2022 rather than layering an
// NSVisualEffectView / window vibrancy material under a translucent surface. Opaque keeps the render
// deterministic + headless-odiff-able (the metric reflects component fidelity, not a live blur).
// Window vibrancy could be added later behind a flag at the AppKit window level without touching
// these seeds.

import Foundation

/// The shipping default theme — Warp's Dark seeds with the live-window slate background (#1D2022).
public struct WarpTheme: Theme {
    public let seeds: ThemeSeeds
    public let name: String

    public init() {
        name = "Warp Slate"
        seeds = ThemeSeeds(
            background: ColorU(u32: 0x1D20_22FF), // #1D2022 — live Warp window slate (bundled-chrome surface)
            foreground: ColorU(u32: 0xFFFF_FFFF), // #FFFFFF (default_themes.rs:265)
            accent: ColorU(u32: 0x19AA_D8FF), // #19AAD8 teal (default_themes.rs:266)
            cursor: nil, // None → falls back to accent (default_themes.rs:267)
            details: .darker, // Darker (default_themes.rs:268)
            terminal: .warpDark, // Dark ANSI palette (§2b)
        )
    }

    /// The shared default theme instance (live-window slate).
    public static let dark = Self()
}

/// Warp's literal code-default "Dark" theme — pure-black background (#000000), otherwise identical
/// seeds to `WarpTheme`. Kept as an explicit ALTERNATE so the abstraction still offers Warp's exact
/// bundled default; the SHIPPING app default is `WarpTheme` (the #1D2022 live-matching slate).
public struct PureBlackDark: Theme {
    public let seeds: ThemeSeeds
    public let name: String

    public init() {
        name = "Dark"
        seeds = ThemeSeeds(
            background: ColorU(u32: 0x0000_00FF), // #000000 (default_themes.rs:264) — Warp's literal default
            foreground: ColorU(u32: 0xFFFF_FFFF), // #FFFFFF
            accent: ColorU(u32: 0x19AA_D8FF), // #19AAD8 teal
            cursor: nil,
            details: .darker,
            terminal: .warpDark,
        )
    }

    /// The shared pure-black alternate instance.
    public static let pureBlack = Self()
}
