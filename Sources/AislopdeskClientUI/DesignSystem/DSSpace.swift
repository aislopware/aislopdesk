#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - DSSpace (LAYER 2 — the ONE 4pt-base spacing scale)

/// The single 4pt-base spacing scale (kills the dual ``AislopdeskTheme.Space`` / ``UIMetrics.spacing*``
/// systems). Named by step so a density flip reflows everything. Every value is scaled by ``DSScale``.
///
/// P1 STATUS: target spec values. The legacy spacing accessors keep their CURRENT literals — and the map
/// is by VALUE not NAME (legacy `spacing5 = 10` does NOT become `s5 = 12`; the legacy accessor keeps 10).
/// NO view consumes `DSSpace` in P1.
///
/// ⚠️ LIVE-SCALE CONTRACT (read before P3/P5 adoption): these are `static var` getters that read
/// `DSScale.shared.multiplier` directly inside ``DSScale/scaled(_:)``. A singleton read inside a `static`
/// computed var is NOT tracked by SwiftUI's `@Observable` graph — it is the EXACT dead-notification shape
/// the spec indicts for legacy ``UIMetrics``. So `height = DSSpace.statusBarHeight` / `.padding(DSSpace.s6)`
/// / `.cornerRadius(DSRadius.sm)` wired STRAIGHT into view code will NOT live-repaint on a P5 density flip
/// (only `.dsFont`/`.dsSpace`, which read `@Environment(DSScale.self)`, reflow). To get a tracked,
/// live-reflowing geometry, consume these through a modifier that reads `@Environment(DSScale.self)` (e.g.
/// `.dsSpace`, or a future `.dsFrame(height:)`/`.dsRadius` helper) — do NOT read the static var directly in
/// a view body that must reflow. P3/P5 either funnels geometry through such tracked modifiers or accepts
/// that a directly-read dimension is fixed until the next view-identity change.
@preconcurrency @MainActor
public enum DSSpace {
    public static var s0: CGFloat { DSScale.scaled(0) }
    public static var s1: CGFloat { DSScale.scaled(2) }
    public static var s2: CGFloat { DSScale.scaled(4) }
    public static var s3: CGFloat { DSScale.scaled(6) }
    public static var s4: CGFloat { DSScale.scaled(8) }
    /// NOTE: 12 (the spec collapses the legacy 10 → 12 to land on a clean 4pt grid). Target-only in P1.
    public static var s5: CGFloat { DSScale.scaled(12) }
    public static var s6: CGFloat { DSScale.scaled(16) }
    public static var s7: CGFloat { DSScale.scaled(20) }
    public static var s8: CGFloat { DSScale.scaled(24) }
    public static var s9: CGFloat { DSScale.scaled(32) }
    public static var s10: CGFloat { DSScale.scaled(40) }
    public static var s11: CGFloat { DSScale.scaled(48) }
    public static var s12: CGFloat { DSScale.scaled(64) }

    // MARK: Density-driven layout tokens (default tier in P1; tier-driven in P5)

    /// List-row height (default density 28). Resolves through ``DSThemeStore/shared`` `.density.rowHeight`
    /// (there is no `DSDensity.current`; the active tier lives on the persisted ``DSThemeStore``).
    public static var rowHeight: CGFloat { DSScale.scaled(DSThemeStore.shared.density.rowHeight) }
    /// Tab-strip height (default density 30). Target-only in P1; legacy `Metrics.tabHeight` stays 32.
    public static var tabHeight: CGFloat { DSScale.scaled(DSThemeStore.shared.density.tabHeight) }
    /// Bottom status-bar height (default density 26). Legacy `Metrics.statusBarHeight` stays 28.
    public static var statusBarHeight: CGFloat { DSScale.scaled(DSThemeStore.shared.density.statusBarHeight) }

    /// The per-side pane gutter — 4pt (spec: paneGutter = space4(8)/2). Legacy `Space.paneGap` stays 7.
    public static var paneGutter: CGFloat { DSScale.scaled(4) }
    /// The split-divider grab band hit area (unchanged from today — forward-safe).
    public static var dividerHit: CGFloat { DSScale.scaled(16) }
}

// MARK: - DSRadius (LAYER 2 — the ONE radius scale)

/// The single corner-radius scale, scaled by ``DSScale``. Values 4/6/8/10 are unchanged from today; the
/// pane radius stays 8. `overlay` (12) is the new L4 overlay/modal radius (target-only in P1).
///
/// ⚠️ LIVE-SCALE CONTRACT: like ``DSSpace``, these `static var` getters read `DSScale.shared` inside a
/// static computed var, which SwiftUI cannot observe — a value read straight into `.cornerRadius(...)`
/// will NOT live-repaint on a P5 density flip. Consume via a tracked `@Environment(DSScale.self)`-reading
/// modifier when the radius must reflow live. See the ``DSSpace`` contract note.
@preconcurrency @MainActor
public enum DSRadius {
    public static var sm: CGFloat { DSScale.scaled(4) }
    public static var md: CGFloat { DSScale.scaled(6) }
    public static var lg: CGFloat { DSScale.scaled(8) }
    public static var xl: CGFloat { DSScale.scaled(10) }
    /// the per-pane rounded-card radius (8pt continuous)
    public static var pane: CGFloat { DSScale.scaled(8) }
    /// L4 overlay / palette / floating-pane radius (target-only in P1)
    public static var overlay: CGFloat { DSScale.scaled(12) }
}

// MARK: - dsSpace ViewModifier (reads @Environment(DSScale.self) — the tracked repaint path)

/// Applies uniform padding from a base point value, reading `@Environment(DSScale.self)` so the padding
/// repaints on a live density change (the same tracked-dependency mechanism as `.dsFont`). Forward
/// vocabulary in P1 — no view adopts it yet.
@preconcurrency @MainActor
public struct DSSpaceModifier: ViewModifier {
    @Environment(DSScale.self) private var scale
    let edges: Edge.Set
    let base: CGFloat

    public func body(content: Content) -> some View {
        // Read the injected instance's multiplier so SwiftUI records the dependency (single `*`, no FMA).
        content.padding(edges, base * scale.multiplier)
    }
}

public extension View {
    /// Pads by a base point value scaled live through `@Environment(DSScale.self)`. Forward vocabulary.
    @MainActor
    func dsSpace(_ edges: Edge.Set = .all, _ base: CGFloat) -> some View {
        modifier(DSSpaceModifier(edges: edges, base: base))
    }
}
#endif
