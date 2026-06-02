import CoreGraphics

// MARK: - The one responsive switch (pure)

/// The single adaptation decision for the whole app (docs/22 §4): is the workspace being shown in a
/// **compact** projection (one leaf at a time, the phone carousel) or the **regular** projection (the
/// full recursive split tree)?
///
/// Pulled out of the view as a pure, synchronously-testable function so the breakpoint is pinned in
/// one place and unit-tested with zero SwiftUI. `WorkspaceRootView` computes it once from
/// `@Environment(\.horizontalSizeClass)` + the detail width and branches exactly once on the result.
public enum WorkspaceLayout {
    /// The width below which a regular layout collapses to compact when no size class is available
    /// (macOS has no `horizontalSizeClass`). This is a DETAIL-area width (the NavigationSplitView
    /// detail column), NOT the whole window: at the 720pt window floor the detail is ~500pt (720 minus
    /// the ~220 ideal sidebar), so the threshold sits a hair below that (460) — the macOS minimum
    /// window resolves REGULAR, and only a truly phone-narrow detail falls back to compact. On iOS the
    /// PRIMARY signal is `horizontalSizeClass` (the first term below), independent of this width gate.
    public static let compactWidthThreshold: CGFloat = 460

    /// Whether to use the compact projection.
    ///
    /// - Parameters:
    ///   - horizontalSizeClassCompact: `true` when `@Environment(\.horizontalSizeClass) == .compact`
    ///     (iPhone, iPad slide-over). On macOS — which has no size class — pass `false`; the width
    ///     fallback then decides.
    ///   - width: the available width of the detail area.
    /// - Returns: compact iff the size class is compact OR the width is below
    ///   ``compactWidthThreshold`` (docs/22 §4). The size class is the PRIMARY signal; the width is
    ///   the macOS / narrow-window fallback.
    public static func isCompact(horizontalSizeClassCompact: Bool, width: CGFloat) -> Bool {
        horizontalSizeClassCompact || width < compactWidthThreshold
    }
}
