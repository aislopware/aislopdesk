import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Headless proof of the P3b chrome restructure's PURE view-model transforms — the row-state → style
/// mapping (sidebar), the RTT telemetry format + colour (status bar), and the seam colour (divider). These
/// are the load-bearing decisions (selected-beats-hover, identity-vs-telemetry hierarchy, discoverable
/// seam) extracted so they are testable without driving SwiftUI layout (no NSWindow / Ghostty / SCStream /
/// VT / Metal is instantiated).
#if canImport(SwiftUI)
@MainActor
final class P3bChromeTransformTests: XCTestCase {
    // MARK: - SessionRow.rowVisual / rowFill (the "selected clearly BEATS hovered" fix)

    /// An active row resolves to `.active` regardless of hover — selection takes precedence over hover so a
    /// selected row never downgrades to the hover plate while the pointer is over it.
    func testActiveTakesPrecedenceOverHover() {
        XCTAssertEqual(SessionRow.rowVisual(isActive: true, isHovered: false), .active)
        XCTAssertEqual(SessionRow.rowVisual(isActive: true, isHovered: true), .active)
    }

    /// A non-active hovered row resolves to `.hovered`; a non-active non-hovered row to `.idle`.
    func testHoverAndIdleResolution() {
        XCTAssertEqual(SessionRow.rowVisual(isActive: false, isHovered: true), .hovered)
        XCTAssertEqual(SessionRow.rowVisual(isActive: false, isHovered: false), .idle)
    }

    /// THE CORE P3b FIX (revert-to-confirm-fail): the active fill is `selectionWash` (accent·0.18) and the
    /// hover fill is `hoverFill` (white·0.05) — they MUST be different colours so "selected" visibly beats
    /// "hovered". The old code mapped active→accentSoft (accent·0.10) ≈ hover, the bug this restructure
    /// fixes. If a refactor re-points active back to a near-hover wash, the inequality below fails.
    func testSelectedFillClearlyBeatsHoverFill() {
        let active = SessionRow.rowFill(.active)
        let hovered = SessionRow.rowFill(.hovered)
        XCTAssertEqual(active, DSColor.selectionWash)
        XCTAssertEqual(hovered, DSColor.hoverFill)
        XCTAssertNotEqual(active, hovered, "selected (selectionWash) must visibly differ from hovered (hoverFill)")
    }

    /// Selection is ADDITIVE, never subtractive: an idle row's fill is `.clear` (it is NOT dimmed relative to
    /// its peers). The selected row is shown by the wash + the accent bar being ADDED, not by reducing the
    /// others.
    func testIdleRowIsClearNotDimmed() {
        XCTAssertEqual(SessionRow.rowFill(.idle), Color.clear)
    }

    /// The three fills are mutually distinct, so the hierarchy "selected > hovered > idle" holds even if the
    /// underlying token VALUES are later re-pointed (catches a spec drift the literal assertions move in
    /// lockstep with).
    func testRowFillsAreMutuallyDistinct() {
        let active = SessionRow.rowFill(.active)
        let hovered = SessionRow.rowFill(.hovered)
        let idle = SessionRow.rowFill(.idle)
        XCTAssertNotEqual(active, hovered)
        XCTAssertNotEqual(active, idle)
        XCTAssertNotEqual(hovered, idle)
        XCTAssertEqual(idle, Color.clear, "idle is no fill at all (never a dim)")
    }

    // MARK: - PaneStatusBar.rttLabel / rttColor (telemetry format + colour)

    /// Sub-millisecond pings show "<1ms"; everything else rounds to an integer + "ms". The boundary is at
    /// exactly 1 (`< 1` is "<1ms"; `1.0` rounds to "1ms").
    func testRttLabelFormatting() {
        XCTAssertEqual(PaneStatusBar.rttLabel(0), "<1ms")
        XCTAssertEqual(PaneStatusBar.rttLabel(0.4), "<1ms")
        XCTAssertEqual(PaneStatusBar.rttLabel(1), "1ms")
        XCTAssertEqual(PaneStatusBar.rttLabel(28.4), "28ms")
        XCTAssertEqual(PaneStatusBar.rttLabel(28.6), "29ms")
        XCTAssertEqual(PaneStatusBar.rttLabel(150), "150ms")
    }

