// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
import AppKit

/// The window-shell configurator: the borderless, custom-title-bar foundation the whole chrome paints on
/// top of. Ported from Muxy's `WindowConfigurator` — it hides the stock titlebar, drops the window
/// background to a single solid theme color (so the window reads as ONE surface with the panes instead of
/// a stock `NavigationSplitView`), repositions the traffic lights to sit in our custom title bar, and keeps
/// them aligned across resize / screen-change / fullscreen / backing-property changes.
///
/// Attach it as a background of the root view:
///
///     SomeRootView()
///         .background(WindowConfigurator())
///
/// Unlike Muxy, this does NOT intercept the close button (Muxy is single-window and terminates the app on
/// close; we are multi-window-capable, so the default close behavior stands) and references no Muxy-only
/// types — only `AislopdeskTheme.nsBg` and the scaled `UIMetrics` tokens.
public struct WindowConfigurator: NSViewRepresentable {
    /// Bumping this re-applies `updateNSView` (e.g. after a theme / UI-scale change), so the traffic-light
    /// position and window background track the current `UIMetrics` without a manual relayout.
    public var configVersion: Int
    /// The active density preset. Stored so SwiftUI re-runs `updateNSView` when the user rescales the UI
    /// (the traffic-light Y is derived from `UIMetrics.titleBarHeight`, which scales with this).
    public var uiScalePreset: UIScale.Preset

