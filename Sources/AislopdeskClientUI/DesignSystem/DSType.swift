#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - DSFont (LAYER 2 — a typography token: size + weight + design + leading + tracking)

/// A typography token carrying everything a label needs (size, weight, SF/mono design, line height,
/// tracking) so call sites stop re-inventing `.font(.system(size:weight:design:))` by hand. The `size` is
/// scaled by ``DSScale`` at read time. Apply via the `.dsFont(_:)` ViewModifier (which also sets tracking
/// + line spacing) so the whole token lands, not just the size.
///
/// P1 STATUS: the 13pt Minor-Third ladder holds its TARGET spec sizes. NO view adopts `.dsFont(_:)` in P1
/// — the legacy ``UIMetrics`` font sizes stay live (12pt body, etc.). The ladder is forward vocabulary.
public struct DSFont: Sendable {
    public let size: CGFloat
    public let weight: Font.Weight
    public let design: Font.Design
    /// Target line height (snaps to the 4pt grid). Used by `.dsFont` to derive `.lineSpacing`.
    public let leading: CGFloat
    /// Letter-spacing in points (negative tracking only kicks in ≥16pt per spec).
    public let tracking: CGFloat

    public init(
        _ size: CGFloat,
        _ weight: Font.Weight,
        _ design: Font.Design,
        leading: CGFloat,
        tracking: CGFloat = 0,
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.leading = leading
        self.tracking = tracking
    }

    /// The scaled SwiftUI `Font`. Scaling is a single `*` inside ``DSScale.scaled`` — no FMA.
    @MainActor
    public var font: Font {
        .system(size: DSScale.scaled(size), weight: weight, design: design)
    }

    // MARK: The 13pt Minor-Third ladder (target spec sizes)

    /// micro telemetry, kbd hints — 9pt regular SF, lh12, +0.2
    public static let caption2 = Self(9, .regular, .default, leading: 12, tracking: 0.2)
    /// status bar, section eyebrow — 10pt medium SF, lh14, +0.1
    public static let caption = Self(10, .medium, .default, leading: 14, tracking: 0.1)
    /// sub-labels, badges — 11pt regular SF, lh16
    public static let footnote = Self(11, .regular, .default, leading: 16)
    /// THE base — tab titles, sidebar rows, palette rows — 13pt regular SF, lh16
    public static let body = Self(13, .regular, .default, leading: 16)
    /// pane header path, command names — 13pt regular mono, lh16
    public static let bodyMono = Self(13, .regular, .monospaced, leading: 16)
    /// active tab title, sidebar active row — 13pt semibold SF, lh16
    public static let emphasis = Self(13, .semibold, .default, leading: 16)
    /// palette search field, settings labels — 16pt regular SF, lh20, -0.1
    public static let subhead = Self(16, .regular, .default, leading: 20, tracking: -0.1)
    /// 19pt semibold SF Text, lh24, -0.2
    public static let title3 = Self(19, .semibold, .default, leading: 24, tracking: -0.2)
    /// empty-state, connection gate — 23pt semibold SF Display, lh28, -0.4
    public static let title2 = Self(23, .semibold, .default, leading: 28, tracking: -0.4)
    /// hero / onboarding only — 28pt bold SF Display, lh34, -0.6
    public static let title1 = Self(28, .bold, .default, leading: 34, tracking: -0.6)
}

// MARK: - dsFont ViewModifier (reads @Environment(DSScale.self) — the tracked repaint path)

/// Applies a ``DSFont`` token's font + tracking + line spacing. It declares
/// `@Environment(DSScale.self) private var scale` so SwiftUI records the density dependency — when
/// `DSScale.shared.multiplier` changes (a future P5 density flip), every `.dsFont(_:)` view repaints.
/// This is the live-scale wiring that ``UIMetrics`` (static-var reads of `UIScale.shared`) can never get.
@preconcurrency @MainActor
public struct DSFontModifier: ViewModifier {
    // OPTIONAL form (`DSScale?`) — returns nil instead of TRAPPING when this modifier renders outside the
    // injected scope (e.g. the pre-connect ConnectionGateView, a sheet, or a detached NSHostingView that
    // does not inherit WorkspaceRootView's `.environment(DSScale.shared)`). When nil we fall back to the
    // single shared instance (the bridged source DSScale.scaled already reads), so scaling stays correct;
    // we only lose the live-repaint dependency in that unscoped context, which is acceptable.
    @Environment(DSScale.self) private var scale: DSScale?
    let token: DSFont

    public func body(content: Content) -> some View {
        // Read `scale?.multiplier` so the @Environment dependency is recorded WHEN injected — referencing the
        // injected instance is what SwiftUI tracks for the live repaint. Then route ALL scaling through the
        // SINGLE `DSScale.scaled` path (the same route as `DSFont.font`) so there is exactly one scaling
        // formula and the two cannot drift in a later phase. (DSScale.scaled reads `shared.multiplier`, which
        // equals the injected `scale.multiplier` we just observed — same value, one route.)
        _ = scale?.multiplier
        return content
            .font(token.font)
            .tracking(token.tracking)
            // lineSpacing is the GAP added between lines; derive it from leading − size, floored at 0 with
            // an ordered max (never a bare `<`/`>` ternary — NaN-faithful per project convention). Scale the
            // gap through the same `DSScale.scaled` route so it tracks density with the font.
            .lineSpacing(Double.maximum(0, DSScale.scaled(token.leading - token.size)))
    }
}

public extension View {
    /// Applies a ``DSFont`` token (font + tracking + line spacing) via an `@Environment(DSScale.self)`-
    /// reading modifier, so the text repaints on a live density change. Forward vocabulary in P1.
    @MainActor
    func dsFont(_ token: DSFont) -> some View {
        modifier(DSFontModifier(token: token))
    }
}
#endif