    /// A TOTAL formatter must not be able to crash the GUI on one bad sample: a non-finite `ms` maps to the
    /// em-dash placeholder, NOT a trap. Revert-to-confirm-fail: the pre-fix `ms < 1 ? … : "\(Int(ms.rounded()))ms"`
    /// took the else branch for NaN (`NaN < 1 == false`) and trapped in `Int(Double.nan.rounded())`; ±inf
    /// overflows `Int` and also trapped. The guard makes all three boundary doubles total.
    func testRttLabelNonFinite() {
        XCTAssertEqual(PaneStatusBar.rttLabel(.nan), "—")
        XCTAssertEqual(PaneStatusBar.rttLabel(.infinity), "—")
        XCTAssertEqual(PaneStatusBar.rttLabel(-.infinity), "—")
    }

    /// RTT colour: past the 100ms "this will feel laggy" line ⇒ amber (statusYellow); under ⇒ the
    /// subordinate textTertiary (NOT the old fgDim). The two cases must be different colours so the amber
    /// warning is distinguishable from the ok state.
    func testRttColorThreshold() {
        XCTAssertEqual(PaneStatusBar.rttColor(overThreshold: true), DSColor.statusYellow)
        XCTAssertEqual(PaneStatusBar.rttColor(overThreshold: false), DSColor.textTertiary)
        XCTAssertNotEqual(
            PaneStatusBar.rttColor(overThreshold: true),
            PaneStatusBar.rttColor(overThreshold: false),
            "the amber laggy warning must visibly differ from the ok telemetry colour",
        )
    }

    // MARK: - Status-bar hierarchy (identity HEADING vs telemetry SUBORDINATE)

    /// The status-bar hierarchy is real: the LEFT identity heading rests at `textSecondary`, the RIGHT
    /// telemetry at `textTertiary` — DIFFERENT text tokens, so identity reads heavier than telemetry. (The
    /// ok-RTT case is the telemetry colour; assert it differs from the identity colour.)
    func testIdentityHeadingDiffersFromTelemetry() {
        let identity = DSColor.textSecondary
        let telemetry = PaneStatusBar.rttColor(overThreshold: false) // textTertiary
        XCTAssertEqual(telemetry, DSColor.textTertiary)
        XCTAssertNotEqual(
            identity,
            telemetry,
            "identity (textSecondary) must read heavier than telemetry (textTertiary)",
        )
    }

    // MARK: - DividerHandleView.lineColor (discoverable-but-recessive seam)

    /// The divider seam: at REST it is `borderComponent` (white·0.11 — discoverable over the gutter, vs the
    /// old invisible white·0.07); hover/drag washes to `focusRing` (accent). The two states differ so the
    /// seam announces itself on hover.
    func testDividerLineColorStates() {
        XCTAssertEqual(DividerHandleView.lineColor(active: false), DSColor.borderComponent)
        XCTAssertEqual(DividerHandleView.lineColor(active: true), DSColor.focusRing)
        XCTAssertNotEqual(
            DividerHandleView.lineColor(active: false),
            DividerHandleView.lineColor(active: true),
            "the at-rest seam must visibly differ from the active (accent) seam",
        )
    }

    /// The at-rest divider seam is the COMPONENT border (white·0.11), NOT the subtle border (white·0.07) the
    /// legacy `AislopdeskTheme.border` used — that is the "can't find the seam" fix. Revert-to-confirm-fail:
    /// if the at-rest colour regressed to `borderSubtle`, this fails.
    func testDividerAtRestUsesComponentBorderNotSubtle() {
        XCTAssertEqual(DividerHandleView.lineColor(active: false), DSColor.borderComponent)
        XCTAssertNotEqual(DividerHandleView.lineColor(active: false), DSColor.borderSubtle)
    }

    // MARK: - SessionSidebarView.sectionHeaderFont (readable section eyebrow)

    /// The section-header token is 10pt SEMIBOLD with +0.4 tracking — the readable eyebrow that replaces the
    /// unreadable `fgFaint`·0.20. Semibold (not the medium of `DSFont.caption`) + the wider 0.4 tracking are
    /// the load-bearing emphasis.
    func testSectionHeaderFontIsSemiboldWithTracking() {
        let f = SessionSidebarView.sectionHeaderFont
        XCTAssertEqual(f.size, 10)
        XCTAssertEqual(f.weight, .semibold)
        XCTAssertEqual(f.tracking, 0.4)
        // It is a STRONGER twin of caption (which is .medium / +0.1) — assert it out-weighs caption.
        XCTAssertNotEqual(f.weight, DSFont.caption.weight, "section header must be heavier than DSFont.caption")
    }
}
#endif
