// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AislopdeskTheme (the Muxy-faithful chrome palette + metrics)

/// The coding-IDE chrome design tokens, COPIED from Muxy (`muxy-app/muxy` — SwiftUI + libghostty), not
/// re-invented. Muxy derives its whole UI palette from the active terminal theme's background/foreground
/// and paints the chrome in solid theme colors (NO system materials / vibrancy / `colorScheme`), so the
/// window reads as ONE surface with the terminal instead of a stock `NavigationSplitView` app. We mirror
/// that: a dark base (matching the libghostty default dark theme) with every accent/separator/surface
/// token derived as a foreground opacity, exactly like Muxy's `MuxyTheme`.
///
/// All values are static (Muxy's `MuxyTheme` / `UIMetrics` are static too) so any chrome view reads
/// `AislopdeskTheme.surface` / `.border` / `.metrics.tabHeight` without threading an environment object.
enum AislopdeskTheme {
    // MARK: Base (the two colors everything else derives from)

    /// The window/chrome background — a deep, very slightly warm dark (Muxy: `bg` = terminal background
    /// color). Nudged from pure neutral #161820 toward a warmer near-black (~#161716) so it pairs with
    /// the warmer off-white fg without the cool-vs-warm clash.
    static let bg = Color(red: 0.086, green: 0.090, blue: 0.086) // ~#161716 (warm near-black)

    /// A slightly raised opaque surface for overlays / popovers that need a hard background (Muxy: a
    /// hair lighter than `bg`; use `surface` / `surface12` for translucent overlays in the chrome).
    static let bgRaised = Color(red: 0.122, green: 0.122, blue: 0.118) // ~#1F1F1E (warm raised)

    /// The DEEPEST elevation level — one subtle step BELOW `bg` (~2% luminance). Used as the gutter
    /// "canvas behind cards": the SplitTreeView seam + the outer half-gap padding paint this so the
    /// `bg` panes read as raised cards floating on a sunken floor. The 3-step ladder is
    /// `bgRaised` (sidebar) > `bg` (pane card) > `bgSunken` (gutter) — present but deliberately subtle.
    static let bgSunken = Color(red: 0.063, green: 0.067, blue: 0.063) // ~#101110 (gutter behind panes)

    /// The foreground (text/icon) base — a warm off-white (Muxy: `fg` = terminal foreground color).
    /// Warmed slightly toward Warp Phenomenon's #FAF9F6 for a richer reading tone while staying
    /// cohesive with the dark chrome (was #E2E5EC, now #EAE8E3).
    static let fg = Color(red: 0.918, green: 0.910, blue: 0.890) // ~#EAE8E3 (warm off-white)

    // MARK: Derived foreground tokens (fg-opacity text ladder + surface/border ladder)

    /// Primary text — main labels, active tab titles (fg @ 90% so it reads as warm off-white rather
    /// than harsh full-white; identical in practice to `fg` itself for most uses).
    static let fgPrimary = fg.opacity(0.90)
    /// Secondary text — labels, inactive tab titles (Muxy `fgMuted` = fg · 0.65).
    static let fgMuted = fg.opacity(0.65)
    /// Tertiary text / dim icons — close glyphs, counts (Muxy `fgDim` = fg · 0.40).
    static let fgDim = fg.opacity(0.40)
    /// Placeholder / disabled text — hint strings, fully disabled controls (fg · 0.20).
    static let fgFaint = fg.opacity(0.20)

    // MARK: Surface ladder (fg blended over bg at increasing opacity)

    /// The lightest raised surface — hover / subtle fill (fg · 0.05).
    static let surface05 = fg.opacity(0.05)
    /// Active-tab / selected-row fill (Muxy `surface` = fg · 0.08).
    static let surface = fg.opacity(0.08)
    /// A slightly stronger surface — focused input / active sidebar row (fg · 0.12).
    static let surface12 = fg.opacity(0.12)
    /// Every divider / separator / hairline border — soft 1px lines (fg · 0.10).
    static let border = fg.opacity(0.10)
    /// Row hover background (Muxy `hover` = fg · 0.06 ≈ surface05 split for clarity).
    static let hover = fg.opacity(0.06)

    // MARK: Accent + accent-overlay ladder

