// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
import AppKit

struct MiddleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickNSView, context _: Context) {
        nsView.action = action
    }
}

final class MiddleClickNSView: NSView {
    var action: (() -> Void)?

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let currentEvent = NSApp.currentEvent,
              currentEvent.type == .otherMouseDown,
              currentEvent.buttonNumber == 2
        else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        action?()
    }
}

#else

/// iOS stub: there is no middle mouse button on iOS, so this is an inert view that keeps cross-platform
/// call sites compiling. It paints nothing and the `action` is never fired here.
struct MiddleClickView: View {
    let action: () -> Void

    var body: some View {
        Color.clear.allowsHitTesting(false)
    }
}

#endif
#endif
