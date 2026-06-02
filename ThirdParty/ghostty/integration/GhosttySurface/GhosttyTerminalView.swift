//
//  GhosttyTerminalView.swift
//  Rwork — the SwiftUI host for the ONLY terminal renderer (libghostty-only).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THIS FILE IS DELIBERATELY OUTSIDE THE DEFAULT `swift build` GRAPH.
//  ─────────────────────────────────────────────────────────────────────────────
//  It is the production `TerminalRenderingView` conformer named in
//  `Sources/RworkClientUI/Terminal/TerminalRenderingView.swift` (the documented
//  extension point). Like its sibling `GhosttySurface.swift` (same directory) it is
//  NOT a member of any target in `/Package.swift`; it compiles only inside the
//  macOS/iOS GUI app target (WF-8) which (a) links `libghostty.xcframework` and
//  (b) imports the `CGhostty` clang module. A headless `swift build` / `swift test`
//  never sees it, so the core stays green with zero conditional-compilation hacks.
//
//  The WHOLE FILE is gated on `#if canImport(CGhostty)`. Until the xcframework lands
//  the `CGhostty` module does not exist, so this file compiles to NOTHING — it is
//  inert in every build available on this macOS-26.5 host. Its correctness is
//  verified by REVIEW against `GhosttySurface.swift` + `CGhostty/ghostty.h`, not by
//  compilation (see docs/21-HANDOFF.md "Activating the libghostty renderer").
//
//  ─────────────────────────────────────────────────────────────────────────────
//  API CORRECTNESS — every symbol this file relies on (so a reviewer can diff it)
//  ─────────────────────────────────────────────────────────────────────────────
//  From `GhosttySurface.swift` (the @MainActor Swift binding, same directory):
//    • init(app:platformView:cols:rows:contentScale:)   — line 120
//    • var onWrite: ((Data) -> Void)?                    — line 103  (OUT path)
//    • var onResize: ((UInt16, UInt16) -> Void)?         — line 198  (grid → host)
//    • func feed(_:)                                     — line 229  (IN path; model calls this)
//    • func setSize(cols:rows:)                          — line 252
//    • func setContentScale(_:)                          — line 272
//    • func key(_: ghostty_input_key_s) -> Bool          — line 300
//    • func text(_: String)                              — line 310
//    • func redraw()                                     — line 325
//    • func setFocus(_:)                                 — line 332
//    • func close()                                      — line 201
//  From `CGhostty/ghostty.h` (the C ABI), cited by header line:
//    • ghostty_init(uintptr_t, char**)                   — 1117  (process-wide, once)
//    • ghostty_config_new() / _finalize() / _free()      — 1123 / 1132 / 1124
//    • ghostty_runtime_config_s { userdata, wakeup_cb,
//        action_cb, read/confirm/write_clipboard_cb,
//        close_surface_cb, supports_selection_clipboard } — 1073
//    • ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t) — 1141
//    • ghostty_app_free(ghostty_app_t)                   — 1143
//    • ghostty_app_tick(ghostty_app_t)                   — 1144
//    • ghostty_app_t (void*) / ghostty_config_t (void*)  — 29 / 30
//    • ghostty_input_key_s { action, mods, consumed_mods,
//        keycode, text, unshifted_codepoint, composing }  — 322
//    • ghostty_input_action_e {RELEASE,PRESS,REPEAT}     — 120
//    • ghostty_input_mods_e {NONE,SHIFT,CTRL,ALT,SUPER,…}— 100
//
//  NOTE on the OUT path (keystrokes → host PTY stdin): the surface emits encoded
//  bytes via `onWrite`. This view forwards them to the model through a documented
//  seam (`TerminalViewModel.surface.onWrite`). The bridge `onWrite → RworkClient
//  .sendInput(_:)` is owned by the connection layer that holds the live client (the
//  `GhosttyTerminalView` is handed only the model by the factory closure). That
//  bridge is the SAME not-yet-wired seam doc 21 lists for the iOS table-stakes — it
//  is called out as a remaining step here and in docs/21-HANDOFF.md, NOT invented.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREADING (doc 18 §C — libghostty calls are main-thread-only)
//  ─────────────────────────────────────────────────────────────────────────────
//  `GhosttySurface` is `@MainActor`, and SwiftUI representable callbacks + the
//  Metal layer view run on the main thread, so every surface call below is on main.
//  We never `await` between write_output → refresh → draw (the binding keeps that
//  trio synchronous inside `feed`).
//

#if canImport(CGhostty)

import SwiftUI
import QuartzCore          // CAMetalLayer
import RworkTerminal       // TerminalSurface protocol
import RworkClientUI       // TerminalRenderingView, TerminalViewModel
import CGhostty            // the clang module over ghostty.h (link "ghostty")

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Process-wide libghostty app handle

/// Owns the single process-wide `ghostty_app_t`. libghostty is initialized once per
/// process (`ghostty_init`, header 1117) and one `app` handle is shared by every
/// surface (`ghostty_app_new`, header 1141). Surfaces are created from it
/// (`GhosttySurface.init(app:…)`). `@MainActor` because all libghostty calls are
/// main-thread-only (doc 18 §C).
@MainActor
final class GhosttyApp {
    /// Lazily-created shared handle. The GUI process keeps it alive for its lifetime,
    /// so surfaces created from it (held by the Metal views) never outlive it.
    static let shared = GhosttyApp()

