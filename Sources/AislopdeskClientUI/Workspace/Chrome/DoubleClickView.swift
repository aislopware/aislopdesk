// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
import AppKit

struct DoubleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> DoubleClickNSView {
        let view = DoubleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: DoubleClickNSView, context _: Context) {
        nsView.action = action
    }
}

final class DoubleClickNSView: NSView {
    var action: (() -> Void)?

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let currentEvent = NSApp.currentEvent,
              currentEvent.type == .leftMouseDown,
              currentEvent.clickCount == 2
        else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        action?()
    }
}

#else

/// iOS stub: an inert overlay that keeps cross-platform call sites compiling. macOS catches the
/// raw double-click via an `NSView`; on iOS double-tap handling belongs to a SwiftUI gesture instead,
/// so this view does nothing and the `action` is simply never fired here.
struct DoubleClickView: View {
    let action: () -> Void

    var body: some View {
        Color.clear.allowsHitTesting(false)
    }
}

#endif
#endif
