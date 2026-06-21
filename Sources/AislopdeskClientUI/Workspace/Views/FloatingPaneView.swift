#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI

// MARK: - FloatingPaneView (P5a — the zellij-style floating/scratch pane card)

/// A single FLOATING pane: a raised card that overlays the tiled ``SplitTreeView`` layout at the pane's
/// (clamped) `floatingFrame`, movable by its title strip and resizable by its corner grips. It wraps the
/// SAME reused leaf content (the `content` closure mounts the very `.id(PaneID)` host the tiled path would
/// — no double-mount, no teardown on a float↔tile toggle: the host just changes geometry).
///
/// ### One-surface rule (CLAUDE.md)
/// Glass / material lives ONLY on the title-strip chrome (via ``glassedSurface(corner:)``). The TERMINAL
/// CONTENT stays opaque/solid — the card body is a solid `bg` raised surface with a border + drop shadow,
/// and the leaf chrome inside is the normal opaque ``PaneChromeView``. The float is NEVER dimmed.
///
/// ### Gesture discipline (mirrors ``CanvasItemView``)
/// The MOVE drag lives on the title strip only; the RESIZE drag on the corner grips only — both plain
/// `.gesture` (never `.highPriorityGesture`), so a click/drag in the terminal BODY still reaches
/// libghostty (selection). The live drag/resize preview is held in `@GestureState` (no per-frame store
/// write); the store is mutated exactly ONCE on `.onEnded` (one `reconcileTree()` → keystroke/render-path
/// safe). All sizes route through ``AislopdeskTheme`` tokens.
struct FloatingPaneView<Content: View>: View {
    @Bindable var store: WorkspaceStore
    let tab: Tab
    let id: PaneID
    /// The clamped floating frame in the `SplitTreeView` bounds coordinate space (from the render model).
    let rect: CGRect
    /// The container bounds (for committing a clamped move/resize through the store).
    let bounds: CGRect
    /// The reused leaf content (the `.id(PaneID)` host). Called with the embedded content rect (the card
    /// interior, origin-relative) + visibility (always true for a float).
    @ViewBuilder let content: (CGRect, Bool) -> Content

    /// Live MOVE preview (title-strip drag) — origin delta, no store write until `.onEnded`.
    @GestureState private var dragOffset: CGSize = .zero
    /// Live RESIZE preview (corner-grip drag) — size/origin delta, no store write until `.onEnded`.
    @GestureState private var resizeDelta: FloatingResizeDelta = .zero

    @State private var hoveringStrip = false

    /// The strip height (a slim title/grab bar — the only floating chrome that may be glass).
    private static var stripHeight: CGFloat { 26 }
    /// The corner resize-grip hit size.
    private static var gripSize: CGFloat { 16 }

    private var spec: PaneSpec {
        store.tree.spec(for: id) ?? PaneSpec(kind: .terminal, title: "Terminal")
    }

    /// The card frame after the live (un-committed) drag/resize preview is applied, CLAMPED into `bounds`
    /// with the same ``WorkspaceTreeOps/clampFloatingFrame(_:in:)`` the store's commit uses — so the live
    /// card stops at the viewport edge during the gesture and the `.onEnded` commit is a no-op continuation
    /// (no visible snap-back when you overshoot an edge). The size is floored first so a shrink grip can't
    /// collapse the card mid-drag.
    private var previewRect: CGRect {
        var r = rect
        r.origin.x += dragOffset.width + resizeDelta.origin.width
        r.origin.y += dragOffset.height + resizeDelta.origin.height
        let minW = WorkspaceTreeOps.floatingMinSize.width
        let minH = WorkspaceTreeOps.floatingMinSize.height
        r.size.width = Double.maximum(Double(r.size.width + resizeDelta.size.width), Double(minW))
        r.size.height = Double.maximum(Double(r.size.height + resizeDelta.size.height), Double(minH))
        return WorkspaceTreeOps.clampFloatingFrame(r, in: bounds)
    }