    /// Create a window configurator. Both parameters default so it can be attached with a bare
    /// `.background(WindowConfigurator())`; pass the live values to force a reconfigure on change.
    public init(
        configVersion: Int = 0,
        uiScalePreset: UIScale.Preset = UIScale.shared.preset,
    ) {
        self.configVersion = configVersion
        self.uiScalePreset = uiScalePreset
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovable = false
            w.isMovableByWindowBackground = false
            Self.disableWindowTabbing(for: w)
            Self.applyWindowBackground(w)
            Self.repositionTrafficLights(in: w)
            Self.hideTitlebarDecorationView(in: w)
            Self.neutralizeSafeAreaInsets(in: w)
            context.coordinator.observe(window: w)
        }
        return v
    }

    public func updateNSView(_ nsView: NSView, context _: Context) {
        guard let w = nsView.window else { return }
        Self.applyWindowBackground(w)
        Self.repositionTrafficLights(in: w)
    }

    // MARK: Window surface

    /// Drop the stock window background to a single opaque theme color so the chrome blends into the panes
    /// (Muxy paints `nsBg` straight onto the content layer; no system material / vibrancy).
    private static func applyWindowBackground(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = AislopdeskTheme.nsBg.cgColor
    }

    /// Turn off native window tabbing — both the per-window mode and the app-wide automatic tabbing — so
    /// macOS never inserts a tab bar above our custom title bar.
    static func disableWindowTabbing(for window: NSWindow) {
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed
    }

    // MARK: Safe-area neutralization

    /// On macOS 26+, the system reserves a top safe-area inset for the (now-hidden) titlebar; zero it so the
    /// custom title bar starts flush at the top. We first clear our additive inset, read the residual base
    /// inset, then cancel it with an equal negative additive inset.
    static func neutralizeSafeAreaInsets(in window: NSWindow) {
        if #available(macOS 26.0, *) {
            guard let contentView = window.contentView else { return }
            contentView.additionalSafeAreaInsets.top = 0
            let baseSafeAreaTop = contentView.safeAreaInsets.top
            contentView.additionalSafeAreaInsets.top = -baseSafeAreaTop
        }
    }

    // MARK: Titlebar decoration removal

    /// Walk the private `NSTitlebarContainerView` / `NSTitlebarDecorationView` hierarchy and clear every
    /// opaque background layer so none of the stock titlebar chrome paints over our custom title bar. Class
    /// names are matched by substring (private API names can carry suffixes) and we only ever toggle
    /// visibility / clear layer colors — never reorder or remove views — so the traffic lights survive.
    static func hideTitlebarDecorationView(in window: NSWindow) {
        guard let themeFrame = window.contentView?.superview else { return }
        for view in themeFrame.subviews {
            let name = NSStringFromClass(type(of: view))
            guard name.contains("NSTitlebarContainerView") else { continue }

            view.wantsLayer = true
            view.layer?.backgroundColor = CGColor.clear
            view.layer?.isOpaque = false

            for child in view.subviews {
                let childName = NSStringFromClass(type(of: child))
                if childName.contains("NSTitlebarDecorationView") {
                    child.isHidden = true
                }
                if childName.contains("NSTitlebarView") {
                    child.wantsLayer = true
                    child.layer?.backgroundColor = CGColor.clear
                    child.layer?.isOpaque = false
                    for sub in child.subviews {
                        let subName = NSStringFromClass(type(of: sub))
                        if subName == "NSView" || subName.contains("Background") {
                            sub.isHidden = true
                        }
                    }
                }
            }
        }
    }

    // MARK: Traffic-light placement

    /// The pre-scale title-bar height the traffic-light math is anchored to (Muxy `baselineTitleBarHeight`).
    static let baselineTitleBarHeight: CGFloat = 32
    /// The traffic-light Y used on pre-macOS-26 systems (Muxy `trafficLightY`).
    static let trafficLightY: CGFloat = 3.5

    /// The Y origin the traffic lights are pinned to, scaled to track our custom title-bar height. As the UI
    /// scale grows the title bar, the buttons drop by half the extra height so they stay vertically centered.
    static func desiredTrafficLightY() -> CGFloat {
        let scaledTitleBarHeight = UIMetrics.titleBarHeight
        let extraVerticalSpace = scaledTitleBarHeight - baselineTitleBarHeight
        if #available(macOS 26.0, *) {
            let buttonHeight: CGFloat = 14
            return (baselineTitleBarHeight - buttonHeight - extraVerticalSpace) / 2
        }
        return trafficLightY - extraVerticalSpace / 2
    }

    /// Move the close / minimize / zoom buttons to `desiredTrafficLightY`, keeping all three visible. Skips
    /// buttons already within half a point of the target so it never churns the layout on idle notifications.
    static func repositionTrafficLights(in window: NSWindow) {
        let y = desiredTrafficLightY()
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let btn = window.standardWindowButton(button) else { continue }
            guard abs(btn.frame.origin.y - y) > 0.5 else { continue }
            var frame = btn.frame
            frame.origin.y = y
            btn.frame = frame
        }
    }

    // MARK: Coordinator

    /// Re-applies the title-bar tweaks whenever the window changes shape, screen, backing scale, key/main
    /// state, or fullscreen — AppKit re-lays-out the standard buttons on those events, so we re-pin them.
    public final class Coordinator: NSObject {
        private var observations: [NSObjectProtocol] = []
        private var buttonFrameObservations: [NSObjectProtocol] = []

        /// Subscribe to the window lifecycle notifications that can disturb the traffic lights / titlebar
        /// layer, re-pinning on each. Idempotent: a second call on the same coordinator is a no-op.
        public func observe(window: NSWindow) {
            guard observations.isEmpty else { return }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didUpdateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main,
                ) { notification in
                    guard let w = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated {
                        WindowConfigurator.repositionTrafficLights(in: w)
                        WindowConfigurator.hideTitlebarDecorationView(in: w)
                        if name == NSWindow.didChangeScreenNotification
                            || name == NSWindow.didChangeBackingPropertiesNotification
                        {
                            WindowConfigurator.neutralizeSafeAreaInsets(in: w)
                        }
                        if name == NSWindow.didEnterFullScreenNotification
                            || name == NSWindow.didExitFullScreenNotification
                        {
                            WindowConfigurator.neutralizeSafeAreaInsets(in: w)
                            let isFullScreen = w.styleMask.contains(.fullScreen)
                            NotificationCenter.default.post(
                                name: .aislopdeskWindowFullScreenDidChange,
                                object: w,
                                userInfo: ["isFullScreen": isFullScreen],
                            )
                        }
                    }
                }
                observations.append(token)
            }

            observeButtonFrames(window: window)
        }

        /// AppKit can re-frame the standard buttons after our own pin (e.g. when fullscreen accessory views
        /// appear). Observe each button's frame and re-pin on the next runloop tick so they settle in place.
        private func observeButtonFrames(window: NSWindow) {
            for token in buttonFrameObservations { NotificationCenter.default.removeObserver(token) }
            buttonFrameObservations.removeAll()
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = MainActor.assumeIsolated({ window.standardWindowButton(type) }) else { continue }
                MainActor.assumeIsolated { button.postsFrameChangedNotifications = true }
                let token = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: button,
                    queue: .main,
                ) { [weak window] _ in
                    guard let window else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            WindowConfigurator.repositionTrafficLights(in: window)
                        }
                    }
                }
                buttonFrameObservations.append(token)
            }
        }

        deinit {
            for token in observations { NotificationCenter.default.removeObserver(token) }
            for token in buttonFrameObservations { NotificationCenter.default.removeObserver(token) }
        }
    }
}

public extension Notification.Name {
    /// Posted (with `userInfo["isFullScreen"]`) when the configured window enters or exits native
    /// fullscreen, so chrome views that lay out around the title bar can adapt. The `object` is the window.
    static let aislopdeskWindowFullScreenDidChange = Notification.Name("aislopdeskWindowFullScreenDidChange")
}

#else

/// Non-macOS stub: the borderless custom-title-bar foundation is macOS-only (it pokes `NSWindow` /
/// titlebar internals), so on other platforms `WindowConfigurator` is a transparent no-op view. This lets
/// shared call sites attach `.background(WindowConfigurator())` unconditionally and still type-check.
public struct WindowConfigurator: View {
    /// Accepted for source compatibility with the macOS configurator; ignored on this platform.
    public var configVersion: Int
    /// Accepted for source compatibility with the macOS configurator; ignored on this platform.
    public var uiScalePreset: UIScale.Preset

    /// Create a no-op configurator. Mirrors the macOS initializer so the same call site compiles everywhere.
    public init(
        configVersion: Int = 0,
        uiScalePreset: UIScale.Preset = UIScale.shared.preset,
    ) {
        self.configVersion = configVersion
        self.uiScalePreset = uiScalePreset
    }

    public var body: some View { Color.clear }
}

#endif
#endif
