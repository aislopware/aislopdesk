#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - DSShadow (a tokenized drop-shadow profile)

/// One of the TWO tokenized shadow profiles (replaces the three ad-hoc inline profiles). Shadow is used
/// ONLY at L4 (overlays/modals) — never on L2/L3 surfaces, where depth comes from the lightness ladder +
/// hairline borders. The radius/offset are scaled by ``DSScale``.
public struct DSShadow: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

// MARK: - DSElevation (LAYER 2 — the two shadow profiles + inner-highlight helpers)

/// The elevation tokens: exactly two shadow profiles plus the inner-top-edge highlight helper (the
/// premium dark-surface tell). DEFINED in P1 as forward vocabulary; NO overlay adopts them until P4.
@preconcurrency @MainActor
public enum DSElevation {
    /// L4 overlay shadow — black·0.40, radius 24, y 8 (scaled). Palette / peek / floating-pane / popover.
    public static var shadowOverlay: DSShadow {
        DSShadow(color: .black.opacity(0.40), radius: DSScale.scaled(24), y: DSScale.scaled(8))
    }

    /// Modal shadow — same colour, radius 28, y 10 (scaled). Connection gate / settings sheet.
    public static var shadowModal: DSShadow {
        DSShadow(color: .black.opacity(0.40), radius: DSScale.scaled(28), y: DSScale.scaled(10))
    }

    /// A 1pt top-aligned highlight stroke (white·0.12 → clear) — the premium dark-surface tell, currently
    /// absent everywhere. Apply as `.overlay(alignment: .top) { DSElevation.innerTopHighlight() }` on L4
    /// surfaces and floating-pane cards.
    public static func innerTopHighlight() -> some View {
        LinearGradient(
            colors: [.white.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .bottom,
        )
        .frame(height: 1)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

public extension View {
    /// Applies a ``DSShadow`` token. Forward vocabulary in P1.
    func dsShadow(_ shadow: DSShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}
#endif
