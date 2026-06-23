// L5OverlaySnapshotTests — a HEADLESS EAGER/STATIC ImageRenderer harness for the L5 overlay layer
// (CommandPaletteView / PaletteRow / FilterChip / ConfirmModal / SettingsOverlay / ToastCard /
// ThemedContextMenu). Sibling of the L2/L3/L4 harnesses.
//
// EAGER/STATIC discipline: every overlay sub-view is rendered with `staticMirror: true` so it paints its
// at-rest fill (no hover, no first-responder TextField, no auto-dismiss timer). The whole body is
// `#if os(macOS)` and guarded on `ImageRenderer` producing a bitmap (SKIPS, never fails, on a headless
// GPU). No socket / PTY / Ghostty / VideoToolbox / Metal / SCStream is instantiated — the palette/modal
// bind a dummy-session tree store, which never dials.
//
// INFORMATIONAL, NOT A GATE — it asserts only that the renders were produced (a bitmap came back), never
// on pixels. It exists to prove the views render headlessly + to produce artifacts for visual iteration.

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

#if os(macOS)
@MainActor
final class L5OverlaySnapshotTests: XCTestCase {
    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(), liveModel: .tree,
            makeSession: { spec in DummyPaneSession(spec: spec) },
        )
    }

    /// Render `view` to a 1× PNG of `size` over the warp surface bg; false ⇒ skip (no bitmap on this GPU).
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

    func testRendersOverlayPrimitivesHeadlessly() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        let store = makeStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette(mode: .command)

        // --- Command palette (static mirror, zero-state with chips + catalog) ---
        // NOTE: this renders the LIVE CommandPaletteView, whose result list is a `ScrollView` — headless
        // ImageRenderer does not paint scroll content, so the list comes out blank (chips only). The
        // authoritative, fully-populated 640×464 palette shot (`render-palette.png`) is produced by
        // `L5PaletteSnapshotTests` with an EAGER (no-ScrollView) card; we write this one to a distinct path
        // so the two harnesses don't clobber each other regardless of test order.
        let palette = CommandPaletteView(coordinator: coordinator, staticMirror: true)
        guard renderPNG(
            palette, size: CGSize(width: 800, height: 700),
            to: Self.shotsDir + "/render-palette-live-scrollview.png",
        )
        else { throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)") }

        // --- Confirm modal ---
        let modal = ConfirmModal(
            title: "Close pane with a running process?",
            message: "“Terminal” still has a command running. Closing it will terminate the process.",
            onConfirm: {}, onCancel: {},
        )
        XCTAssertTrue(renderPNG(modal, size: CGSize(width: 800, height: 500), to: Self.shotsDir + "/render-modal.png"))

        // --- Settings overlay ---
        let settings = SettingsOverlay(model: SettingsModel(), staticMirror: true, onClose: {})
        XCTAssertTrue(renderPNG(
            settings,
            size: CGSize(width: 800, height: 500),
            to: Self.shotsDir + "/render-settings.png",
        ))

        // --- Toast card ---
        let toast = ToastCard(
            toast: Toast(id: "t", flavor: .success, title: "Build finished", body: "Exit 0 · 1240 ms"),
            staticMirror: true, onDismiss: {},
        )
        XCTAssertTrue(renderPNG(toast, size: CGSize(width: 500, height: 80), to: Self.shotsDir + "/render-toast.png"))

        // --- Themed context menu (pane overflow) ---
        let menu = ThemedContextMenu(
            items: ContextMenuModel.paneItems(paneID: PaneID(), lastKnownCwd: "~/src", isInSplit: true),
            store: store, onDismiss: {},
        )
        XCTAssertTrue(renderPNG(
            menu,
            size: CGSize(width: 260, height: 260),
            to: Self.shotsDir + "/render-contextmenu.png",
        ))

        print("=== L5 OVERLAY SNAPSHOT (informational) === artifacts in: \(Self.shotsDir)")
    }
}
#endif
