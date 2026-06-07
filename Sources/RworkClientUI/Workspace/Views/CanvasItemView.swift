#if canImport(SwiftUI)
import SwiftUI

// MARK: - CanvasItemView (one positioned pane on the infinite plane)

/// Renders one ``CanvasItem`` (docs/30 §6.4): the proven ``PaneChromeView`` + ``PaneLeafView``
/// **verbatim**, plus the two canvas-only gestures — drag-to-move (on the header) and 8-anchor resize
/// (on edge/corner grips). The parent ``CanvasView`` positions this view at the item's canvas-space
/// frame (under one rigid camera `.offset`); this view only previews a live move/resize and commits
/// once on `.onEnded` (the `SplitContainer` commit-on-end discipline — no per-frame store mutation, no
/// `TIOCSWINSZ` storm).
///
/// ### Why the body keeps its click (docs/30 §6.5)
/// The move gesture is attached to the HEADER only (inside ``PaneChromeView``), and the resize gesture
/// only to the thin edge/corner grips — both plain `.gesture` (never `.highPriorityGesture`). The
/// terminal body has NO ancestor gesture, so libghostty's own `mouseDown` (selection / mouse reporting)
/// is never stolen; body focus comes from `onRequestFocus` (``wireFocusOnClick(for:)``, ported verbatim
/// from the old `PaneTreeView`), and on iOS from a `.simultaneousGesture(Tap)`.
struct CanvasItemView: View {
    let item: CanvasItem
    let store: WorkspaceStore
    let tab: TabID
    /// The named coordinate space of the canvas plane (so a drag translation is the canvas-space delta,
    /// 1:1 since the camera is a pure translate).
    let coordSpace: String

    /// Live drag-to-move preview (rigid `.offset`; auto-resets on gesture end). The committed move
    /// lands via ``WorkspaceStore/movePane(_:by:)`` on `.onEnded`.
    @GestureState private var moveLive: CGSize = .zero
    /// Live resize preview — the previewed canvas-space frame, or `nil` when not resizing. Auto-resets
    /// on gesture end; the committed frame lands via ``WorkspaceStore/resizePane(_:to:)``.
    @GestureState private var resizeLive: CGRect?

    private var isFocused: Bool { store.isFocused(item.id) }

    var body: some View {
        let shown = resizeLive ?? item.frame
        // Keep the ANCHORED edge pinned during a resize: the parent positions us at the original
        // frame's centre, so shift by the centre delta of the previewed frame (zero when not resizing),
        // plus the rigid move preview.
        let offsetX = (shown.midX - item.frame.midX) + moveLive.width
        let offsetY = (shown.midY - item.frame.midY) + moveLive.height

        return PaneChromeView(
            id: item.id,
            spec: item.spec,
            handle: store.handle(for: item.id),
            isFocused: isFocused,
            isZoomed: store.activeTab?.maximizedPane == item.id,
            store: store,
            moveHandleGesture: AnyGesture(moveGesture.map { _ in () })
        ) {
            PaneLeafView(
                handle: store.handle(for: item.id),
                spec: item.spec,
                isFocused: isFocused,
                focusCoordinator: store.focusCoordinator,
                store: store
            )
        }
        .frame(width: shown.width, height: shown.height)   // resize previews live (intended reflow)
        .overlay { resizeHandles }
        .offset(x: offsetX, y: offsetY)
        // NOTE: the dragged pane floats above its siblings via the OUTER `.zIndex` in CanvasView (sibling
        // stacking lives there) — driven by `store.isFocused`, which the move/resize gestures set at drag
        // START (`raiseOnGestureStart`). A `.zIndex` here would be inert (no siblings at this level).
        .onAppear { wireFocusOnClick(for: item.id) }
        #if os(iOS)
        // Absorb a touch on the body → focus this pane AND block the background pan from firing under
        // it (the bottom Color.clear pan layer never sees a touch that lands on a pane).
        .simultaneousGesture(TapGesture().onEnded { store.focus(item.id) })
        #endif
    }

    // MARK: Gestures

