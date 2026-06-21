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

    // P2 REPOINT: these point at the ``DSPalette`` primitives (non-isolated `static let`s) that the
    // matching ``DSColor`` role tokens themselves return — `DSColor.bg` IS `DSPalette.n1`, so pointing
    // here at `DSPalette.n1` is byte-identical to `DSColor.bg` while staying a plain `static let` (no
    // `@MainActor` hop; `DSColor` is `@MainActor`-isolated, `DSPalette` is not). The accent ladder below
    // DOES read `DSColor` (for the live ``DSThemeStore`` override) and so is `@MainActor` computed.

    /// The window/chrome background.
    ///
    /// P2 REPOINT: now the new cool ink `n1` `#121316` (== ``DSColor/bg``) — the legacy warm near-black
    /// `#161716` literal is retired. All ~12 `AislopdeskTheme.bg` call sites pick up the new surface
    /// ladder at once without a per-site migration (that structural work is P3). COLOR-ONLY: no geometry.
    static let bg = DSPalette.n1

    /// A slightly raised opaque surface for overlays / popovers that need a hard background.
    ///
    /// P2 REPOINT: now the raised chrome step `n3` `#1D1F24` (== ``DSColor/chrome``: sidebar / tab strip
    /// / raised panel), replacing the legacy warm `#1F1F1E`.
    static let bgRaised = DSPalette.n3

    /// The DEEPEST elevation level — the gutter "canvas behind cards".
    ///
    /// P2 REPOINT: now the sunken floor `n0` `#0C0D0F` (== ``DSColor/bgSunken``). The SplitTreeView seam +
    /// the outer half-gap padding paint this so the `bg` panes read as raised cards floating on a sunken
    /// floor; the new ramp deepens the spread so the ladder is actually felt.
    static let bgSunken = DSPalette.n0

    /// The foreground (text/icon) base.
    ///
    /// P2 REPOINT: now ``DSPalette/n12`` (`#ECEEF1`, the cool off-white primary text — NOT pure #FFF),
    /// replacing the legacy warm `#EAE8E3`. The text ladder below is RECALIBRATED against the new base by
    /// repointing each step at the matching opaque cool token (see each accessor).
    static let fg = DSPalette.n12

    // MARK: Derived foreground tokens (recalibrated text ladder on the new cool base)

    /// Primary text — main labels, active tab titles.
    ///
    /// P2 REPOINT: `n12` (== ``DSColor/textPrimary``). The old `fg·0.90` is retired; the new opaque cool
    /// token reads better against the deeper `n1`/`n2` surfaces.
    static let fgPrimary = DSPalette.n12
    /// Secondary text — labels, inactive tab titles.
    ///
    /// P2 REPOINT: `n11` `#C3C7CE` (== ``DSColor/textSecondary``, ≈ the old `fg·0.65` step but opaque + cool).
    static let fgMuted = DSPalette.n11
    /// Tertiary text / dim icons — close glyphs, counts.
    ///
    /// P2 REPOINT: `n10` `#9AA0AB` (== ``DSColor/textTertiary``, ≈ the old `fg·0.40` step, opaque + cool).
    static let fgDim = DSPalette.n10
    /// Placeholder / disabled text — hint strings, fully disabled controls.
    ///
    /// P2 REPOINT: `n9` `#6B7280` (== ``DSColor/textDisabled``, ≈ the old `fg·0.20` step, opaque + cool).
    static let fgFaint = DSPalette.n9

    // MARK: Surface ladder (white-over-bg tints matching the new semantic tokens)

    /// The lightest raised surface — hover / subtle fill.
    ///
    /// P2 REPOINT: white·0.05 (== ``DSColor/hoverFill``).
    static let surface05 = Color.white.opacity(0.05)
    /// Active-tab / selected-row fill.
    ///
    /// P2 REPOINT: white·0.08 (== ``DSColor/activeFill``).
    static let surface = Color.white.opacity(0.08)
    /// A slightly stronger surface — focused input / active sidebar row.
    ///
    /// P2 REPOINT: white·0.08 (== ``DSColor/activeFill``). The legacy `surface12` (fg·0.12) flattens to the
    /// same `activeFill` step in the new ladder (the distinct `12` rung is not in the semantic token set);
    /// the only call site is a fill tint, so the merge is intentional and invisible in practice.
    static let surface12 = Color.white.opacity(0.08)
    /// Every divider / separator / hairline border — soft 1px lines.
    ///
    /// P2 REPOINT: white·0.07 (== ``DSColor/borderSubtle``).
    static let border = Color.white.opacity(0.07)
    /// Row hover background.
    ///
    /// P2 REPOINT: white·0.05 (== ``DSColor/hoverFill``).
    static let hover = Color.white.opacity(0.05)

    // MARK: Accent + accent-overlay ladder

    // These are `@MainActor` COMPUTED (not stored) because they read ``DSColor/accentSolid`` which
    // resolves the live ``DSThemeStore`` accent override (`store.accent ?? DSPalette.a9`) — a stored
    // `static let` would snapshot the default at init and miss a later user override.

    /// The focus / active accent.
    ///
    /// P2 REPOINT: now ``DSColor/accentSolid`` — the DS indigo (`a9` `#5E6AD2`) as the new DEFAULT,
    /// replacing the system `Color.accentColor`. Still user-overridable via ``DSThemeStore`` (the store's
    /// `accent` wins when set). The accent stays a SCARCE resource (focus ring / active-tab line / fill).
    @MainActor static var accent: Color { DSColor.accentSolid }
    /// A soft accent wash — hover / light fill (accentSolid · 0.10).
    ///
    /// P2 REPOINT: derived from the DS indigo at the SAME 0.10 opacity (was `Color.accentColor·0.10`).
    @MainActor static var accentSoft: Color { DSColor.accentSolid.opacity(0.10) }
    /// A medium accent wash — hover-active / focused interactive rows (accentSolid · 0.25).
    ///
    /// P2 REPOINT: DS indigo at the SAME 0.25 opacity (was `Color.accentColor·0.25`).
    @MainActor static var accentHover: Color { DSColor.accentSolid.opacity(0.25) }
    /// A strong accent wash — selected / active state tint (accentSolid · 0.40).
    ///
    /// P2 REPOINT: DS indigo at the SAME 0.40 opacity (was `Color.accentColor·0.40`).
    @MainActor static var accentSelected: Color { DSColor.accentSolid.opacity(0.40) }
    /// A contrasting foreground for text/glyphs painted ON the accent fill — black on a light accent,
    /// white on a dark one (Muxy `accentForeground` = `contrastingForeground(for: accent)`, threshold 0.6).
    /// Our base accent is the system accent, so this is derived from `NSColor.controlAccentColor` on
    /// macOS and falls back to white where AppKit is unavailable.
    ///
    /// P1 SHIM: the `contrastingForeground(for:)` body below now forwards to the deduped single contrast
    /// helper (``DSPalette.contrastingForeground(for:)``), so this stored value is byte-identical to the
    /// pre-P1 computation (same 0.6 threshold, same separated products).
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
    /// The chrome background as an `NSColor` for AppKit views (matches `bg`).
    ///
    /// P2 REPOINT: now ``DSPalette/nsN1`` (`n1` `#121316`) — the AppKit mirror of the new window bg. The
    /// ``WindowConfigurator`` titlebar reads THIS for the window content-layer background, so repointing it
    /// re-matches the title strip to `n1` in lockstep with the SwiftUI `bg` — no seam (`bg` and `nsBg` are
    /// the same `n1` ink).
    static let nsBg = DSPalette.nsN1
    /// The foreground as an `NSColor` for AppKit views (matches `fg`).
    ///
    /// P2 REPOINT: now ``DSPalette/nsN12`` (`n12` `#ECEEF1`, the cool off-white).
    static let nsFg = DSPalette.nsN12
    /// Secondary foreground as an `NSColor` (matches `fgMuted`).
    ///
    /// P2 REPOINT: now ``DSPalette/nsN11`` (`n11` `#C3C7CE`) — the opaque cool secondary-text mirror,
    /// replacing the old `nsFg·0.65` alpha blend.
    static let nsFgMuted = DSPalette.nsN11
    /// The sunken gutter as an `NSColor` for AppKit views (matches `bgSunken`).
    ///
    /// P2 REPOINT: now ``DSPalette/nsN0`` (`n0` `#0C0D0F`).
    static let nsBgSunken = DSPalette.nsN0
    #endif

    // MARK: Color scheme

    /// The chrome's effective appearance. Muxy derives this from the background luminance (light if
    /// luminance > 0.5, else dark); our base `bg` is the cool ink `n1` `#121316` (P2 repoint), deeply
    /// dark, so this is `.dark`.
    static let colorScheme: ColorScheme = .dark

    // MARK: Contrast helper (Muxy `Snapshot.contrastingForeground(for:)`)

    #if canImport(AppKit)
    /// Returns black or white — whichever reads against `color` — using the sRGB relative luminance
    /// (0.2126·r + 0.7152·g + 0.0722·b), with Muxy's 0.6 threshold. Used to pick `accentForeground`.
    ///
    /// P1 SHIM: forwards to the deduped single contrast helper (``DSPalette.contrastingForeground(for:)``)
    /// so there is ONE implementation. The DS helper keeps the SAME separated `*` then `+` products
    /// (never fused to `addingProduct`/`fma`) and the same 0.6 threshold — byte-identical output.
    static func contrastingForeground(for color: NSColor) -> NSColor {
        DSPalette.contrastingForeground(for: color)
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
