#if canImport(SwiftUI)
import SwiftUI

// MARK: - CanvasView (the pannable infinite plane)

/// The regular-width workspace surface (docs/30 §6.2): one tab's infinite ``Canvas`` rendered under a
/// single rigid camera `.offset` (a pure translate — NEVER a scale, so every libghostty surface keeps
/// `bounds == frame == 1:1` and its points-with-y-flip mouse mapping is unchanged). It:
/// - mounts the kind-aware visible items (terminals never culled; off-viewport video culled),
/// - positions each at its canvas-space frame and applies the camera as one `.offset`,
/// - pans via a background drag (both platforms) and trackpad scroll/wheel (macOS),
/// - renders the maximized pane full-viewport when one is set (the old zoom branch),
/// - reports the solved layout (geometric focus), the viewport size, and viewport membership
///   (the video-cap "on screen" signal) back to the store.
///
/// Replaces the recursive `PaneTreeView`. The compact (phone) projection stays the carousel.
struct CanvasView: View {
    let store: WorkspaceStore
    let tab: TabID

    /// Screen-space additive offset applied to the content during a LIVE background pan (before commit).
    /// View `@State` so the per-frame pan never touches the store (the `SplitContainer` discipline);
    /// only `.onEnded` / a scroll step commits via ``WorkspaceStore/commitCamera(_:)``.
    @State private var livePan: CGSize = .zero

    private static let coordSpace = "canvas"

    private var activeTab: Tab? { store.workspace.tabs.first { $0.id == tab } }
    private var canvas: Canvas { activeTab?.canvas ?? Canvas(items: []) }

    var body: some View {
        GeometryReader { geo in
            let camera = canvas.camera
            ZStack(alignment: .topLeading) {
                if let maxID = activeTab?.maximizedPane, canvas.contains(maxID) {
                    maximizedBody(maxID, viewport: geo.size)
                } else {
                    backgroundPanLayer(camera: camera)
                    canvasContent(camera: camera, viewport: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .coordinateSpace(.named(Self.coordSpace))
            .overlay(alignment: .bottomTrailing) { recenterButton(viewport: geo.size) }
            .onAppear { report(geo.size, camera: canvas.camera) }
            .onChange(of: geo.size) { _, s in report(s, camera: canvas.camera) }
            .onChange(of: canvas) { _, _ in report(geo.size, camera: canvas.camera) }
            // Maximize toggles a flag on `Tab` (not on `canvas`), so `.onChange(of: canvas)` does NOT
            // fire — recompute membership here so entering/leaving maximize correctly reports exactly
            // the maximized pane (or the full canvas) and the now-hidden video panes free their slots.
            .onChange(of: activeTab?.maximizedPane) { _, _ in report(geo.size, camera: canvas.camera) }
            // When the canvas view disappears (a regular→compact projection flip), clear membership so
            // the compact carousel falls back to `isPaneOnActiveTab` instead of inheriting a stale set.
            .onDisappear { store.clearViewportMembership() }
        }
        .background(.background)
    }

    // MARK: Content

    private func canvasContent(camera: CanvasCamera, viewport: CGSize) -> some View {
        let visible = CanvasGeometry.visibleItems(canvas.items, camera: camera, viewport: viewport,
                                                  focused: activeTab?.focusedPane)
        return ZStack(alignment: .topLeading) {
            ForEach(visible.sorted { $0.z < $1.z }) { item in
                CanvasItemView(item: item, store: store, tab: tab, coordSpace: Self.coordSpace)
                    .position(x: item.frame.midX, y: item.frame.midY)   // canvas-space; CONSTANT during a pan
                    // The focused pane always renders above the rest (the pane you are interacting with
                    // is on top); the dragged pane is usually the focused one and is raised on commit.
                    .zIndex(store.isFocused(item.id) ? 1_000_000 : Double(item.z))
                    .id(item.id)                                         // LOAD-BEARING (.id(PaneID))
            }
        }
        // Explicit size so `.position` lays out absolutely; off-frame items are NOT clipped here (the
        // outer GeometryReader `.clipped()` clips the viewport), so panned-in panes appear.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .offset(x: -camera.origin.x + livePan.width, y: -camera.origin.y + livePan.height)  // the ONLY camera application (rigid)
    }

    // MARK: Maximize (full-viewport one pane — the old zoom branch)

    private func maximizedBody(_ id: PaneID, viewport: CGSize) -> some View {
        // No move gesture (a maximized pane can't be dragged); the chrome's button reads "Restore".
        PaneChromeView(
            id: id,
            spec: canvas.spec(for: id) ?? PaneSpec(kind: .terminal, title: "Terminal"),
            handle: store.handle(for: id),
            isFocused: store.isFocused(id),
            isZoomed: true,
            store: store
        ) {
            PaneLeafView(
                handle: store.handle(for: id),
                spec: canvas.spec(for: id) ?? PaneSpec(kind: .terminal, title: "Terminal"),
                isFocused: store.isFocused(id),
                focusCoordinator: store.focusCoordinator,
                store: store
            )
        }
        .padding(4)
        .id(id)   // same identity → the live session survives maximize/restore (no teardown)
    }

    // MARK: Background pan

    @ViewBuilder
    private func backgroundPanLayer(camera: CanvasCamera) -> some View {
        #if os(macOS)
        // macOS: a bottom NSView catches scroll-wheel / trackpad-scroll AND empty-background drag to pan
        // (a SwiftUI DragGesture cannot see scroll, and an overlay returning nil from hitTest would get
        // no scroll either — so the catcher sits BEHIND the panes; panes above intercept their own
        // region, and scroll over a terminal still reaches libghostty's scrollback).
        CanvasBackingView(
            onLiveDrag: { livePan = $0 },
            onCommitDrag: { translation in commitPan(translation); livePan = .zero },
            onScroll: { delta in store.commitCamera(canvas.camera.translated(by: delta)) }
        )
        #else
        // iOS: one-finger drag on the empty background pans (a touch that starts on a pane is absorbed by
        // that pane's `.simultaneousGesture(Tap)`, so the background never sees it).
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.coordSpace))
                    .onChanged { v in livePan = v.translation }
                    .onEnded { v in commitPan(v.translation); livePan = .zero }
            )
        #endif
    }