    /// The focus / active accent. Muxy uses the terminal theme's accent (typically blue); we use the
    /// user's system accent so it tracks their preference, which reads the same way (Muxy: the active
    /// theme's accent; ours = `NSColor.controlAccentColor` surfaced as `Color.accentColor`).
    ///
    /// PALETTE DECISION: keeping `Color.accentColor` (system) rather than a fixed steel-blue
    /// (#2E5D9E). The system accent ensures the chrome respects the user's macOS preference, which
    /// typically IS a near-Warp-steel blue by default while still adapting to e.g. graphite mode.
    static let accent = Color.accentColor
    /// A soft accent wash — hover / light fill (accent · 0.10).
    static let accentSoft = Color.accentColor.opacity(0.10)
    /// A medium accent wash — hover-active / focused interactive rows (accent · 0.25).
    static let accentHover = Color.accentColor.opacity(0.25)
    /// A strong accent wash — selected / active state tint (accent · 0.40).
    static let accentSelected = Color.accentColor.opacity(0.40)
    /// A contrasting foreground for text/glyphs painted ON the accent fill — black on a light accent,
    /// white on a dark one (Muxy `accentForeground` = `contrastingForeground(for: accent)`, threshold 0.6).
    /// Our base accent is the system accent, so this is derived from `NSColor.controlAccentColor` on
    /// macOS and falls back to white where AppKit is unavailable.
    static let accentForeground: Color = {
        #if canImport(AppKit)
        return Color(nsColor: contrastingForeground(for: NSColor.controlAccentColor))
        #else
        return .white
        #endif
    }()

    // MARK: Semantic status accents (state colours — NOT the interactive accent)

    /// Saturated, FIXED-hue status colours (sRGB literals, NOT system colours) so they read identically
    /// regardless of the user's macOS accent or appearance. The chrome reserves `accent` for the active
    /// /focus signal; these four carry SEMANTIC state — connection / agent / telemetry health — so a
    /// "working" or "down" cue never collides with the user's accent. Each has a soft `.opacity(0.15)`
    /// fill twin for plate backgrounds.
    static let statusBlue = Color(red: 0.341, green: 0.757, blue: 1.0) // #57C1FF (active / in-flight)
    static let statusGreen = Color(red: 0.349, green: 0.831, blue: 0.600) // #59D499 (ok / done)
    static let statusRed = Color(red: 1.0, green: 0.380, blue: 0.380) // #FF6161 (down / blocked)
    static let statusYellow = Color(red: 1.0, green: 0.773, blue: 0.200) // #FFC533 (degraded / caution)
    /// Soft `.15` fill twins for status plates / wash backgrounds.
    static let statusBlueSoft = statusBlue.opacity(0.15)
    static let statusGreenSoft = statusGreen.opacity(0.15)
    static let statusRedSoft = statusRed.opacity(0.15)
    static let statusYellowSoft = statusYellow.opacity(0.15)

    /// A warning / caution tint (Muxy `warning` = the active theme's bright-yellow palette slot, falling
    /// back to `systemYellow`). We use `systemYellow` directly per the contract.
    static let warning = Color(.systemYellow)

    // MARK: AppKit color tokens (Muxy `nsBg` / `nsFg` / `nsFgMuted`)

