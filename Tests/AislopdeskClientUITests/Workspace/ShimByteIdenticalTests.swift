import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The P2 REGRESSION PINS for the recalibrated surface ladder. P1 pinned every legacy accessor to its
/// pre-P1 literal (so the screenshot was pixel-identical through the shim conversion); P2 REPOINTS the
/// ``AislopdeskTheme`` colour accessors at the ``DSColor`` / ``DSPalette`` semantic tokens, so the new cool
/// ink ramp + indigo accent + recalibrated text ladder are VISIBLE everywhere at once. These tests are
/// FLIPPED accordingly — they now assert each legacy accessor resolves to its NEW DS target value, so they
/// become the regression pins for the new ramp. (A test still asserting the OLD warm literal would be the
/// bug: it would mean the repoint silently did not land.)
///
/// Uses SwiftUI `Color` `Equatable` (the existing `PaneStatusIndicatorTests` / `AgentStatusDotColorTests`
/// pattern) — each accessor compares equal to the exact DS token / primitive it now forwards to, so a
/// representation drift is still caught. The type / spacing TARGET values still DIFFER from the legacy
/// `UIMetrics` geometry (P2 is colour + elevation ONLY; geometry migrates in P3/P5) — that guard is kept.
@MainActor
final class ShimByteIdenticalTests: XCTestCase {
    #if canImport(SwiftUI)

    // MARK: - AislopdeskTheme colours now resolve to the NEW DS ramp (P2 repoint)

    func testThemeBaseColorsRepointedToDSRamp() {
        // bg -> n1, bgRaised -> chrome(n3), bgSunken -> n0, fg -> n12.
        XCTAssertEqual(AislopdeskTheme.bg, DSColor.bg)
        XCTAssertEqual(AislopdeskTheme.bg, DSPalette.n1)
        XCTAssertEqual(AislopdeskTheme.bgRaised, DSColor.chrome)
        XCTAssertEqual(AislopdeskTheme.bgRaised, DSPalette.n3)
        XCTAssertEqual(AislopdeskTheme.bgSunken, DSColor.bgSunken)
        XCTAssertEqual(AislopdeskTheme.bgSunken, DSPalette.n0)
        XCTAssertEqual(AislopdeskTheme.fg, DSColor.textPrimary)
        XCTAssertEqual(AislopdeskTheme.fg, DSPalette.n12)
    }

    /// CONCRETE-VALUE BACKSTOP for the base ink ramp. The token-against-token pins above follow the
    /// primitive, so they would STILL pass if `DSPalette.n1` were re-authored to a wrong hex. This pin
    /// hardcodes the spec hexes ONCE so an accidental repoint of the underlying primitive is caught —
    /// making the suite a true regression pin for the new ramp, not just a token-follower. The hexes are
    /// the spec values: n1 #121316 (bg), n3 #1D1F24 (bgRaised), n0 #0C0D0F (bgSunken), n12 #ECEEF1 (fg).
    func testThemeBaseColorsResolveToSpecHexes() {
        XCTAssertEqual(AislopdeskTheme.bg, Color(hex: 0x121316), "bg must be the cool ink n1 #121316")
        XCTAssertEqual(AislopdeskTheme.bgRaised, Color(hex: 0x1D1F24), "bgRaised must be the chrome n3 #1D1F24")
        XCTAssertEqual(AislopdeskTheme.bgSunken, Color(hex: 0x0C0D0F), "bgSunken must be the sunken floor n0 #0C0D0F")
        XCTAssertEqual(AislopdeskTheme.fg, Color(hex: 0xECEEF1), "fg must be the off-white n12 #ECEEF1")
    }

    func testThemeForegroundLadderRepointedToDSTextTokens() {
        // The recalibrated text ladder: primary -> n12, muted -> n11, dim -> n10, faint -> n9.
        XCTAssertEqual(AislopdeskTheme.fgPrimary, DSColor.textPrimary)
        XCTAssertEqual(AislopdeskTheme.fgMuted, DSColor.textSecondary)
        XCTAssertEqual(AislopdeskTheme.fgDim, DSColor.textTertiary)
        XCTAssertEqual(AislopdeskTheme.fgFaint, DSColor.textDisabled)
    }

    /// CONCRETE-VALUE BACKSTOP for the recalibrated text ladder. As above, the token-against-token pins
    /// follow the primitive; this hardcodes the spec hexes ONCE so a drift in `DSPalette.n9…n12` is caught:
    /// primary n12 #ECEEF1, muted n11 #C3C7CE, dim n10 #9AA0AB, faint n9 #6B7280.
    func testThemeForegroundLadderResolvesToSpecHexes() {
        XCTAssertEqual(AislopdeskTheme.fgPrimary, Color(hex: 0xECEEF1), "fgPrimary must be n12 #ECEEF1")
        XCTAssertEqual(AislopdeskTheme.fgMuted, Color(hex: 0xC3C7CE), "fgMuted must be n11 #C3C7CE")
        XCTAssertEqual(AislopdeskTheme.fgDim, Color(hex: 0x9AA0AB), "fgDim must be n10 #9AA0AB")
        XCTAssertEqual(AislopdeskTheme.fgFaint, Color(hex: 0x6B7280), "fgFaint must be n9 #6B7280")
    }

