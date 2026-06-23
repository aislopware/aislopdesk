// L3PaneChromeSnapshotOdiffTests — a HEADLESS snapshot-odiff harness for the L3 PANE chrome
// (PaneHeader + PaneDivider + CwdPill, plus an optional two-pane SplitContainer chrome). It is the
// sibling of `L2SnapshotOdiffTests` (which covers the WindowTopBar + VerticalTabRail) and follows the
// identical shape: render each view with `ImageRenderer` at scale 1.0 over a #000 (Warp default-theme)
// background, write the PNGs to the scratchpad warp-shots dir, run `odiff` against the cropped live-Warp
// reference regions, and LOG the reported diff percentage.
//
// INFORMATIONAL, NOT A GATE: it NEVER `XCTFail`s on a pixel delta — pixel parity is driven toward in
// later layers; this just produces the numbers + artifacts so we can iterate. The whole body is
// `#if os(macOS)` + guarded on ImageRenderer producing a bitmap (SKIPS, never fails, on a headless GPU)
// and a present `odiff` binary, so it stays green in every environment.
//
// EAGER/STATIC discipline (the reason this is separate from the live views): all three components are
// already non-lazy (HStack/ZStack/Text/IconButton — no `ScrollView`/`LazyVStack`/interactive `TextField`),
// so they materialize correctly under the offscreen `ImageRenderer`. `CwdPill` is rendered with
// `interactive: false` so it paints its at-rest surface (no hover swap, no `Button` first-responder).
// `PaneDivider` is fed a synthetic `DividerHandle` rect (no store, no gesture drive). The optional
// two-pane chrome is a plain `HStack` of header+placeholder columns split by a `PaneDivider`, NOT the
// real store-driven `SplitContainer` (which needs a GeometryReader + live `PaneContainer`s).
//
// Hang-safety: nothing here instantiates a socket, PTY, Ghostty, VideoToolbox, Metal, or `SCStream`.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

#if os(macOS)
@MainActor
final class L3PaneChromeSnapshotOdiffTests: XCTestCase {
    // MARK: Output / reference locations (the orchestrator-provided scratchpad)

    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"
    private static let odiffBinary = "/opt/homebrew/bin/odiff"

    // MARK: Reference-crop geometries (taken from warp-main-window.png, 1280×800 @1×)

    //
    //   ref-paneheader.png  534×34   — the LEFT bottom-pane header strip ("..s-Mac-Studio:~/.config" + ⋮ ×).
    //   ref-divider.png      16×240  — the vertical hairline between the two bottom panes (band centered on it).
    //   ref-cwdpill.png     120×36   — the bottom-left "~/.config" cwd pill (folder glyph + path in a border).

    private static let headerSize = CGSize(width: 534, height: 34)
    private static let dividerSize = CGSize(width: 16, height: 240)
    private static let cwdPillSize = CGSize(width: 120, height: 36)

    // MARK: Render helper (identical contract to L2SnapshotOdiffTests.renderPNG)

    /// Render `view` to a 1× PNG of exactly `size` over a #000 background (the Warp default-theme window
    /// bg, so the components' transparent edges match the reference) and write it to `outPath`. Returns
    /// false (skip) when `ImageRenderer` cannot produce a bitmap in this environment.
    private func renderPNG(_ view: some View, size: CGSize, to outPath: String) -> Bool {
        let renderer = ImageRenderer(
            content:
            view
                .environment(\.theme, DesignTokens(theme: WarpTheme()))
                .frame(width: size.width, height: size.height)
                // Composite over the live-matching theme base (#1D2022) — the WarpTheme bg SEED — so the
                // components' transparent edges sit on the same slate as the live-Warp reference crops.
                .background(Color(red: 29.0 / 255.0, green: 32.0 / 255.0, blue: 34.0 / 255.0)),
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

    /// Run odiff for one (ref, render) pair, returning a human-readable diff summary line, or nil if odiff
    /// could not run / a reference is missing. Always informational — the harness never asserts on it.
    @discardableResult
    private func runOdiff(ref: String, render: String, diffOut: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.odiffBinary) else { return "odiff binary not present" }
        guard fm.fileExists(atPath: ref) else { return "reference missing: \(ref)" }
        guard fm.fileExists(atPath: render) else { return "render missing: \(render)" }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.odiffBinary)
        proc.arguments = ["--antialiasing", "--threshold", "0.1", ref, render, diffOut]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return "odiff launch failed: \(error)" }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The snapshot

    func testSnapshotPaneChromeDiffVsWarp() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        // --- PaneHeader: 534 × 34. Active + in-split so the ⋮ overflow and × close are revealed, matching
        // the reference (a non-active pane in a split still shows both because the screenshot was taken with
        // the row hovered/active). Title mirrors the reference text. ---
        let header = PaneHeader(
            title: "..s-Mac-Studio:~/.config",
            isActive: true,
            isInSplit: true,
        )
        let headerPath = Self.shotsDir + "/render-paneheader.png"
        let headerRendered = renderPNG(header, size: Self.headerSize, to: headerPath)
        guard headerRendered else { throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)") }

