// WarpThemeResolveTests — pin the DEFAULT theme's seeds + resolved derived values.
//
// The shipping default (`WarpTheme`) seeds the LIVE Warp window slate (bg #1D2022, ORCH-DECISIONS
// L7 polish BG-TONE finding) — NOT Warp's literal code-default #000000 (that pure-black variant is
// `PureBlackDark`, pinned separately below). Exact ColorU equality so a derivation refactor — or a
// silent drift away from the live-window match — can't slip through.

import Testing
@testable import AislopdeskDesignSystem

struct WarpThemeResolveTests {
    let c = WarpTheme.dark.colors

    // MARK: Seeds — live-window slate (#1D2022)

    @Test
    func seeds() {
        #expect(c.background == ColorU(u32: 0x1D20_22FF)) // #1D2022 live slate
        #expect(c.foreground == ColorU(u32: 0xFFFF_FFFF)) // #FFFFFF
        #expect(c.accent == ColorU(u32: 0x19AA_D8FF)) // #19AAD8 teal
        #expect(c.cursor == c.accent) // cursor nil → accent fallback
        #expect(WarpTheme.dark.name == "Warp Slate")
    }

    // MARK: Neutral surfaces — bg.blend(fg @ N%) over the #1D2022 base (verified by the blend math)

    @Test
    func `neutral surfaces`() {
        #expect(c.surface1 == ColorU(r: 0x28, g: 0x2B, b: 0x2D, a: 255)) // fg@5%  ≈ #282B2D (top bar)
        #expect(c.surface2 == ColorU(r: 0x34, g: 0x36, b: 0x38, a: 255)) // fg@10% ≈ #343638
        #expect(c.surface3 == ColorU(r: 0x3F, g: 0x41, b: 0x43, a: 255)) // fg@15% ≈ #3F4143
        #expect(c.neutral4 == ColorU(r: 0x4A, g: 0x4D, b: 0x4E, a: 255)) // fg@20% ≈ #4A4D4E
        #expect(c.neutral25 == ColorU(r: 0x56, g: 0x58, b: 0x59, a: 255)) // fg@25% ≈ #565859 (pill fill)
        #expect(c.neutral5 == ColorU(r: 0x77, g: 0x79, b: 0x7A, a: 255)) // fg@40% ≈ #77797A
        #expect(c.neutral6 == ColorU(r: 0xA5, g: 0xA6, b: 0xA7, a: 255)) // fg@60% ≈ #A5A6A7
        #expect(c.neutral7 == ColorU(r: 0xE8, g: 0xE9, b: 0xE9, a: 255)) // fg@90% ≈ #E8E9E9
    }

    @Test
    func `neutral aliases`() {
        #expect(c.subshellBackground == c.neutral4)
        #expect(c.blockBannerBackground == c.surface3)
        #expect(c.tooltipBackground == c.neutral6)
    }

    // MARK: Live-window-match pins (L7 polish) — top bar / standard pill / outline must not drift

    @Test
    func `live window match`() {
        // Top bar = surface_1 ≈ #282B2D (live #262A2C; the seed-derive achromatic ladder lands #282B2D).
        #expect(c.surface1 == ColorU(r: 0x28, g: 0x2B, b: 0x2D, a: 255))
        // Standard footer-pill REST fill = neutral4 ≈ #26292B (live unfilled pill #262A2C); the old
        // neutral25 (#565859) was ~3 tiers too bright. Live FILLED pill (/remote-control) = active tier.
        #expect(c.footerPillFill == ColorU(r: 0x26, g: 0x29, b: 0x2B, a: 255))
        #expect(c.footerPillFillActive == ColorU(r: 0x46, g: 0x48, b: 0x4A, a: 255)) // neutral18 (live #44494C)
        // outline() = fg@10% over slate = a translucent white at alpha 25 (opaque-base resolved later).
        #expect(c.outline == ColorU(r: 255, g: 255, b: 255, a: 25))
    }

    // MARK: Pill fills (L7 polish) — muted green + cwd cyan tint, derived from the seed model

    @Test
    func `pill fills`() {
        // Muted suggestion green = low neutral surface (neutral13) tinted by uiGreen@8% ≈ #384541
        // (live ≈ #374442; a grayed DARK green — the old #486A59 was too bright and too green).
        #expect(c.suggestionGreenFill == ColorU(r: 0x38, g: 0x45, b: 0x41, a: 255))
        // CwdPill surface = the low neutral chrome tier (neutral4) ≈ #26292B (live #262A2C); the cyan
        // lives only in the glyph + path text, not the fill (the old #515F63 was too bright + over-tinted).
        #expect(c.cwdPillFill == ColorU(r: 0x26, g: 0x29, b: 0x2B, a: 255))
        // CwdPill border = accent_overlay_2 (accent@25%).
        #expect(c.cwdPillBorder == c.accentOverlay2)
        #expect(c.cwdPillBorder == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 63))
    }