    /// Drag-to-move: live rigid preview via `@GestureState`, ONE commit on `.onEnded` (which also
    /// raises + focuses). The translation is read in the canvas coordinate space (1:1 → it IS the
    /// canvas delta). Attached to the header only (passed into ``PaneChromeView``).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($moveLive) { value, state, _ in state = value.translation }
            .onChanged { _ in raiseOnGestureStart() }
            .onEnded { value in store.movePane(item.id, by: value.translation) }
    }

    /// Floats this pane to the top the instant a move/resize drag begins (so it is never occluded by a
    /// higher-z sibling mid-gesture). Raising focuses it → CanvasView's outer `.zIndex` lifts it. The
    /// `!isFocused` guard makes it fire at most once per gesture (after the first raise it is focused),
    /// so there is no per-frame store churn; the committed z/frame still land on `.onEnded`.
    private func raiseOnGestureStart() {
        if !store.isFocused(item.id) { store.raisePane(item.id) }
    }

    /// 8-anchor resize for `anchor`: live `.frame` preview (deliberately reflows for native feel), ONE
    /// commit on `.onEnded`. The downstream `sendResize` dedup + host resize-debounce absorb the
    /// intermediate sizes, so only the final frame is persisted.
    private func resizeGesture(_ anchor: ResizeAnchor) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($resizeLive) { value, state, _ in
                state = CanvasGeometry.resizing(item.frame, anchor: anchor, by: value.translation, minSize: Canvas.minItemSize)
            }
            .onChanged { _ in raiseOnGestureStart() }
            .onEnded { value in
                let f = CanvasGeometry.resizing(item.frame, anchor: anchor, by: value.translation, minSize: Canvas.minItemSize)
                store.resizePane(item.id, to: f)
            }
    }

    // MARK: Resize handles

    /// Thin invisible grips at the 4 corners + 4 edges. Edges are laid out first so the corners (added
    /// last) win hit-testing where they overlap. Only the grip area is interactive (the gesture is on
    /// the small grip, not the full-bleed positioning frame), so the terminal body stays clickable.
    private var resizeHandles: some View {
        ZStack {
            edgeHandle(.top, alignment: .top)
            edgeHandle(.bottom, alignment: .bottom)
            edgeHandle(.left, alignment: .leading)
            edgeHandle(.right, alignment: .trailing)
            cornerHandle(.topLeft, alignment: .topLeading)
            cornerHandle(.topRight, alignment: .topTrailing)
            cornerHandle(.bottomLeft, alignment: .bottomLeading)
            cornerHandle(.bottomRight, alignment: .bottomTrailing)
        }
        .allowsHitTesting(store.activeTab?.maximizedPane == nil)   // no resize while maximized
    }

    private static let cornerGrip: CGFloat = 16
    private static let edgeThickness: CGFloat = 8

    private func cornerHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.cornerGrip, height: Self.cornerGrip)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
            #if os(macOS)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func edgeHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        let horizontal = (anchor == .top || anchor == .bottom)
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: horizontal ? nil : Self.edgeThickness,
                height: horizontal ? Self.edgeThickness : nil
            )
            .frame(maxWidth: horizontal ? .infinity : nil, maxHeight: horizontal ? nil : .infinity)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
            #if os(macOS)
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
                else { NSCursor.pop() }
            }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    // MARK: Focus wiring (ported verbatim from the old PaneTreeView.wireFocusOnClick)

    /// Points the leaf's terminal renderer at `store.focus(id)` so a click on the terminal BODY focuses
    /// the pane (libghostty's `mouseDown` consumes the tap before any SwiftUI gesture). A faked /
    /// `.remoteGUI` handle has no `terminalModel`, so this is a no-op there. Captures only `store` + `id`
    /// (both stable), so the closure stays correct across reshapes.
    private func wireFocusOnClick(for id: PaneID) {
        guard let live = store.handle(for: id) as? LivePaneSession,
              let model = live.terminalModel else { return }
        model.onRequestFocus = { [weak store] in store?.focus(id) }
    }
}
#endif