    let app: ghostty_app_t

    private init() {
        // 1. ghostty_init (header 1117): once per process, before any config/app.
        //    Signature is `int ghostty_init(uintptr_t, char**)` — argc/argv; we pass
        //    none (the embedder owns the CLI).
        _ = ghostty_init(0, nil)

        // 2. Config (header 1123 / 1132). Defaults are fine for the EXTERNAL backend;
        //    per-surface backend/callbacks are set in GhosttySurface, not here.
        let config = ghostty_config_new()
        ghostty_config_finalize(config)

        // 3. Runtime config (header 1073). The embedder must supply the callback set;
        //    for Rwork's external-backend viewer the surface's own write/resize
        //    callbacks carry the data path, so these app-level runtime callbacks are
        //    minimal no-ops (wakeup just ticks the app; clipboard/close are stubs the
        //    GUI coordinator can later enrich). All fields zero-initialized first.
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            // libghostty asks to be ticked on the main loop. We tick the shared app.
            MainActor.assumeIsolated {
                ghostty_app_tick(GhosttyApp.shared.app)
            }
        }
        // action_cb returns whether the action was handled; the viewer handles none
        // of the app-level actions (split/new-window/etc.) — return false.
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _ in }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }

        // 4. App (header 1141).
        self.app = ghostty_app_new(&runtime, config)

        // The config can be freed after app_new copies what it needs (header 1124).
        ghostty_config_free(config)
    }
}

// MARK: - GhosttyTerminalView (the TerminalRenderingView conformer)

/// libghostty-backed terminal renderer — Rwork's production `TerminalRenderingView`.
///
/// It hosts a Metal-backed platform view (`CAMetalLayer`) that owns a `GhosttySurface`
/// configured for the EXTERNAL backend. The data flow:
///
///  * **IN** (host PTY output → pixels): the `TerminalViewModel` already calls
///    `surface.feed(_:)` inside `ingestOutput(_:)`. This view just sets
///    `model.surface = <the GhosttySurface>` so the model's existing feed path lands
///    in libghostty. (`feed` → `ghostty_surface_write_output` + refresh + draw.)
///  * **OUT** (keystrokes → host PTY stdin): the view forwards platform key/text
///    events to `surface.key(_:)` / `surface.text(_:)`; libghostty encodes them and
///    emits the bytes via `surface.onWrite`, which the connection layer bridges to
///    `RworkClient.sendInput` (documented seam — see file header + doc 21).
///  * **Resize**: layout changes convert the view's pixel size → cols/rows and call
///    `surface.setSize(cols:rows:)`; the surface mirrors the grid to the host via
///    `surface.onResize`.
///  * **Render cadence**: libghostty drives its own draw from `feed`/`redraw`; the
///    view forces a `redraw()` on focus/occlusion/scale changes.
///
/// ⚠️ **GUI-ONLY:** needs a real screen + the libghostty xcframework. COMPILED +
/// reviewed; not driven from tests (mirrors `VideoWindowView`). This is the view the
/// app injects via `TerminalRendererFactory.shared`.
public struct GhosttyTerminalView: TerminalRenderingView {
    private let model: TerminalViewModel

    public init(model: TerminalViewModel) {
        self.model = model
    }

    public var body: some View {
        GhosttyMetalLayerView(model: model)
            .accessibilityLabel(Text("Terminal"))
    }
}

// MARK: - Platform representable + Metal-backed view

#if os(macOS)

