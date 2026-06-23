// L4FooterSnapshotTests — a HEADLESS EAGER/STATIC snapshot harness for the L4 Claude-Code bottom
// integration bar (AgentInputFooter + FooterPill + SuggestionPill). Sibling of the L2/L3 odiff harnesses.
//
// BG-TONE FIX (the recurring finding): the live-Warp footer paints over surface_1 == #1D2022, but the
// `WarpTheme` background SEED is pure #000000, so its derived surface_1 is a near-black gray. Rendering a
// transparent-edged component over `Color.black` (the old L2/L3 idiom) therefore diffs the *background*
// tone, not the *component*. So here we render every footer view over the SAMPLED live-Warp surface bg
// (`#1D2022`, measured from warp-main-window.png) — the same tone the reference crops sit on — so the odiff
// metric reflects component fidelity, not a bg-seed mismatch. The footer/pills still paint their own
// `theme.surface1`/green fills on top; the sampled bg only governs the transparent gutters + edges.
//
// EAGER/STATIC discipline: every footer sub-view is non-lazy (HStack/Text/Image — no ScrollView /
// LazyVStack / interactive TextField). All pills are rendered with `staticMirror: true` so they paint
// their at-rest fill (no hover first-responder). The whole body is `#if os(macOS)` + guarded on
// ImageRenderer producing a bitmap (SKIPS, never fails, on a headless GPU). No socket / PTY / Ghostty /
// VideoToolbox / Metal / SCStream is instantiated.
//
// INFORMATIONAL, NOT A GATE — it never `XCTFail`s on a pixel delta; it just produces the per-component
// diff numbers + diff PNGs so the L4 chrome can be iterated toward parity.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

#if os(macOS)
@MainActor
final class L4FooterSnapshotTests: XCTestCase {
    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"
    private static let odiffBinary = "/opt/homebrew/bin/odiff"

    /// The live-Warp footer surface tone (#1D2022), sampled from warp-main-window.png. We composite every
    /// render over THIS, not #000, so the odiff metric isn't dominated by the bg-seed mismatch (see header).
    private static let warpSurfaceBg = Color(
        red: 29.0 / 255.0, green: 32.0 / 255.0, blue: 34.0 / 255.0,
    )

    // Reference-crop geometries (taken from warp-main-window.png, 1280×800 @1×):
    //   ref-bottombar.png      1030×22  — the full footer row (x 250..1280): ✳ + green pill + + + pills + cwd.
    //   ref-suggestionpill.png  220×21  — the green "↓ Enable Claude Code notifications ✕" chip alone.
    //   ref-pill.png            106×21  — a standard FooterPill ("/remote-control") alone.
    private static let footerSize = CGSize(width: 1030, height: 22)
    private static let greenPillSize = CGSize(width: 220, height: 21)
    private static let pillSize = CGSize(width: 106, height: 21)

    /// Render `view` to a 1× PNG of exactly `size`, composited over the SAMPLED Warp surface bg (#1D2022),
    /// and write it to `outPath`. Returns false (skip) when `ImageRenderer` cannot produce a bitmap here.
    private func renderPNG(_ view: some View, size: CGSize, to outPath: String) -> Bool {
        let renderer = ImageRenderer(
            content:
            view
                .environment(\.theme, DesignTokens(theme: WarpTheme()))
                .frame(width: size.width, height: size.height)
                .background(Self.warpSurfaceBg),
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

    /// Run odiff for one (ref, render) pair → a human-readable summary line, or nil if it could not run.
    /// Always informational — the harness never asserts on the delta.
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

    func testSnapshotFooterDiffVsWarp() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        // --- AgentInputFooter: a coordinator with NO preferences (suggestion chip shows by default) + the
        // reference cwd. staticMirror so the pills paint their at-rest fills (no hover first-responder). ---
        let coordinator = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: InputBarModel(), preferences: nil,
            cwd: "~/.config", isRemote: false,
        )
        let footer = AgentInputFooter(coordinator: coordinator, cwd: "~/.config", staticMirror: true)
        let footerPath = Self.shotsDir + "/render-bottombar.png"
        guard renderPNG(footer, size: Self.footerSize, to: footerPath) else {
            throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)")
        }

        // --- SuggestionPill (the green chip) in isolation. ---
        let greenPill = SuggestionPill(
            agentName: "Claude Code", staticMirror: true, onEnable: {}, onDismiss: {},
        )
        let greenPath = Self.shotsDir + "/render-suggestionpill.png"
        XCTAssertTrue(renderPNG(greenPill, size: Self.greenPillSize, to: greenPath))

        // --- A single standard FooterPill ("/remote-control"), at rest (the reference pill). ---
        let standardPill = FooterPill(
            systemIcon: "phone", label: "/remote-control",
            help: "Start remote control", staticMirror: true, action: {},
        )
        let pillPath = Self.shotsDir + "/render-pill.png"
        XCTAssertTrue(renderPNG(standardPill, size: Self.pillSize, to: pillPath))

        // --- odiff each pair (informational) ---
        let footerSummary = runOdiff(
            ref: Self.shotsDir + "/ref-bottombar.png",
            render: footerPath,
            diffOut: Self.shotsDir + "/diff-bottombar.png",
        )
        let greenSummary = runOdiff(
            ref: Self.shotsDir + "/ref-suggestionpill.png",
            render: greenPath,
            diffOut: Self.shotsDir + "/diff-suggestionpill.png",
        )
        let pillSummary = runOdiff(
            ref: Self.shotsDir + "/ref-pill.png",
            render: pillPath,
            diffOut: Self.shotsDir + "/diff-pill.png",
        )

        print("=== L4 FOOTER SNAPSHOT ODIFF (informational, over sampled #1D2022 surface bg) ===")
        print("BOTTOMBAR      (1030x22): \(footerSummary ?? "n/a")")
        print("SUGGESTIONPILL (220x21):  \(greenSummary ?? "n/a")")
        print("PILL           (106x21):  \(pillSummary ?? "n/a")")
        print("artifacts in: \(Self.shotsDir)")

        // GREEN as long as the renders were produced — odiff deltas never fail it.
        XCTAssertTrue(fm.fileExists(atPath: footerPath))
        XCTAssertTrue(fm.fileExists(atPath: greenPath))
        XCTAssertTrue(fm.fileExists(atPath: pillPath))
    }
}
#endif