    /// Commits a finished background drag: the camera moves OPPOSITE the drag (grab-the-canvas feel), so
    /// the steady offset after commit equals the live offset (no jump).
    private func commitPan(_ translation: CGSize) {
        store.commitCamera(canvas.camera.translated(by: CGSize(width: -translation.width, height: -translation.height)))
    }

    // MARK: Recenter affordance

    @ViewBuilder
    private func recenterButton(viewport: CGSize) -> some View {
        if activeTab?.maximizedPane == nil, canvas.needsRecenter(viewport: viewport), !canvas.items.isEmpty {
            Button {
                store.centerOnAll()
            } label: {
                Label("Recenter", systemImage: "scope")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(16)
            .help("Pan back to your panes")
            .transition(.opacity)
        }
    }

    // MARK: Reporting (geometric focus + viewport + video-cap membership)

    private func report(_ size: CGSize, camera: CanvasCamera) {
        guard size.width > 0, size.height > 0 else { return }
        store.updateViewport(size)
        if let maxID = activeTab?.maximizedPane, canvas.contains(maxID) {
            // Maximize: exactly ONE pane is on screen (the others are unmounted) → membership is just
            // that pane, so every hidden video pane's `isPaneVisible` flips false and frees its slot.
            // Geometric focus likewise sees the single full-viewport pane.
            store.updateViewportMembership([maxID])
            store.updateSolvedLayout(SolvedLayout(frames: [maxID: CGRect(origin: .zero, size: size)]))
        } else {
            store.updateViewportMembership(CanvasGeometry.viewportMembers(canvas.items, camera: camera, viewport: size))
            store.updateSolvedLayout(canvas.solvedLayout())   // canvas-space; FocusResolver consumes unchanged
        }
    }
}

// MARK: - CanvasBackingView (macOS scroll + background-drag pan)

#if os(macOS)
import AppKit

/// The macOS background pan surface: a bottom NSView that converts trackpad/wheel scroll AND an
/// empty-background mouse drag into camera pans (docs/30 §6.3). It sits BEHIND the panes so a click /
/// scroll over a pane reaches the pane (libghostty mouseDown + terminal scrollback), and only
/// empty-background events reach it. The `WindowWidthReader` drop-to-AppKit idiom.
private struct CanvasBackingView: NSViewRepresentable {
    /// Called repeatedly during a background drag with the running translation (screen-space).
    let onLiveDrag: (CGSize) -> Void
    /// Called once on mouse-up with the final translation.
    let onCommitDrag: (CGSize) -> Void
    /// Called per scroll step with the camera delta to apply (already sign-adjusted for natural scroll).
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        PanView(onLiveDrag: onLiveDrag, onCommitDrag: onCommitDrag, onScroll: onScroll)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PanView else { return }
        v.onLiveDrag = onLiveDrag
        v.onCommitDrag = onCommitDrag
        v.onScroll = onScroll
    }

    final class PanView: NSView {
        var onLiveDrag: (CGSize) -> Void
        var onCommitDrag: (CGSize) -> Void
        var onScroll: (CGSize) -> Void
        private var dragStart: NSPoint?

        init(onLiveDrag: @escaping (CGSize) -> Void,
             onCommitDrag: @escaping (CGSize) -> Void,
             onScroll: @escaping (CGSize) -> Void) {
            self.onLiveDrag = onLiveDrag
            self.onCommitDrag = onCommitDrag
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        // Bottom layer: receives only events not consumed by a pane above it.
        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas {
                dx = event.scrollingDeltaX; dy = event.scrollingDeltaY
            } else {
                dx = event.scrollingDeltaX * 10; dy = event.scrollingDeltaY * 10
            }
            // Natural scroll: the content follows the fingers, so the camera moves opposite the scroll.
            onScroll(CGSize(width: -dx, height: -dy))
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = convert(event.locationInWindow, from: nil)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            // AppKit y grows UP; SwiftUI / canvas y grows DOWN → flip dy so a drag feels natural.
            onLiveDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
        }
        override func mouseUp(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            onCommitDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
            dragStart = nil
        }
    }
}
#endif
#endif