    func testThemeSurfaceLadderRepointedToDSTints() {
        // White-over-bg tints: surface05/hover -> hoverFill(0.05), surface/surface12 -> activeFill(0.08),
        // border -> borderSubtle(0.07). surface12's distinct rung flattens onto activeFill by design.
        XCTAssertEqual(AislopdeskTheme.surface05, DSColor.hoverFill)
        XCTAssertEqual(AislopdeskTheme.surface, DSColor.activeFill)
        XCTAssertEqual(AislopdeskTheme.surface12, DSColor.activeFill)
        XCTAssertEqual(AislopdeskTheme.border, DSColor.borderSubtle)
        XCTAssertEqual(AislopdeskTheme.hover, DSColor.hoverFill)
        // Explicit white-opacity equivalents (the values the tokens hold).
        XCTAssertEqual(AislopdeskTheme.surface05, Color.white.opacity(0.05))
        XCTAssertEqual(AislopdeskTheme.surface, Color.white.opacity(0.08))
        XCTAssertEqual(AislopdeskTheme.border, Color.white.opacity(0.07))
    }

    func testThemeAccentLadderRepointedToDSIndigo() {
        // No DSThemeStore override active (the P1 default): accentSolid resolves to the DS indigo a9.
        XCTAssertNil(DSThemeStore.shared.accent, "no accent override → accentSolid is the DS indigo default")
        // CONCRETE-VALUE BACKSTOP (was a tautological `accent == accentSolid`): the accent fill must be the
        // DS indigo a9 #5E6AD2. Hardcoding the hex here catches a re-author of `DSPalette.a9` to a wrong
        // value — the token-against-token line below is only a forwarding sanity check.
        XCTAssertEqual(AislopdeskTheme.accent, Color(hex: 0x5E6AD2), "accent must be the DS indigo a9 #5E6AD2")
        // The washes keep the SAME 0.10/0.25/0.40 opacities over the indigo fill.
        XCTAssertEqual(AislopdeskTheme.accentSoft, Color(hex: 0x5E6AD2).opacity(0.10))
        XCTAssertEqual(AislopdeskTheme.accentHover, Color(hex: 0x5E6AD2).opacity(0.25))
        XCTAssertEqual(AislopdeskTheme.accentSelected, Color(hex: 0x5E6AD2).opacity(0.40))
        // Forwarding sanity checks (token-followers): the accessor still routes through the DS token.
        XCTAssertEqual(AislopdeskTheme.accent, DSColor.accentSolid)
        XCTAssertEqual(AislopdeskTheme.accent, DSPalette.a9)
    }

    func testThemeStatusColorsUnchanged() {
        XCTAssertEqual(AislopdeskTheme.statusBlue, Color(red: 0.341, green: 0.757, blue: 1.0))
        XCTAssertEqual(AislopdeskTheme.statusGreen, Color(red: 0.349, green: 0.831, blue: 0.600))
        XCTAssertEqual(AislopdeskTheme.statusRed, Color(red: 1.0, green: 0.380, blue: 0.380))
        XCTAssertEqual(AislopdeskTheme.statusYellow, Color(red: 1.0, green: 0.773, blue: 0.200))
        XCTAssertEqual(AislopdeskTheme.statusGreenSoft, AislopdeskTheme.statusGreen.opacity(0.15))
    }

    // MARK: - AislopdeskTheme metrics / radius / space stay at today's values

    func testThemeMetricsUnchanged() {
        XCTAssertEqual(AislopdeskTheme.Metrics.tabHeight, 32)
        XCTAssertEqual(AislopdeskTheme.Metrics.statusBarHeight, 28)
        XCTAssertEqual(AislopdeskTheme.Metrics.dividerHit, 16)
        XCTAssertEqual(AislopdeskTheme.Metrics.sidebarMin, 200)
    }

    func testThemeRadiusUnchanged() {
        XCTAssertEqual(AislopdeskTheme.Radius.sm, 4)
        XCTAssertEqual(AislopdeskTheme.Radius.md, 6)
        XCTAssertEqual(AislopdeskTheme.Radius.lg, 8)
        XCTAssertEqual(AislopdeskTheme.Radius.xl, 10)
        XCTAssertEqual(AislopdeskTheme.Radius.pane, 8)
    }

