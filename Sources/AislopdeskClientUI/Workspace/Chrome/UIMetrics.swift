// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

/// The chrome's design-token scale (Muxy `UIMetrics`). Every token is a computed value = its base point
/// size times `UIScale.shared.multiplier`, so a single density preset rescales fonts, spacing, icons,
/// controls, radii and layout in lockstep. Read tokens directly (`UIMetrics.fontBody`, `.spacing4`).
@preconcurrency @MainActor
public enum UIMetrics {
    // MARK: Fonts

    public static var fontMicro: CGFloat { scaled(8) }
    public static var fontXS: CGFloat { scaled(9) }
    public static var fontCaption: CGFloat { scaled(10) }
    public static var fontFootnote: CGFloat { scaled(11) }
    public static var fontBody: CGFloat { scaled(12) }
    public static var fontEmphasis: CGFloat { scaled(13) }
    public static var fontHeadline: CGFloat { scaled(14) }
    public static var fontTitle: CGFloat { scaled(15) }
    public static var fontTitleLarge: CGFloat { scaled(16) }
    public static var fontDisplay: CGFloat { scaled(20) }
    public static var fontHero: CGFloat { scaled(24) }
    public static var fontMega: CGFloat { scaled(28) }

    // MARK: Spacing

    public static var spacing1: CGFloat { scaled(2) }
    public static var spacing2: CGFloat { scaled(4) }
    public static var spacing3: CGFloat { scaled(6) }
    public static var spacing4: CGFloat { scaled(8) }
    public static var spacing5: CGFloat { scaled(10) }
    public static var spacing6: CGFloat { scaled(12) }
    public static var spacing7: CGFloat { scaled(16) }
    public static var spacing8: CGFloat { scaled(20) }
    public static var spacing9: CGFloat { scaled(24) }
    public static var spacing10: CGFloat { scaled(32) }

    // MARK: Icons

    public static var iconXS: CGFloat { scaled(10) }
    public static var iconSM: CGFloat { scaled(12) }
    public static var iconMD: CGFloat { scaled(14) }
    public static var iconLG: CGFloat { scaled(16) }
    public static var iconXL: CGFloat { scaled(20) }
    public static var iconXXL: CGFloat { scaled(28) }

    // MARK: Controls

    public static var controlSmall: CGFloat { scaled(20) }
    public static var controlMedium: CGFloat { scaled(24) }
    public static var controlLarge: CGFloat { scaled(32) }
    public static var resizeHandleHitArea: CGFloat { scaled(18) }

    // MARK: Radii

    public static var radiusSM: CGFloat { scaled(4) }
    public static var radiusMD: CGFloat { scaled(6) }
    public static var radiusLG: CGFloat { scaled(8) }
    public static var radiusXL: CGFloat { scaled(10) }

    // MARK: Layout

    public static var sidebarCollapsedWidth: CGFloat { scaled(44) }
    public static var sidebarExpandedWidth: CGFloat { scaled(220) }
    public static var sidebarExpandedMinWidth: CGFloat { scaled(180) }
    public static var sidebarExpandedMaxWidth: CGFloat { scaled(480) }
    public static var tabBarHeight: CGFloat { scaled(28) }
    public static var headerHeight: CGFloat { scaled(36) }
    public static var titleBarHeight: CGFloat { scaled(32) }

    /// Multiplies a base point value by the active UI-scale preset's multiplier.
    public static func scaled(_ value: CGFloat) -> CGFloat {
        value * UIScale.shared.multiplier
    }
}
#endif