    var body: some View {
        let frame = previewRect
        VStack(spacing: 0) {
            titleStrip
            // The terminal content fills the rest of the card. The content closure mounts the reused
            // `.id(PaneID)` leaf host (opaque chrome inside — one-surface rule). The embedded rect is the
            // interior size; the leaf positions itself within via its own `.frame`/`.position`.
            content(CGRect(x: 0, y: 0, width: frame.width, height: frame.height - Self.stripHeight), true)
                .frame(width: frame.width, height: Double.maximum(Double(frame.height - Self.stripHeight), 0))
                .clipped()
        }
        .frame(width: frame.width, height: frame.height)
        // Solid raised card body (NOT glass — content stays opaque). Border + drop shadow give the lift.
        .background(
            RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous)
                .fill(AislopdeskTheme.bg),
        )
        .overlay(
            RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous)
                .strokeBorder(
                    tab.activePane == id ? AislopdeskTheme.accent.opacity(0.55) : AislopdeskTheme.border,
                    lineWidth: tab.activePane == id ? 1.5 : 1,
                ),
        )
        .clipShape(RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.pane, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
        // The SE-corner resize grip (an overlay so it sits above the content's hit area).
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .position(x: frame.midX, y: frame.midY)
        .animation(.easeOut(duration: 0.18), value: rect)
    }

    // MARK: Title strip (move + close/embed — the ONLY glass chrome)

    private var titleStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tab
                    .activePane == id ? AnyShapeStyle(AislopdeskTheme.accent) : AnyShapeStyle(.secondary))
            Text(PanePresentation.displayTitle(store.handle(for: id), spec: spec))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // Embed back into the tiled tree.
            ChromeIconButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Embed in layout") {
                store.embedFloating(id)
            }
            // Close the floating pane.
            ChromeIconButton(systemImage: "xmark", help: "Close floating pane", role: .destructive) {
                store.closeFloating(id)
            }
        }
        .padding(.horizontal, AislopdeskTheme.Space.l)
        .frame(height: Self.stripHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // Glass is permitted HERE (transient floating chrome) — never on the content below.
        .glassedSurface(corner: 0)
        .gesture(moveGesture)
        #if os(macOS)
            .onHover { inside in
                hoveringStrip = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
        #endif
            // A click on the strip (below the move dead zone) focuses the float.
            .onTapGesture { store.focusPaneTree(id) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text("Floating pane: \(PanePresentation.displayTitle(store.handle(for: id), spec: spec))"),
            )
    }

    // MARK: Move gesture (title strip only)

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                // A small dead zone so a click (focus / button) is not read as a drag.
                guard abs(value.translation.width) > 3 || abs(value.translation.height) > 3 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard abs(value.translation.width) > 3 || abs(value.translation.height) > 3 else { return }
                let origin = CGPoint(
                    x: rect.origin.x + value.translation.width,
                    y: rect.origin.y + value.translation.height,
                )
                store.moveFloating(id, to: origin)
            }
    }

    // MARK: Resize grip (SE corner only)

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.secondary)
            .frame(width: Self.gripSize, height: Self.gripSize)
            .background(
                RoundedRectangle(cornerRadius: AislopdeskTheme.Radius.sm, style: .continuous)
                    .fill(AislopdeskTheme.surface),
            )
            .padding(3)
            .contentShape(Rectangle())
        #if os(macOS)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        #endif
            .gesture(resizeGesture)
            .accessibilityLabel(Text("Resize floating pane"))
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($resizeDelta) { value, state, _ in
                // SE grip grows the size by the drag translation; origin is fixed (top-left anchored).
                state = FloatingResizeDelta(origin: .zero, size: value.translation)
            }
            .onEnded { value in
                let newFrame = CGRect(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width + value.translation.width,
                    height: rect.size.height + value.translation.height,
                )
                store.resizeFloating(id, to: newFrame)
            }
    }
}

/// A live resize/move preview delta (origin + size), `.zero` at rest. Top-level (not nested in the
/// generic ``FloatingPaneView``) so its `static let zero` is allowed.
struct FloatingResizeDelta: Equatable {
    var origin: CGSize
    var size: CGSize
    static let zero = Self(origin: .zero, size: .zero)
}
#endif
