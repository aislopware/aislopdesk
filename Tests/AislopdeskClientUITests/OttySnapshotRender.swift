// otty visual-verification harness (L10) — renders an otty chrome showcase to a PNG via ImageRenderer so the
// Paper palette + component kit can be eyeballed headlessly (no GUI/TCC). Opt-in: INERT unless the env var
// `OTTY_SNAPSHOT_OUT=<path.png>` is set, so `swift test` / `make check` never write a file. Run on demand:
//   OTTY_SNAPSHOT_OUT="$PWD/.build/otty-showcase.png" swift test --filter OttySnapshotRender
// It renders a hand-built mock of the real chrome from the SAME token layer + component kit, so a palette /
// component regression shows up visually. It is NOT a pixel-diff CI gate.

#if canImport(SwiftUI) && canImport(AppKit)
import AislopdeskWorkspaceCore
import AppKit
import SFSafeSymbols
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

final class OttySnapshotRender: XCTestCase {
    @MainActor
    func testRenderOttyShowcase() throws {
        // Opt-in only: inert under `swift test` / `make check` unless an output path is requested.
        guard let out = ProcessInfo.processInfo.environment["OTTY_SNAPSHOT_OUT"] else {
            throw XCTSkip("set OTTY_SNAPSHOT_OUT=<path.png> to render the otty showcase")
        }
        let renderer = ImageRenderer(content: OttyShowcase().frame(width: 920, height: 560))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        try png.write(to: URL(fileURLWithPath: out))
        print("OTTY_SNAPSHOT_WRITTEN \(out)")
    }

    // MARK: - E2 / WI-6: opt-in render of the new overlay panels (palette + cheat sheet)

    /// Renders the live ``PaletteView`` (typed query, fzf-highlighted rows, a ✓ toggled gutter) and the
    /// ``KeyboardCheatSheetView`` (the full grouped binding table) on a dimmed scrim so the E2 overlays can be
    /// eyeballed headlessly — the SAME `ImageRenderer` opt-in idiom as `testRenderOttyShowcase`, NO CI gate.
    /// Opt-in via a directory (not the showcase's single-file `OTTY_SNAPSHOT_OUT`, which it would otherwise
    /// clobber): `OTTY_OVERLAY_SNAPSHOT_DIR=<dir>` writes `palette.png` + `cheatsheet.png` into it. Inert
    /// (skipped) otherwise. Built over a headless tree-model store (reusing this target's `MountTestPaneSession`
    /// session double) so it never opens a socket or touches video/Metal (the hang-safety rule).
    @MainActor
    func testRenderOverlayPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["OTTY_OVERLAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set OTTY_OVERLAY_SNAPSHOT_DIR=<dir> to render the E2 overlay panels")
        }

        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let overlay = OverlayCoordinator(store: store)
        overlay.openPalette()
        overlay.paletteQuery = "split" // a typed query so the fzf highlight runs render

        // The sidebar row shows its ✓ — exercise the toggled-state gutter the host wires from chrome.
        let palette = PaletteView(
            coordinator: overlay,
            store: store,
            toggledState: { $0.id == "action.toggleSidebar" },
        )
        try render(scrimmed(palette), size: CGSize(width: 920, height: 620), to: dir, named: "palette.png")

        let cheat = KeyboardCheatSheetView(coordinator: overlay)
        try render(scrimmed(cheat), size: CGSize(width: 920, height: 700), to: dir, named: "cheatsheet.png")
    }

    /// Center an overlay panel on the dimmed scrim + window background, the way `OverlayHostView` composes it.
    @MainActor
    private func scrimmed(_ panel: some View) -> some View {
        ZStack {
            Otty.Surface.window
            Otty.State.shadow // the host's dim scrim role
            panel
        }
    }

    /// Rasterize `content` at @2x and write a PNG into `dir`. Fails (not skips) if the renderer yields nothing —
    /// reaching here means the env opt-in was set, so a nil image is a real regression in the panel's layout.
    @MainActor
    private func render(_ content: some View, size: CGSize, to dir: String, named name: String) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let out = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try png.write(to: out)
        print("OTTY_SNAPSHOT_WRITTEN \(out.path)")
    }
}

/// A static mock of the otty chrome, built from the real token layer + component kit. Mirrors otty's resting
/// window: a "TABS" sidebar (white-card active tab via `OttySidebarRow` + a hamburger `OttySectionHeader`
/// accessory) beside a FLUSH, borderless two-pane terminal on paper — NO floating card, NO accent ring, NO
/// per-pane header bar, NO cwd pill and NO right inspector. Green appears ONLY on the prompt `❯` glyph
/// (otty's accent rationing), never as chrome.
private struct OttyShowcase: View {
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(width: 920, height: 560)
        .background(Otty.Surface.window)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            OttySectionHeader("Tabs") {
                Image(systemSymbol: .line3Horizontal)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Otty.Text.icon)
            }
            OttySidebarRow(symbol: .terminal, title: "~/aislopdesk", badge: "zsh", isSelected: true) {}
            OttySidebarRow(symbol: .terminal, title: "build", badge: "zsh", isSelected: false) {}
            OttySidebarRow(symbol: .display, title: "Remote window", isSelected: false) {}
            Spacer()
        }
        .padding(Otty.Metric.space2)
        .frame(width: Otty.Metric.sidebarWidth)
        .background(Otty.Surface.sidebar)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // otty puts the active path in the window titlebar, centered + muted — not a per-pane header bar.
            Text("~/aislopdesk")
                .font(.system(size: Otty.Typeface.base))
                .foregroundStyle(Otty.Text.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Otty.Metric.paneHeaderHeight)
            // Two flush, borderless terminal panes separated by a single hairline divider (otty's split).
            HStack(spacing: 0) {
                terminalPane(
                    promptPath: "~",
                    command: "swift build",
                )
                Rectangle().fill(Otty.Line.divider).frame(width: Otty.Metric.hairline)
                terminalPane(
                    promptPath: "~/aislopdesk",
                    command: nil,
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Otty.Surface.card) // flush paper terminal surface (#FCFBF9), not a brighter-white card
    }

    private func terminalPane(promptPath: String, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("\(promptPath) ").foregroundStyle(Otty.Status.info)
                + Text("via ").foregroundStyle(Otty.Text.secondary)
                + Text("🥭 jmango").foregroundStyle(Otty.Status.ok))
                .font(.system(size: 13, design: .monospaced))
            (Text("/\\ - τ -▽ ").foregroundStyle(Otty.Text.secondary)
                + Text("❯ ").foregroundStyle(Otty.State.accent) // the ONLY green — otty's accent rationing
                + Text(command ?? "").foregroundStyle(Otty.Text.primary))
                .font(.system(size: 13, design: .monospaced))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Otty.Metric.space3)
    }
}
#endif