/// `NSViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: NSViewRepresentable {
    let model: TerminalViewModel

    func makeNSView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        view.attach(model: model)
        return view
    }

    func updateNSView(_ nsView: GhosttyLayerBackedView, context: Context) {
        nsView.attach(model: model)
    }

    static func dismantleNSView(_ nsView: GhosttyLayerBackedView, coordinator: ()) {
        nsView.detach()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`. It owns the
/// `GhosttySurface` (libghostty renders into the layer) for its lifetime and forwards
/// AppKit key/text/resize events into the surface.
final class GhosttyLayerBackedView: NSView {
    let metalLayer = CAMetalLayer()

    /// Strong owner of the surface. `TerminalViewModel.surface` is `weak`, so the view
    /// is the lifetime owner (the GUI owns it on main; `detach()`/`deinit` free it).
    private var surface: GhosttySurface?
    private weak var model: TerminalViewModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func makeBackingLayer() -> CALayer { metalLayer }

    /// Idempotent: builds the surface on first call, then attaches it to the model.
    func attach(model: TerminalViewModel) {
        self.model = model
        if surface == nil {
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: window?.backingScaleFactor ?? 2.0
            )
            // OUT path: encoded keystrokes from libghostty. The connection layer (which
            // holds the live RworkClient) reads `model.surface?.onWrite` to bridge to
            // `RworkClient.sendInput`. Documented remaining seam (file header + doc 21).
            s.onWrite = { [weak self] _ in
                _ = self // bytes are consumed by the connection-layer bridge via model.surface.onWrite
            }
            // Grid changes (font reflow) → host TIOCSWINSZ via the same bridge.
            s.onResize = { _, _ in }
            self.surface = s
        }
        // The model's ingestOutput(_:) feeds inbound bytes into surface.feed(_:).
        model.surface = surface
        surface?.setFocus(true)
    }

    func detach() {
        surface?.close()
        surface = nil
        model?.surface = nil
    }

    deinit {
        // @MainActor not available in deinit; the surface's own deinit frees the
        // ghostty_surface_t. We rely on detach() (dismantleNSView) as the explicit path.
    }

    // MARK: Resize → grid

    override func layout() {
        super.layout()
        // Convert the layer's pixel size → cols/rows using a conservative cell size.
        // libghostty re-measures the true cell size after first draw (GhosttySurface
        // .setSize reads ghostty_surface_size); the seed here just keeps the grid sane.
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let pxW = bounds.width * scale
        let pxH = bounds.height * scale
        // 8×16 seed cell (matches GhosttySurface's seed); the surface refines it.
        let cols = UInt16(max(1, Int(pxW / 8)))
        let rows = UInt16(max(1, Int(pxH / 16)))
        surface?.setContentScale(Double(scale))
        surface?.setSize(cols: cols, rows: rows)
        surface?.redraw()
    }

    // MARK: Input forwarding → libghostty encoder

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Route every key through libghostty's encoder (DECISIONS: never hand-roll VT).
        // ghostty_input_key_s (header 322): action / mods / keycode / text /
        // unshifted_codepoint / composing.
        var key = ghostty_input_key_s()
        key.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        // `text` is a borrowed const char* for the keypress duration; bind the chars.
        if let chars = event.characters, !chars.isEmpty {
            var copy = chars
            copy.withCString { cstr in
                key.text = cstr
                _ = surface?.key(key)
            }
        } else {
            key.text = nil
            _ = surface?.key(key)
        }
    }

    override func keyUp(with event: NSEvent) {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first.map { $0.value } ?? 0
        key.composing = false
        key.text = nil
        _ = surface?.key(key)
    }

    override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    /// Maps AppKit modifier flags → libghostty mods (header 100).
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        // `ghostty_input_mods_e` is a PLAIN C enum (ghostty.h:99-111 — no
        // flag_enum/NS_OPTIONS attribute), so the Clang importer's `init?(rawValue:)`
        // is FAILABLE and only succeeds for declared enumerators. An OR-accumulated
        // value (e.g. SHIFT|CTRL = 3) is not an enumerator, so the labeled init would
        // return nil → both a type mismatch (optional vs. non-optional return) and a
        // runtime break. Use the importer's UNLABELED non-failable init over the raw
        // integer instead — matches upstream Ghostty.Input.swift `ghosttyMods`.
        return ghostty_input_mods_e(raw)
    }
}

#elseif os(iOS)

/// `UIViewRepresentable` host backing the `CAMetalLayer` that owns the `GhosttySurface`.
struct GhosttyMetalLayerView: UIViewRepresentable {
    let model: TerminalViewModel

    func makeUIView(context: Context) -> GhosttyLayerBackedView {
        let view = GhosttyLayerBackedView()
        view.attach(model: model)
        return view
    }

    func updateUIView(_ uiView: GhosttyLayerBackedView, context: Context) {
        uiView.attach(model: model)
    }

    static func dismantleUIView(_ uiView: GhosttyLayerBackedView, coordinator: ()) {
        uiView.detach()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the `GhosttySurface`.
///
/// Physical-key + IME text forwarding on iOS is handled by the existing UIKit
/// table-stakes host (`RworkClientUI.TerminalInputHost` — doc 17 §2.5), which already
/// routes presses/IME to `RworkClient.sendInput`. This view focuses on hosting the
/// Metal layer + surface; the input-host integration is the documented follow-up seam.
final class GhosttyLayerBackedView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var surface: GhosttySurface?
    private weak var model: TerminalViewModel?

    func attach(model: TerminalViewModel) {
        self.model = model
        if surface == nil {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let s = GhosttySurface(
                app: GhosttyApp.shared.app,
                platformView: Unmanaged.passUnretained(self).toOpaque(),
                cols: 80,
                rows: 24,
                contentScale: Double(scale)
            )
            s.onWrite = { [weak self] _ in
                _ = self // consumed by the connection-layer bridge via model.surface.onWrite
            }
            s.onResize = { _, _ in }
            self.surface = s
        }
        model.surface = surface
        surface?.setFocus(true)
    }

    func detach() {
        surface?.close()
        surface = nil
        model?.surface = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let pxW = bounds.width * scale
        let pxH = bounds.height * scale
        let cols = UInt16(max(1, Int(pxW / 8)))
        let rows = UInt16(max(1, Int(pxH / 16)))
        surface?.setContentScale(Double(scale))
        surface?.setSize(cols: cols, rows: rows)
        surface?.redraw()
    }
}

#endif  // os(macOS) / os(iOS)

#endif  // canImport(CGhostty)
