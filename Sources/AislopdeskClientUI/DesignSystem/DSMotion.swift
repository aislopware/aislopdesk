#if canImport(SwiftUI)
import SwiftUI

// MARK: - DSMotion (LAYER 2 — tokenized animation curves)

/// The tokenized motion vocabulary (replaces every inline ad-hoc `.animation(.easeInOut)` duration).
/// RULE: never use bare `.default`/`.easeInOut` — they interpolate through cheap-looking intermediate
/// states on near-black. DEFINED in P1 as forward vocabulary; adopted by the transitions in P5.
public enum DSMotion {
    /// hover / press background + foreground
    public static let hover: Animation = .easeOut(duration: 0.13)
    /// tab / pane / sidebar selection + focus-ring color/width (slight overshoot reads premium on dark)
    public static let select: Animation = .spring(response: 0.22, dampingFraction: 0.82)
    /// palette / peek / overlay appear (opacity + 4pt translateY-up)
    public static let appear: Animation = .easeOut(duration: 0.16)
    /// overlay dismiss
    public static let dismiss: Animation = .easeIn(duration: 0.10)
    /// sidebar collapse/expand, tab-padding compact transition
    public static let layout: Animation = .spring(response: 0.20, dampingFraction: 0.9)
    /// P3 blocked-pane attention-ring pulse
    public static let attention: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// The Reduce-Motion fallback: a near-instant (0.001s) crossfade that swaps state without the spring /
    /// translate. Gate spring/translate behind `@Environment(\.accessibilityReduceMotion)` and use this in
    /// the reduced branch.
    public static let reducedCrossfade: Animation = .easeInOut(duration: 0.001)

    /// Resolves a motion token against Reduce-Motion: returns the near-instant crossfade when
    /// `reduceMotion` is on, else the supplied animation. Centralises the spec rule so every adopting site
    /// is consistent.
    public static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedCrossfade : animation
    }
}
#endif
