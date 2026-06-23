// L5PaletteSnapshotTests — a FOCUSED, HEADLESS EAGER/STATIC ImageRenderer harness for the L5 command
// palette (CommandPaletteView / PaletteRow / FilterChip — warp-overlays-actions.md §1). Sibling of the
// broader L5OverlaySnapshotTests, but pinned to the palette's EXACT card geometry (640×464) and rendered
// EAGERLY so the result rows actually materialize under the offscreen renderer.
//
// WHY A SEPARATE EAGER CARD: `CommandPaletteView.resultList` wraps its rows in a `ScrollView`, and a
// headless `ImageRenderer` does not lay out / paint scroll content (the existing L5 palette shot shows the
// chips but a blank list). To produce a faithful palette snapshot we reproduce the card's chrome verbatim
// (surface_2 fill, 8pt radius, 1pt outline border, the standard drop-shadow) and stack the SAME
// `PaletteRow`/`FilterChip`/separator views in an EAGER `VStack` — no ScrollView — so the rows paint.
//
// EAGER/STATIC discipline: every sub-view is rendered with `staticMirror: true` (at-rest fills, no hover,
// no first-responder TextField). The whole body is `#if os(macOS)` + guarded on `ImageRenderer` producing
// a bitmap (SKIPS, never fails, on a headless GPU). No socket / PTY / Ghostty / VideoToolbox / Metal /
// SCStream is instantiated.
//
// INFORMATIONAL, NOT A GATE — it asserts only that the renders were produced (a bitmap came back), never
// on pixels. The live-Warp reference has the palette CLOSED, so there is no meaningful odiff to run; this
// pass is a visual self-check of the SwiftUI palette against the Warp palette spec.

import AislopdeskDesignSystem
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

#if os(macOS)
@MainActor
final class L5PaletteSnapshotTests: XCTestCase {
    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"

    /// The palette's frozen card geometry (CommandPaletteView: width 640, maxHeight 464).
    private static let paletteSize = CGSize(width: 640, height: 464)
    /// A representative dimmed-workspace canvas the palette floats over (a bit larger than the card so the
    /// drop-shadow + the 8pt radius read against a backdrop, like the live overlay).
    private static let canvasSize = CGSize(width: 800, height: 600)

    /// A single-row crop (the row + its outer highlight gutter at the palette card width).
    private static let rowSize = CGSize(width: 640, height: 48)

