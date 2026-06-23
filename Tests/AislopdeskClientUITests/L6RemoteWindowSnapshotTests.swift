// L6RemoteWindowSnapshotTests — a HEADLESS EAGER/STATIC ImageRenderer harness for the L6 remote-window
// layer (RemoteWindowPlaceholderView / RemoteWindowPicker / RemoteWindowRow). Sibling of the L2/L3/L4/L5
// harnesses.
//
// HANG-SAFETY: NO VideoWindowFactory is registered, so RemoteWindowLeafView would render the placeholder —
// but these snapshots render the placeholder + picker views DIRECTLY (never the leaf's activation path),
// and no SCStream / VTCompression / VTDecompression / Metal / socket is ever instantiated. The picker's
// list is populated by a SYNTHETIC `RemoteWindowDiscovery.shared` closure that just returns value summaries.
//
// INFORMATIONAL, NOT A GATE — it asserts only that the renders were produced (a bitmap came back), never on
// pixels. The whole body is `#if os(macOS)` and SKIPS (never fails) on a headless GPU.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

#if os(macOS)
@MainActor
final class L6RemoteWindowSnapshotTests: XCTestCase {
    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"

    private func renderPNG(_ view: some View, size: CGSize, to outPath: String) -> Bool {
        let bg = Color(red: 29.0 / 255.0, green: 32.0 / 255.0, blue: 34.0 / 255.0)
        let renderer = ImageRenderer(
            content: view
                .environment(\.theme, DesignTokens(theme: WarpTheme()))
                .frame(width: size.width, height: size.height)
                .background(bg),
        )
        renderer.scale = 1.0
        renderer.isOpaque = true
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: size.width, height: size.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: outPath)) } catch { return false }
        return true
    }

    func testRendersRemoteWindowPrimitivesHeadlessly() async throws {
        Fonts.register()
        try? FileManager.default.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        // --- Placeholder, all three states ---
        for (state, name) in [
            (RemoteWindowPlaceholderView.State.connecting, "connecting"),
            (.gated, "gated"),
            (.unbound, "unbound"),
        ] {
            let view = RemoteWindowPlaceholderView(state: state, title: "Xcode — Build")
            guard renderPNG(
                view,
                size: CGSize(width: 480, height: 320),
                to: Self.shotsDir + "/render-remote-placeholder-\(name).png",
            )
            else { throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)") }
        }

        // --- Picker (populated via a synthetic discovery seam, no video stack) ---
        RemoteWindowDiscovery.shared = { _, _, _ in
            [
                RemoteWindowSummary(windowID: 1, appName: "Safari", title: "Apple", width: 1200, height: 800),
                RemoteWindowSummary(windowID: 2, appName: "Xcode", title: "aislopdesk", width: 1440, height: 900),
                RemoteWindowSummary(windowID: 3, appName: "Terminal", title: "", width: 800, height: 600),
            ]
        }
        defer { RemoteWindowDiscovery.shared = nil }
        let model = RemoteWindowModel()
        await model.refresh()
        XCTAssertEqual(model.availableWindows.count, 3)

        // The live `RemoteWindowPicker` card carries an interactive `.plain` `TextField` and a lazy
        // `ScrollView`/`LazyVStack`, neither of which materializes correctly under the offscreen
        // `ImageRenderer` (the field paints its unrendered first-responder placeholder; the lazy list
        // stays empty). So we render an EAGER/STATIC mirror of the SAME card — identical token vocabulary
        // (surface2 card @ dialog radius + outline hairline, the real header, a static filter-field
        // surface) — populated with the real eager `RemoteWindowRow`s in a plain `VStack`.
        let picker = RemoteWindowPickerStaticMirror(windows: model.availableWindows)
        XCTAssertTrue(renderPNG(
            picker,
            size: CGSize(width: 600, height: 520),
            to: Self.shotsDir + "/render-remote-picker.png",
        ))

        // --- One picker row ---
        let row = RemoteWindowRow(
            summary: RemoteWindowSummary(windowID: 2, appName: "Xcode", title: "aislopdesk", width: 1440, height: 900),
            onOpen: {},
        )
        XCTAssertTrue(renderPNG(
            row,
            size: CGSize(width: 400, height: 48),
            to: Self.shotsDir + "/render-remote-row.png",
        ))
    }

    /// (b) A REMOTE-WINDOW PANE chrome composed from the L3 primitives, EAGER/STATIC:
    /// `PaneHeader("macstudio — Safari")` over a placeholder video content rect (the headless
    /// `RemoteWindowPlaceholderView`, which is exactly what a remote-GUI leaf renders with no
    /// `VideoWindowFactory`) with a `CwdPill` pinned bottom-left as the cwd/controls area. Pure
    /// `VStack`/`ZStack` composition — no store, GeometryReader, socket, SCStream, VT, or Metal.
    func testRendersRemoteWindowPaneChromeHeadlessly() throws {
        Fonts.register()
        try? FileManager.default.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        let pane = RemoteWindowPaneChromeSnapshot()
        guard renderPNG(
            pane,
            size: CGSize(width: 720, height: 460),
            to: Self.shotsDir + "/render-remote-pane.png",
        )
        else { throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)") }
    }

    /// An EAGER/STATIC mirror of the `RemoteWindowPicker` card: same surface2 card @ `WarpRadius.dialog`
    /// + `outline` hairline, the same accent-glyph header + title/subtitle, a static (non-`TextField`)
    /// filter-field surface, and the populated list as the real eager `RemoteWindowRow`s in a plain
    /// `VStack` (NOT the live lazy `ScrollView`). Token vocabulary matches `RemoteWindowPicker` 1:1.
    private struct RemoteWindowPickerStaticMirror: View {
        @Environment(\.theme) private var theme
        let windows: [RemoteWindowSummary]

        var body: some View {
            ZStack {
                Color(WarpShadow.modalBackdrop).ignoresSafeArea()
                VStack(alignment: .leading, spacing: WarpSpace.xl) {
                    // Header — mirrors RemoteWindowPicker.header.
                    HStack(spacing: WarpSpace.m) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: WarpType.headerSize, weight: .regular))
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Open a Remote Window")
                                .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                                .foregroundStyle(theme.textMain)
                            Text("Stream a window from the host into a pane")
                                .font(WarpType.ui(WarpType.overlineSize))
                                .foregroundStyle(theme.textSub)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.clockwise").foregroundStyle(theme.textSub)
                        Image(systemName: "xmark").foregroundStyle(theme.textSub)
                    }
                    // Static filter-field surface — mirrors RemoteWindowPicker.filterField (no live TextField).
                    HStack(spacing: WarpSpace.s) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                        Text("Filter windows…")
                            .font(WarpType.ui(WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarpSpace.m)
                    .frame(height: WarpSize.controlHeightSmall)
                    .background(
                        RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.surface1),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                            .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
                    )
                    // Populated list — the REAL eager rows, in a plain (non-lazy) VStack.
                    VStack(spacing: 0) {
                        ForEach(windows) { window in
                            RemoteWindowRow(summary: window, onOpen: {})
                        }
                    }
                }
                .padding(WarpSpace.dialogHorizontal)
                .frame(width: 440)
                .background(
                    RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous).fill(theme.surface2),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                        .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// An EAGER mirror of a remote-window pane: a `PaneHeader` titled like a streamed host window over the
    /// `RemoteWindowPlaceholderView` content rect, with a `CwdPill` overlay bottom-left for the controls
    /// area. Mirrors `L3PaneChromeSnapshotOdiffTests.TwoPaneChromeSnapshot` (same token vocabulary).
    private struct RemoteWindowPaneChromeSnapshot: View {
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(spacing: 0) {
                PaneHeader(title: "macstudio — Safari", isActive: true, isInSplit: true)
                ZStack(alignment: .bottomLeading) {
                    // The placeholder IS the remote-GUI pane's headless content rect (no factory ⇒ this view).
                    RemoteWindowPlaceholderView(state: .connecting, title: "macstudio — Safari")
                    CwdPill(cwd: "~/src/aislopdesk", interactive: false)
                        .padding(WarpSpace.m)
                }
            }
            .background(theme.background)
            .overlay(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                    .strokeBorder(theme.splitPaneBorder, lineWidth: WarpBorder.width),
            )
        }
    }
}
#endif
