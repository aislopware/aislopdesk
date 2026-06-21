#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - DSScale (the live-scale fix)

/// The design-system's density multiplier — the LIVE, injected replacement for the dead
/// ``UIScale``-notification path.
///
/// THE CORRECTNESS FIX (P1): `DSScale` is `@Observable` AND is injected into the SwiftUI dependency
/// graph at ``WorkspaceRootView`` via `.environment(DSScale.shared)`. The `dsFont` / `dsSpace`
/// ViewModifiers read `@Environment(DSScale.self)`, so SwiftUI records the dependency and a density
/// change repaints every token-reading view. This closes the gap where ``UIScale`` is `@Observable`
/// but never injected — ``UIMetrics`` reads `UIScale.shared.multiplier` inside *static* computed vars,
/// which SwiftUI cannot observe, so `aislopdeskThemeDidChange` posts into the void (zero consumers).
///
/// P1 BRIDGE: `DSScale.shared.multiplier` mirrors `UIScale.shared.preset.multiplier` so DS tokens scale
/// identically to the legacy ``UIMetrics`` tokens while NO view consumes DS tokens yet. The semantic
/// `regular`/`large`/`extraLarge` → density-tier swap is deferred to P5; the legacy ``UIScale`` stays
/// intact for ``UIMetrics.scaled`` + ``WindowConfigurator``.
@preconcurrency @MainActor
@Observable
public final class DSScale {
    /// The process-wide instance injected at ``WorkspaceRootView`` and read by every `dsFont`/`dsSpace`.
    public static let shared = DSScale()

    /// The density multiplier applied to every geometric token (fonts, spacing, radii).
    ///
    /// P1 default 1.00 (matches today's `UIScale.defaultPreset`). It is a stored, observable property so
    /// mutating it invalidates every view whose body read `@Environment(DSScale.self)` — the tracked
    /// repaint path. In P1 it is seeded once from the legacy ``UIScale`` so the two systems never diverge.
    public var multiplier: CGFloat

    private init() {
        // P1 BRIDGE: seed from the legacy preset so a user who already chose Large/ExtraLarge gets DS
        // tokens at the same scale as the legacy `UIMetrics` tokens. No view consumes DS tokens in P1,
        // so this only matters for the unit-proof + forward-compat — but it keeps the two paths coherent.
        multiplier = UIScale.shared.multiplier
    }

    /// Scales a base point value by the active multiplier.
    ///
    /// CONVENTION: a single `*` — there is no `+ c` term, so the FMA rule is moot, but the project bans
    /// `addingProduct`/`fma` everywhere; keep it a plain multiply.
    public static func scaled(_ value: CGFloat) -> CGFloat {
        value * shared.multiplier
    }
}

// MARK: - DSDensity (semantic density tiers — vocabulary only in P1)

/// The semantic density tiers that will REPLACE ``UIScale.Preset`` (`regular`/`large`/`extraLarge`) in
/// P5. Each tier carries a `multiplier` plus row-height tokens so a density flip reflows the whole chrome
/// — not just fonts (the legacy presets only touched the font multiplier, leaving heights fixed).
///
/// DEFINED in P1 as forward vocabulary; NOT wired to env / ``DSScale`` until P5. P1's `DSScale.multiplier`
/// stays bridged to the legacy ``UIScale``.
public enum DSDensity: String, CaseIterable, Sendable {
    case compact
    case `default`
    case comfortable

    /// The scale factor fed to ``DSScale`` (P5).
    public var multiplier: CGFloat {
        switch self {
        case .compact: 0.92
        case .default: 1.00
        case .comfortable: 1.10
        }
    }

    /// The list-row height for this tier (drives `DSSpace.rowHeight` in P5).
    public var rowHeight: CGFloat {
        switch self {
        case .compact: 24
        case .default: 28
        case .comfortable: 32
        }
    }

    /// The tab-strip row height for this tier.
    public var tabHeight: CGFloat {
        switch self {
        case .compact: 28
        case .default: 30
        case .comfortable: 34
        }
    }

    /// The bottom status-bar height for this tier.
    public var statusBarHeight: CGFloat {
        switch self {
        case .compact: 24
        case .default: 26
        case .comfortable: 28
        }
    }
}

// MARK: - DSThemeStore (the optional accent override + density tier)

/// The persisted, observable theme overrides: an optional user accent (nil ⇒ ``DSColor.accentSolid``
/// falls back to ``DSPalette.a9``) and the active ``DSDensity`` tier.
///
/// In P1 this is forward vocabulary: `accent` is `nil` (so `DSColor.accentSolid` resolves to `a9`) and
/// `density` is `.default`. The wiring to env + persistence + the live density flip lands in P5.
@preconcurrency @MainActor
@Observable
public final class DSThemeStore {
    /// The process-wide theme store read by ``DSColor.accentSolid``.
    public static let shared = DSThemeStore()

    /// The user's accent override. `nil` ⇒ the DS default indigo (``DSPalette.a9``). P1: always `nil`.
    public var accent: Color?

    /// The active density tier. P1: `.default`.
    public var density: DSDensity

    private init() {
        accent = nil
        density = .default
    }
}
#endif