    func testThemeSpaceUnchanged() {
        XCTAssertEqual(AislopdeskTheme.Space.xs, 2)
        XCTAssertEqual(AislopdeskTheme.Space.s, 4)
        XCTAssertEqual(AislopdeskTheme.Space.m, 6)
        XCTAssertEqual(AislopdeskTheme.Space.l, 8)
        XCTAssertEqual(AislopdeskTheme.Space.xl, 10)
        XCTAssertEqual(AislopdeskTheme.Space.xxl, 12)
        XCTAssertEqual(AislopdeskTheme.Space.paneGap, 7)
    }

    // MARK: - UIMetrics fonts / spacing / radii stay at today's values (default multiplier 1.00)

    func testUIMetricsFontsUnchanged() {
        XCTAssertEqual(UIMetrics.fontMicro, 8)
        XCTAssertEqual(UIMetrics.fontCaption, 10)
        XCTAssertEqual(UIMetrics.fontBody, 12)
        XCTAssertEqual(UIMetrics.fontEmphasis, 13)
        XCTAssertEqual(UIMetrics.fontHeadline, 14)
        XCTAssertEqual(UIMetrics.fontMega, 28)
    }

    func testUIMetricsSpacingUnchanged() {
        XCTAssertEqual(UIMetrics.spacing1, 2)
        XCTAssertEqual(UIMetrics.spacing2, 4)
        XCTAssertEqual(UIMetrics.spacing3, 6)
        XCTAssertEqual(UIMetrics.spacing4, 8)
        // The trap the spec flags: legacy spacing5 stays 10 (DSSpace.s5 is the target 12 — see below).
        XCTAssertEqual(UIMetrics.spacing5, 10)
        XCTAssertEqual(UIMetrics.spacing6, 12)
        XCTAssertEqual(UIMetrics.spacing7, 16)
        XCTAssertEqual(UIMetrics.spacing9, 24)
    }

    func testUIMetricsRadiiAndStrokeUnchanged() {
        XCTAssertEqual(UIMetrics.radiusSM, 4)
        XCTAssertEqual(UIMetrics.radiusMD, 6)
        XCTAssertEqual(UIMetrics.radiusLG, 8)
        XCTAssertEqual(UIMetrics.radiusXL, 10)
        XCTAssertEqual(UIMetrics.paneAttentionRing, 2)
        XCTAssertEqual(UIMetrics.resizeHandleHitArea, 18)
        XCTAssertEqual(UIMetrics.titleBarHeight, 32)
    }

    func testUIMetricsScaledIsValueTimesMultiplier() {
        // The one `value * multiplier` site — at the default preset (1.00) it is the identity.
        XCTAssertEqual(UIMetrics.scaled(13), 13)
        XCTAssertEqual(UIMetrics.scaled(0), 0)
    }

    // MARK: - REPOINT GUARD: legacy COLOUR accessors now DO forward to the DS tokens (P2)

    /// The single most important P2 assertion, INVERTED from the P1 `DidNotForward` pin: the legacy ink
    /// ramp NOW forwards to the new cool DS ramp (`DSColor.bg` / `DSPalette.n1`), so every `AislopdeskTheme`
    /// call site picks up the new surface at once. (P1 asserted `NotEqual` to keep the screenshot frozen;
    /// P2 makes the new ramp visible, so the correct assertion is `Equal`.)
    func testLegacyInkRampForwardsToDSTokens() {
        XCTAssertEqual(AislopdeskTheme.bg, DSColor.bg, "legacy bg now resolves to the new cool n1")
        XCTAssertEqual(AislopdeskTheme.bg, DSPalette.n1)
        XCTAssertEqual(AislopdeskTheme.bgSunken, DSColor.bgSunken)
        XCTAssertEqual(AislopdeskTheme.fg, DSColor.textPrimary)
    }

    /// The DS type / spacing TARGET values STILL differ from the legacy ones — P2 repoints COLOUR +
    /// ELEVATION only and does NOT touch `UIMetrics` geometry (that is P3/P5). The DS body font is 13pt
    /// while legacy `fontBody` stays 12pt, `DSSpace.s5` is 12 while legacy `spacing5` stays 10, and
    /// `DSSpace.tabHeight` is 30 while legacy `Metrics.tabHeight` stays 32 — proving the geometry is
    /// untouched.
    func testDSTargetValuesDifferFromLegacy() {
        XCTAssertEqual(DSFont.body.size, 13, "DS body is the target 13pt ladder base")
        XCTAssertNotEqual(DSFont.body.size, UIMetrics.fontBody, "legacy fontBody stays 12pt")
        XCTAssertEqual(DSSpace.s5, 12, "DS s5 lands on the 4pt grid (target)")
        XCTAssertNotEqual(DSSpace.s5, UIMetrics.spacing5, "legacy spacing5 stays 10")
        XCTAssertEqual(DSSpace.tabHeight, 30, "DS default-density tab height is the target 30")
        XCTAssertNotEqual(DSSpace.tabHeight, AislopdeskTheme.Metrics.tabHeight, "legacy tabHeight stays 32")
    }
    #endif
}
