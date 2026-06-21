import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The P1 INVARIANT GUARD: every still-live legacy accessor (``AislopdeskTheme`` / ``UIMetrics``) resolves
/// to its EXACT pre-P1 value, so the screenshot is pixel-identical after the shim conversion. And the
/// PIXEL-IDENTITY guard: the legacy ink-ramp / type / spacing accessors must NOT forward to the changed DS
/// tokens (whose TARGET values differ) — `AislopdeskTheme.bg != DSColor.bg`, etc. The new vocabulary
/// exists but no legacy accessor adopts the changed value; the migration happens in P2..P5.
///
/// Uses SwiftUI `Color` `Equatable` (the existing `PaneStatusIndicatorTests` / `AgentStatusDotColorTests`
/// pattern) — a legacy literal compares equal to itself; the colour tests below reconstruct the EXACT
/// legacy constructor so a representation drift is caught.
@MainActor
final class ShimByteIdenticalTests: XCTestCase {
    #if canImport(SwiftUI)

    // MARK: - AislopdeskTheme colours stay at today's literals

    func testThemeBaseColorsUnchanged() {
        XCTAssertEqual(AislopdeskTheme.bg, Color(red: 0.086, green: 0.090, blue: 0.086))
        XCTAssertEqual(AislopdeskTheme.bgRaised, Color(red: 0.122, green: 0.122, blue: 0.118))
        XCTAssertEqual(AislopdeskTheme.bgSunken, Color(red: 0.063, green: 0.067, blue: 0.063))
        XCTAssertEqual(AislopdeskTheme.fg, Color(red: 0.918, green: 0.910, blue: 0.890))
    }

    func testThemeForegroundLadderUnchanged() {
        let fg = Color(red: 0.918, green: 0.910, blue: 0.890)
        XCTAssertEqual(AislopdeskTheme.fgPrimary, fg.opacity(0.90))
        XCTAssertEqual(AislopdeskTheme.fgMuted, fg.opacity(0.65))
        XCTAssertEqual(AislopdeskTheme.fgDim, fg.opacity(0.40))
        XCTAssertEqual(AislopdeskTheme.fgFaint, fg.opacity(0.20))
    }

    func testThemeSurfaceLadderUnchanged() {
        let fg = Color(red: 0.918, green: 0.910, blue: 0.890)
        XCTAssertEqual(AislopdeskTheme.surface05, fg.opacity(0.05))
        XCTAssertEqual(AislopdeskTheme.surface, fg.opacity(0.08))
        XCTAssertEqual(AislopdeskTheme.surface12, fg.opacity(0.12))
        XCTAssertEqual(AislopdeskTheme.border, fg.opacity(0.10))
        XCTAssertEqual(AislopdeskTheme.hover, fg.opacity(0.06))
    }

    func testThemeAccentLadderUnchanged() {
        XCTAssertEqual(AislopdeskTheme.accent, Color.accentColor)
        XCTAssertEqual(AislopdeskTheme.accentSoft, Color.accentColor.opacity(0.10))
        XCTAssertEqual(AislopdeskTheme.accentHover, Color.accentColor.opacity(0.25))
        XCTAssertEqual(AislopdeskTheme.accentSelected, Color.accentColor.opacity(0.40))
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

    // MARK: - PIXEL-IDENTITY GUARD: legacy accessors do NOT forward to the changed DS tokens

    /// The single most important assertion: the legacy `bg` must NOT have been pointed at the new cool
    /// ramp (`DSColor.bg` / `DSPalette.n1`). If it had, the window background would shift — a visible
    /// change P1 forbids. (`Color(red:0.086…)` warm near-black vs `#121316` cool — different by design.)
    func testLegacyInkRampDidNotForwardToDSTokens() {
        XCTAssertNotEqual(AislopdeskTheme.bg, DSColor.bg, "legacy bg must keep its warm literal, not n1")
        XCTAssertNotEqual(AislopdeskTheme.bg, DSPalette.n1)
        XCTAssertNotEqual(AislopdeskTheme.bgSunken, DSColor.bgSunken)
        XCTAssertNotEqual(AislopdeskTheme.fg, DSColor.textPrimary)
    }

    /// The DS type / spacing TARGET values differ from the legacy ones (they are forward vocabulary): the
    /// DS body font is 13pt while legacy `fontBody` is 12pt, and `DSSpace.s5` is 12 while legacy
    /// `spacing5` stays 10 — proving the shim did NOT collapse the values together.
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
