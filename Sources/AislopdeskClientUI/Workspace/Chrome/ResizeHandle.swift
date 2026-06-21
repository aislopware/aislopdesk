// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ResizeHandle: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis
    var onEnd: (() -> Void)?
    let onDrag: (DragGesture.Value) -> Void
    @State private var hovering = false
    @GestureState private var dragging = false

    private var active: Bool { hovering || dragging }

    var body: some View {
        Rectangle()
            .fill(active ? AislopdeskTheme.accent : AislopdeskTheme.border)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(
                        width: axis == .horizontal ? UIMetrics.resizeHandleHitArea : nil,
                        height: axis == .vertical ? UIMetrics.resizeHandleHitArea : nil,
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { value in
                                setCursor()
                                onDrag(value)
                            }
                            .onEnded { _ in
                                onEnd?()
                            },
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            hovering = true
                            setCursor()
                        case .ended:
                            hovering = false
                            if !dragging {
                                resetCursor()
                            }
                        }
                    }
            }
            .zIndex(1)
    }

    #if os(macOS)
    private var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func setCursor() {
        cursor.set()
    }

    private func resetCursor() {
        NSCursor.arrow.set()
    }
    #else
    private func setCursor() {}
    private func resetCursor() {}
    #endif
}

struct AnchoredResizeHandle<Anchor>: View {
    let axis: ResizeHandle.Axis
    let captureAnchor: () -> Anchor
    let onTranslate: (Anchor, CGFloat) -> Void
    @State private var anchor: Anchor?

    var body: some View {
        ResizeHandle(
            axis: axis,
            onEnd: { anchor = nil },
            onDrag: { value in
                let current = anchor ?? captureAnchor()
                anchor = current
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                onTranslate(current, delta)
            },
        )
    }
}

struct PanelResizeHandle: View {
    enum Edge {
        case leading
        case trailing
        case top
        case bottom
    }

    let axis: ResizeHandle.Axis
    var edge: Edge = .leading
    let current: () -> CGFloat
    let apply: (CGFloat) -> Void

    var body: some View {
        AnchoredResizeHandle(
            axis: axis,
            captureAnchor: current,
            onTranslate: { start, delta in
                let signed = (edge == .leading || edge == .top) ? -delta : delta
                apply(start + signed)
            },
        )
        .accessibilityHidden(true)
    }
}
#endif