        // --- PaneDivider: a synthetic horizontal-axis (side-by-side columns) handle → a vertical hairline.
        // The handle rect is the full 16×240 band; the divider draws its 1.5pt `split_pane_border` hairline
        // centered in it (matching the cropped reference band). No store / gesture is wired. ---
        let dividerHandle = SplitTreeRenderModel.DividerHandle(
            splitID: SplitNodeID(),
            childIndex: 0,
            axis: .horizontal, // horizontal split axis == side-by-side columns == a VERTICAL hairline
            rect: CGRect(origin: .zero, size: Self.dividerSize),
        )
        let divider = PaneDivider(handle: dividerHandle, axisSpan: Self.dividerSize.height)
        let dividerPath = Self.shotsDir + "/render-divider.png"
        XCTAssertTrue(renderPNG(divider, size: Self.dividerSize, to: dividerPath), "divider render should succeed")

        // --- CwdPill: the at-rest, non-interactive chip (no hover swap, no Button first-responder) bound to
        // the reference cwd. Rendered over the terminal bg in a 120×36 band like the cropped reference. ---
        let cwdPill = CwdPill(cwd: "~/.config", interactive: false)
        let cwdPillPath = Self.shotsDir + "/render-cwdpill.png"
        XCTAssertTrue(renderPNG(cwdPill, size: Self.cwdPillSize, to: cwdPillPath), "cwd-pill render should succeed")

        // --- (Optional) two-pane SplitContainer chrome: two header+placeholder columns split by a real
        // `PaneDivider`. Documents how the three components compose; NOT odiff'd against a crop (the live
        // reference panes are mostly empty terminal area), just produced as a visual artifact. ---
        let twoPane = TwoPaneChromeSnapshot()
        _ = renderPNG(twoPane, size: CGSize(width: 1028, height: 360), to: Self.shotsDir + "/render-twopane-chrome.png")

        // --- odiff (informational) ---
        let headerSummary = runOdiff(
            ref: Self.shotsDir + "/ref-paneheader.png",
            render: headerPath,
            diffOut: Self.shotsDir + "/diff-paneheader.png",
        )
        let dividerSummary = runOdiff(
            ref: Self.shotsDir + "/ref-divider.png",
            render: dividerPath,
            diffOut: Self.shotsDir + "/diff-divider.png",
        )
        let cwdPillSummary = runOdiff(
            ref: Self.shotsDir + "/ref-cwdpill.png",
            render: cwdPillPath,
            diffOut: Self.shotsDir + "/diff-cwdpill.png",
        )

        // Log the numbers — this is the deliverable, NOT a gate.
        print("=== L3 PANE-CHROME SNAPSHOT ODIFF (informational) ===")
        print("PANEHEADER (534x34):  \(headerSummary ?? "n/a")")
        print("DIVIDER    (16x240):  \(dividerSummary ?? "n/a")")
        print("CWDPILL    (120x36):  \(cwdPillSummary ?? "n/a")")
        print("artifacts in: \(Self.shotsDir)")

        // GREEN as long as the renders were produced — odiff deltas never fail it.
        XCTAssertTrue(fm.fileExists(atPath: headerPath))
        XCTAssertTrue(fm.fileExists(atPath: dividerPath))
        XCTAssertTrue(fm.fileExists(atPath: cwdPillPath))
    }

    /// An EAGER two-pane chrome mirror: two columns (each = a `PaneHeader` over a black terminal-placeholder
    /// body with a `CwdPill` pinned bottom-left) split by a real `PaneDivider`. Pure composition of the L3
    /// components in plain `HStack`/`VStack`/`ZStack` — no store, GeometryReader, or `PaneContainer`.
    private struct TwoPaneChromeSnapshot: View {
        @Environment(\.theme) private var theme

        private func column(active: Bool) -> some View {
            VStack(spacing: 0) {
                PaneHeader(title: "..s-Mac-Studio:~/.config", isActive: active, isInSplit: true)
                ZStack(alignment: .bottomLeading) {
                    theme.background
                    CwdPill(cwd: "~/.config", interactive: false)
                        .padding(WarpSpace.m)
                }
            }
        }

        var body: some View {
            HStack(spacing: 0) {
                column(active: false)
                PaneDivider(
                    handle: SplitTreeRenderModel.DividerHandle(
                        splitID: SplitNodeID(),
                        childIndex: 0,
                        axis: .horizontal,
                        rect: CGRect(x: 0, y: 0, width: 8, height: 360),
                    ),
                    axisSpan: 360,
                )
                column(active: false)
            }
            .background(theme.background)
        }
    }
}
#endif