    // MARK: Foreground overlays — translucent fg, bg-independent (warp-tokens-color.md §3c)

    @Test
    func `fg overlays`() {
        // fg@N% → white with alpha = 255*N/100 (independent of the base color).
        #expect(c.fgOverlay1 == ColorU(r: 255, g: 255, b: 255, a: 12)) // 5%  → a=12
        #expect(c.fgOverlay2 == ColorU(r: 255, g: 255, b: 255, a: 25)) // 10% → a=25
        #expect(c.fgOverlay3 == ColorU(r: 255, g: 255, b: 255, a: 38)) // 15% → a=38
    }

    @Test
    func `outline and split border`() {
        #expect(c.outline == c.fgOverlay2) // outline() = fg_overlay_2 (fg@10%)
        #expect(c.splitPaneBorder == c.fgOverlay3) // split = fg_overlay_3 (fg@15%)
        #expect(c.inactivePaneOverlay == c.fgOverlay2)
    }

    // MARK: Accent overlays — translucent accent, bg-independent (warp-tokens-color.md §3d)

    @Test
    func `accent overlays`() {
        // accent #19AAD8 with alpha = 255*N/100.
        #expect(c.accentOverlay1 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 25)) // 10% → a=25
        #expect(c.accentOverlay2 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 63)) // 25% → a=63 (selection)
        #expect(c.accentOverlay3 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 102)) // 40% → a=102 (pressed)
        #expect(c.accentOverlay4 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 153)) // 60% → a=153 (hover)
    }

    // MARK: Fixed status literals (warp-tokens-color.md §3a)

    @Test
    func `fixed status literals`() {
        #expect(c.uiWarning == ColorU(u32: 0xC280_00FF)) // #C28000
        #expect(c.uiError == ColorU(u32: 0xBC36_2AFF)) // #BC362A
        #expect(c.uiYellow == ColorU(u32: 0xE5A0_1AFF)) // #E5A01A
        #expect(c.uiGreen == ColorU(u32: 0x1CA0_5AFF)) // #1CA05A
        #expect(c.success == ColorU(u32: 0x008E_41FF)) // #008E41
    }

    @Test
    func `selection and agent accents`() {
        // text_selection = #76A7FA @ 40% = rgba(118,167,250,102).
        #expect(c.textSelection == ColorU(r: 118, g: 167, b: 250, a: 102))
        // Agent accents are SEPARATE from the (teal) terminal accent.
        #expect(AgentAccent.claudeOrange == ColorU(u32: 0xE870_4EFF)) // #E8704E
        #expect(AgentAccent.footerBrand == ColorU(u32: 0xD977_57FF)) // #D97757
        #expect(c.accent != AgentAccent.claudeOrange) // teal ≠ orange
    }

    // MARK: Terminal ANSI palette spot-checks (warp-tokens-color.md §2b)

    @Test
    func `ansi palette`() {
        #expect(c.seeds.terminal.normal.magenta == ColorU(u32: 0xFF8F_FDFF)) // #FF8FFD (prompt pwd)
        #expect(c.seeds.terminal.normal.green == ColorU(u32: 0xB4FA_72FF)) // #B4FA72 (git)
        #expect(c.seeds.terminal.bright.white == ColorU(u32: 0xFEFF_FFFF)) // #FEFFFF
        #expect(c.seeds.terminal.normal.black == ColorU(u32: 0x6161_61FF)) // #616161
    }

    // MARK: Pure-black alternate theme — Warp's literal code default (#000000)

    @Test
    func `pure black alternate`() {
        let p = PureBlackDark.pureBlack.colors
        #expect(p.background == ColorU(u32: 0x0000_00FF)) // #000000 — Warp's literal default seed
        #expect(p.foreground == ColorU(u32: 0xFFFF_FFFF))
        #expect(p.accent == ColorU(u32: 0x19AA_D8FF))
        #expect(PureBlackDark.pureBlack.name == "Dark")
        // Same derivation, pure-black base → the original #000000-derived surfaces (warp-tokens-color §3b).
        #expect(p.surface1 == ColorU(r: 0x0D, g: 0x0D, b: 0x0D, a: 255)) // fg@5%  ≈ #0D0D0D
        #expect(p.surface2 == ColorU(r: 0x1A, g: 0x1A, b: 0x1A, a: 255)) // fg@10% = #1A1A1A
        #expect(p.surface3 == ColorU(r: 0x26, g: 0x26, b: 0x26, a: 255)) // fg@15% = #262626
        // Same translucent-overlay alphas regardless of base.
        #expect(p.outline == c.outline)
    }
}