    #if canImport(AppKit)
    /// The chrome background as an `NSColor` for AppKit views (matches `bg` warm near-black).
    static let nsBg = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.086, alpha: 1.0) // ~#161716
    /// The foreground as an `NSColor` for AppKit views (matches `fg` warm off-white).
    static let nsFg = NSColor(srgbRed: 0.918, green: 0.910, blue: 0.890, alpha: 1.0) // ~#EAE8E3
    /// Secondary foreground as an `NSColor` (fg · 0.65 — matches `fgMuted`).
    static let nsFgMuted = nsFg.withAlphaComponent(0.65)
    /// The sunken gutter as an `NSColor` for AppKit views (matches `bgSunken` ~#101110).
    static let nsBgSunken = NSColor(srgbRed: 0.063, green: 0.067, blue: 0.063, alpha: 1.0) // ~#101110
    #endif

    // MARK: Color scheme

    /// The chrome's effective appearance. Muxy derives this from the background luminance (light if
    /// luminance > 0.5, else dark); our base `bg` (#161820) is deeply dark, so this is `.dark`.
    static let colorScheme: ColorScheme = .dark

    // MARK: Contrast helper (Muxy `Snapshot.contrastingForeground(for:)`)

    #if canImport(AppKit)
    /// Returns black or white — whichever reads against `color` — using the sRGB relative luminance
    /// (0.2126·r + 0.7152·g + 0.0722·b), with Muxy's 0.6 threshold. Used to pick `accentForeground`.
    static func contrastingForeground(for color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
    #endif

    // MARK: Metrics (Muxy `UIMetrics`)

    enum Metrics {
        /// The titlebar / tab-strip row height (Muxy `titleBarHeight = 32`).
        static let tabHeight: CGFloat = 32
        /// The bottom status-bar height (Muxy `statusBarHeight = 28`).
        static let statusBarHeight: CGFloat = 28
        /// Width reserved at the sidebar's top-left for the macOS traffic lights so chrome never overlaps
        /// them under the hidden titlebar (Muxy `trafficLightWidth = 75`).
        static let trafficLightInset: CGFloat = 28
        /// The sidebar column widths (Muxy collapsed 44 / expanded 220, min 180 / max 480).
        static let sidebarMin: CGFloat = 200
        static let sidebarIdeal: CGFloat = 240
        static let sidebarMax: CGFloat = 360
        /// The split-divider grab band — invisible-ish 1pt line, generous hit area (Muxy hit area 18pt).
        static let dividerHit: CGFloat = 16
    }

    // MARK: Corner radii (Muxy radiusSM/MD/LG/XL)

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 10
        /// The per-pane rounded-card radius (Warp "floating cards" look — 8pt continuous).
        /// Every pane leaf uses this so a single change propagates everywhere.
        static let pane: CGFloat = 8
    }

    // MARK: Spacing scale (Muxy spacing1…8)

    enum Space {
        static let xs: CGFloat = 2
        static let s: CGFloat = 4
        static let m: CGFloat = 6
        static let l: CGFloat = 8
        static let xl: CGFloat = 10
        static let xxl: CGFloat = 12
        /// Half-gap between adjacent split panes (the other half comes from the sibling).  Together
        /// they produce a `paneGap`-pt visible gutter; the same value is applied as outer padding
        /// around the panes host so edge panes float away from the tab strip / status bar / sidebar.
        static let paneGap: CGFloat = 7
    }
}

// MARK: - Reusable chrome bits (the IconButton Muxy uses throughout its strips/footers)

/// A small, borderless icon button in the Muxy idiom: a 24pt hit target, `fgMuted` at rest, `accent` on
/// hover, with a subtle `hover` background plate. Used by the tab-strip controls and the sidebar footer so
/// every chrome affordance reads identically (replacing the scattered `.buttonStyle(.borderless)` +
/// `.foregroundStyle(.secondary)` calls that looked stock).
struct ChromeIconButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    var size: CGFloat = 24
    var glyphSize: CGFloat = 12
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    // control radius = 4 (sm) per Warp convention: buttons/badges use the small radius
                    RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.sm, style: .continuous)
                        .fill(hovering ? AislopdeskTheme.hover : .clear),
                )
                .foregroundStyle(hovering
                    ? AnyShapeStyle(role == .destructive ? Color.red : AislopdeskTheme.accent)
                    : AnyShapeStyle(AislopdeskTheme.fgMuted))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .onHover { hovering = $0 }
        #endif
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Glass surface helper (transient overlays only)

extension View {
    /// Backs a TRANSIENT overlay (the ⌘K palette, future floating/peek overlays) with a glass surface.
    /// On macOS 26 / iOS 26 it uses the native `.glassEffect(.regular,…)`; on older OSes it falls back to
    /// `.ultraThinMaterial` plus a hairline `border` stroke so the look degrades gracefully.
    ///
    /// HARD RULE (one-surface invariant): NEVER call this on a content / terminal / GUI-video pane or the
    /// full window — glass is reserved for transient floating chrome, so the window keeps reading as one
    /// solid theme surface with the terminal.
    @ViewBuilder
    func glassedSurface(corner: CGFloat) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(AislopdeskTheme.border, lineWidth: 1),
                )
        }
    }
}
#endif