    /// Render `view` to a 1× PNG of exactly `size` over `bg`, write it to `outPath`. Returns false (skip)
    /// when `ImageRenderer` cannot produce a bitmap here.
    private func renderPNG(_ view: some View, size: CGSize, bg: Color, to outPath: String) -> Bool {
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

    // MARK: Representative palette data (a zero-state-style mix: chips + Recents + Actions, ~8 rows)

    /// The chip categories (the zero-state filter row), in the mixer's registration order.
    private static let chipFilters: [QueryFilter] = [.actions, .tabs, .files, .conversations, .repos]

    /// ~8 result rows across two sections, exercising every row variant the spec calls out:
    /// title-only, title+subtitle, with/without a right-aligned shortcut chip, plus two separators.
    private static let demoItems: [PaletteItem] = [
        .separator("Recents", filter: .actions),
        PaletteItem(
            id: "demo.recent.split", icon: "rectangle.split.2x1", title: "Split Pane Right",
            subtitle: "~/src/aislopdesk", shortcut: nil, filter: .actions, action: .noOp,
        ),
        PaletteItem(
            id: "demo.recent.reconnect", icon: "arrow.clockwise", title: "Reconnect Pane",
            subtitle: "macstudio:7799", shortcut: "⇧⌘R", filter: .actions, action: .noOp,
        ),
        .separator("Actions", filter: .actions),
        PaletteItem(
            id: "demo.newTab", icon: "plus.rectangle", title: "New Tab",
            subtitle: nil, shortcut: "⌘T", filter: .actions, action: .noOp,
        ),
        PaletteItem(
            id: "demo.newRemote", icon: "rectangle.on.rectangle", title: "New Remote Window Tab",
            subtitle: nil, shortcut: "⌥⌘N", filter: .actions, action: .noOp,
        ),
        PaletteItem(
            id: "demo.closePane", icon: "xmark.square", title: "Close Pane",
            subtitle: nil, shortcut: "⌘W", filter: .actions, action: .noOp,
        ),
        PaletteItem(
            id: "demo.toggleZoom", icon: "arrow.up.left.and.arrow.down.right", title: "Toggle Maximize Pane",
            subtitle: nil, shortcut: "⇧⌘↩", filter: .actions, action: .noOp,
        ),
        PaletteItem(
            id: "demo.settings", icon: "slider.horizontal.3", title: "Open Settings",
            subtitle: nil, shortcut: nil, filter: .actions, action: .noOp,
        ),
    ]

    /// The palette card, reproduced EAGERLY (no ScrollView) so the rows paint headlessly. Chrome is verbatim
    /// from `CommandPaletteView.body` (surface_2 fill, dialog radius, 1pt outline border, std drop-shadow).
    private struct EagerPaletteCard: View {
        @Environment(\.theme) private var theme
        let chips: [QueryFilter]
        let items: [PaletteItem]
        /// The index into `items` that is keyboard-selected (so one row shows the at-rest highlight fill).
        let selectedIndex: Int

        var body: some View {
            VStack(spacing: 0) {
                // Search field (static mirror — placeholder text, no first-responder).
                HStack(spacing: WarpSpace.l) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: WarpSize.iconGlyph))
                        .foregroundStyle(theme.textSub)
                    Text("Search for a command")
                        .font(WarpType.ui(WarpType.paletteSize))
                        .foregroundStyle(theme.textSub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, WarpSpace.dialogHorizontal)
                .padding(.vertical, WarpSpace.xxl)

                Divider().overlay(theme.outline)

                // Zero-state filter chips.
                FilterChipRow(filters: chips)
                    .padding(.horizontal, WarpSpace.dialogHorizontal)
                    .padding(.vertical, WarpSpace.m)

                // EAGER results list (no ScrollView).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(
                            item: item,
                            isSelected: index == selectedIndex,
                            staticMirror: true,
                            onRun: {},
                        )
                    }
                }
                .padding(.vertical, WarpSpace.s)

                Spacer(minLength: 0)
            }
            .frame(width: 640)
            .frame(maxHeight: 464)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                    .fill(theme.surface2),
            )
            .overlay(
                RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                    .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
            )
            .shadow(
                color: theme.shadowColor,
                radius: WarpShadow.blur,
                x: WarpShadow.offset.width,
                y: WarpShadow.offset.height,
            )
        }
    }

    /// A simple eager chip row (the wrapping FlowChips collapse to one HStack here — 5 chips fit at 640pt).
    private struct FilterChipRow: View {
        let filters: [QueryFilter]
        var body: some View {
            HStack(spacing: WarpSpace.m) {
                ForEach(filters, id: \.self) { filter in
                    FilterChip(filter: filter, isSelected: false, staticMirror: true, onSelect: {})
                }
                Spacer(minLength: 0)
            }
        }
    }

    func testRendersPaletteCardHeadlessly() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        // A dimmed workspace backdrop (Warp's blurred-background-overlay tint ≈ black @ 70% over the
        // sampled #1D2022 surface — here we just use the dim tone the card floats over).
        let dimmedBg = Color(red: 12.0 / 255.0, green: 13.0 / 255.0, blue: 15.0 / 255.0)

        // The 4th row ("New Tab", first Actions entry) is keyboard-selected so the highlight fill shows.
        let card = EagerPaletteCard(chips: Self.chipFilters, items: Self.demoItems, selectedIndex: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        let palettePath = Self.shotsDir + "/render-palette.png"
        guard renderPNG(card, size: Self.canvasSize, bg: dimmedBg, to: palettePath) else {
            throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)")
        }

        print("=== L5 PALETTE SNAPSHOT (informational, 640x464 card over dimmed bg) ===")
        print("artifacts in: \(Self.shotsDir)")
        XCTAssertTrue(fm.fileExists(atPath: palettePath))
    }

    /// A single row sitting on the real surface_2 card fill (so the selected highlight reads against the
    /// card tone it actually composites over, not an arbitrary canvas color).
    private struct RowOnCard: View {
        @Environment(\.theme) private var theme
        let item: PaletteItem
        let isSelected: Bool
        var body: some View {
            PaletteRow(item: item, isSelected: isSelected, staticMirror: true, onRun: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(theme.surface2)
        }
    }

    func testRendersSingleRowSelectedVsUnselected() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        // A representative row carrying icon + title + subtitle + a right-aligned shortcut chip.
        let demoRow = PaletteItem(
            id: "demo.row", icon: "arrow.clockwise", title: "Reconnect Pane",
            subtitle: "macstudio:7799", shortcut: "⇧⌘R", filter: .actions, action: .noOp,
        )

        // The crop bg is the card surface_2 tone (RowOnCard paints it), so the outer canvas is irrelevant.
        let cardTone = Color(red: 12.0 / 255.0, green: 13.0 / 255.0, blue: 15.0 / 255.0)
        let unselected = RowOnCard(item: demoRow, isSelected: false)
        let selected = RowOnCard(item: demoRow, isSelected: true)

        let unselectedPath = Self.shotsDir + "/render-paletterow-unselected.png"
        guard renderPNG(unselected, size: Self.rowSize, bg: cardTone, to: unselectedPath) else {
            throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)")
        }
        let selectedPath = Self.shotsDir + "/render-paletterow-selected.png"
        XCTAssertTrue(renderPNG(selected, size: Self.rowSize, bg: cardTone, to: selectedPath))

        print("=== L5 PALETTE ROW SNAPSHOT (informational, selected vs unselected) ===")
        print("artifacts in: \(Self.shotsDir)")
        XCTAssertTrue(fm.fileExists(atPath: unselectedPath))
        XCTAssertTrue(fm.fileExists(atPath: selectedPath))
    }
}
#endif
