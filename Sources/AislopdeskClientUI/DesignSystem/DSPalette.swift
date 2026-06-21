#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Color(hex:) helper (validate-then-clamp, no trap)

public extension Color {
    /// Builds an sRGB `Color` from a packed `0xRRGGBB` integer. The high byte is masked off (so a stray
    /// alpha byte cannot shift the channels), each channel is `/ 255` into `0...1`, and `opacity` rides
    /// through. Pure value math — NO force-unwrap, NO trap on any input (`UInt32` cannot overflow the
    /// masks). Always `.sRGB` so the DS ink/accent ramps are authored in one fixed, predictable space.
    ///
    /// CONVENTION: every divide is a plain `/` on a `Double`; there is no `a*b+c` to fuse, so the FMA rule
    /// is moot here.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        // Clamp opacity into the valid alpha range with NaN-faithful ordered min/max (project convention:
        // never a bare `<`/`>` ternary, which has the wrong NaN behaviour).
        let a = Double.minimum(1, Double.maximum(0, opacity))
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - DSPalette (LAYER 1 — primitive ramps; never imported by views)

/// The primitive colour ramps for the design system: OKLCH-derived sRGB hex, authored once. NOT
/// `@MainActor` (pure static `let`s) so the AppKit mirrors are reachable from ``WindowConfigurator``
/// without an actor hop. Views NEVER import this — they read ``DSColor`` role tokens.
///
/// P1 STATUS: these hold the TARGET spec values (the new cool ink ramp + indigo accent). They are
/// referenced by ``DSColor`` (also target-only in P1). The STATUS literals reuse today's exact hexes so
/// the legacy status accessors could forward — but to dodge the `Color(hex:)`-vs-`Color(red:green:blue:)`
/// equality trap, the legacy ``AislopdeskTheme`` status accessors KEEP their own `Color(red:…)` literals
/// and these are an independent (numerically-equal) copy. See `ShimByteIdenticalTests`.
public enum DSPalette {
    // MARK: Neutral ink ramp (12 steps, cool hue 250, near-black floor — never pure #000)

    /// canvas floor / sunken gutter
    public static let n0 = Color(hex: 0x0C0D0F)
    /// window bg
    public static let n1 = Color(hex: 0x121316)
    /// pane content bg
    public static let n2 = Color(hex: 0x17181C)
    /// chrome / sidebar / raised panel
    public static let n3 = Color(hex: 0x1D1F24)
    /// hover fill
    public static let n4 = Color(hex: 0x24262C)
    /// active/pressed fill, overlay bg
    public static let n5 = Color(hex: 0x2B2E35)
    /// subtle border / divider
    public static let n6 = Color(hex: 0x34373F)
    /// component border
    public static let n7 = Color(hex: 0x3E424B)
    /// strong border / input edge
    public static let n8 = Color(hex: 0x4C515B)
    /// disabled glyph
    public static let n9 = Color(hex: 0x6B7280)
    /// tertiary text
    public static let n10 = Color(hex: 0x9AA0AB)
    /// secondary text
    public static let n11 = Color(hex: 0xC3C7CE)
    /// primary text (off-white, NOT #FFF)
    public static let n12 = Color(hex: 0xECEEF1)

    // MARK: Accent ramp (tuned indigo-blue, oklch 0.62 0.16 256)

    public static let a7 = Color(hex: 0x3A4FB0)
    public static let a8 = Color(hex: 0x455DC8)
    /// solid — focus ring, primary fill (the DS default accent)
    public static let a9 = Color(hex: 0x5E6AD2)
    /// hover
    public static let a10 = Color(hex: 0x6E7AE0)
    /// accent text on dark
    public static let a11 = Color(hex: 0x9EB1FF)

    // MARK: Status (fixed-hue, theme-independent — numerically equal to today's literals)

    public static let statusBlue = Color(hex: 0x57C1FF)
    public static let statusGreen = Color(hex: 0x59D499)
    public static let statusRed = Color(hex: 0xFF6161)
    public static let statusYellow = Color(hex: 0xFFC533)
    /// Soft `.15` fill twins for status plates / wash backgrounds.
    public static let statusBlueSoft = statusBlue.opacity(0.15)
    public static let statusGreenSoft = statusGreen.opacity(0.15)
    public static let statusRedSoft = statusRed.opacity(0.15)
    public static let statusYellowSoft = statusYellow.opacity(0.15)

    // MARK: Pane radius placeholder (cross-module micro-module DEFERRED to P2)

    /// The per-pane card radius as a raw `CGFloat`. P2 exposes this through a tiny dependency-free
    /// `AislopdeskDSConstants` module that BOTH AislopdeskClientUI and ThirdParty/ghostty import, killing
    /// the copy-pasted `8` in the Ghostty layer. P1 just records the value here (no cross-module target,
    /// no `Package.swift` edit — that touches the Xcode app target which `swift build` cannot verify).
    public static let paneRadiusRaw: CGFloat = 8

    // MARK: AppKit mirrors (target-only in P1; unused — WindowConfigurator still reads the legacy nsBg)

    #if canImport(AppKit)
    /// AppKit mirrors of the ink ramp for ``WindowConfigurator`` / the Ghostty layer (P2+).
    public static let nsN0 = NSColor(srgbRed: 0x0C / 255, green: 0x0D / 255, blue: 0x0F / 255, alpha: 1)
    public static let nsN1 = NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x16 / 255, alpha: 1)
    public static let nsN2 = NSColor(srgbRed: 0x17 / 255, green: 0x18 / 255, blue: 0x1C / 255, alpha: 1)
    public static let nsN3 = NSColor(srgbRed: 0x1D / 255, green: 0x1F / 255, blue: 0x24 / 255, alpha: 1)
    public static let nsN12 = NSColor(srgbRed: 0xEC / 255, green: 0xEE / 255, blue: 0xF1 / 255, alpha: 1)

    /// Returns black or white — whichever reads against `color` — using the sRGB relative luminance
    /// (0.2126·r + 0.7152·g + 0.0722·b), threshold 0.6. This is the SINGLE contrast helper; the legacy
    /// ``AislopdeskTheme.contrastingForeground(for:)`` forwards to it (target == today: same threshold,
    /// same separated products).
    ///
    /// CONVENTION: the three luminance products stay SEPARATE `*` then `+` — never fused to
    /// `addingProduct`/`fma` (FMA keeps extra precision and would diverge from the legacy result).
    public static func contrastingForeground(for color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
    #endif
}
#endif
