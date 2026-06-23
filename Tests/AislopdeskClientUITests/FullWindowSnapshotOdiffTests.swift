// FullWindowSnapshotOdiffTests — a HEADLESS EAGER/STATIC composite of the WHOLE workspace window at
// 1280×800 @1×, odiff'd against the live-Warp reference (warp-main-window.png). Sibling of the L2/L3/L4
// per-component odiff harnesses; this one measures OVERALL chrome fidelity in one shot.
//
// INFORMATIONAL, NOT A GATE: it renders with `ImageRenderer` at scale 1.0 over the live-matching theme
// base (#1D2022 — the shipping WarpTheme bg SEED), writes render-fullwindow.png + diff-fullwindow.png, and
// LOGS the odiff percentage. It NEVER `XCTFail`s on a pixel delta (pixel parity is iterated toward).
//
// EAGER/STATIC discipline (the reason this can't reuse the live `WorkspaceRootView`): the production root
// wires a `ScrollView { LazyVStack }` rail, an interactive `TextField`, a `GeometryReader`-driven
// `SplitContainer`, and live `PaneContainer`/`TerminalLeafView`s (which need a renderer factory + sessions).
// Under the offscreen `ImageRenderer` those don't materialize / paint "unavailable" fills. So this composite
// hand-assembles the SAME production components in an EAGER layout that mirrors `WorkspaceRootView.chrome`:
//   • real `WindowTopBar` (35pt)
//   • a body row of [ eager `TabRow`s on the rail panel | real `PanelSeparator` | a 2-pane split ]
//   • each split pane = real `PaneHeader` over a terminal-bg placeholder body with a real `CwdPill`
//   • the ACTIVE (left) pane carries the real `AgentInputFooter` (Claude-Code bottom bar) pinned to its base
// Everything is the production L2–L4 code; only the lazy/interactive containers are swapped for eager ones.
//
// CAVEATS (reported, not failed): the live screenshot has the OS traffic-lights cluster (top-left ~x<76,
// y<35) which this render lacks, and the live terminal panes show REAL shell/agent text whereas this paints
// a static placeholder body — both regions necessarily diff. The overall % therefore over-counts true chrome
// drift; the per-component L2–L4 numbers are the precise fidelity metric, this is the gestalt check.
//
// Hang-safety: builds a tree-backed `WorkspaceStore` with a dummy session factory — NO socket, PTY,
// Ghostty, VideoToolbox, Metal, or `SCStream` is ever instantiated.

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import SwiftUI
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

#if os(macOS)
@MainActor
final class FullWindowSnapshotOdiffTests: XCTestCase {
    private static let shotsDir =
        "/private/tmp/claude-501/-Volumes-Lacie-Workspace-oss-aislopdesk/" +
        "5361f08a-7ef1-47d1-bede-28cb51f4b4eb/scratchpad/warp-shots"
    private static let odiffBinary = "/opt/homebrew/bin/odiff"

    /// The live-matching theme base (#1D2022) — the shipping `WarpTheme` background SEED. The window
    /// composites over THIS so transparent edges sit on the same slate as the live-Warp reference.
    private static let themeBg = Color(red: 29.0 / 255.0, green: 32.0 / 255.0, blue: 34.0 / 255.0)

    // MARK: Deterministic store (mirrors warp-main-window.png)

    private final class DummyPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
        private(set) var id: PaneID
        let kind: PaneKind
        private(set) var isVideoActive = false
        init(spec: PaneSpec) {
            id = PaneID()
            kind = spec.kind
        }

        func adopt(id: PaneID) { self.id = id }
        func setVideoActive(_ active: Bool) { if kind == .remoteGUI { isVideoActive = active } }
        func pause() {}
        func resume() {}
        func teardown() {}
    }

    /// Three panes mirroring the reference: row1 ACTIVE "✳ Claude Code"/~/.config (.working), rows 2–3 plain.
    private func makeSeededStore() -> (WorkspaceStore, [PaneID]) {
        let p1 = PaneID(), p2 = PaneID(), p3 = PaneID()
        func spec(_ title: String, cwd: String) -> PaneSpec {
            PaneSpec(kind: .terminal, title: title, lastKnownCwd: cwd, lastKnownTitle: title)
        }
        let specs: [PaneID: PaneSpec] = [
            p1: spec("✳ Claude Code", cwd: "~/.config"),
            p2: spec("..s-Mac-Studio:~/.config", cwd: "~/.config"),
            p3: spec("..s-Mac-Studio:~/.config", cwd: "~/.config"),
        ]
        let tab = Tab(
            root: .split(
                id: SplitNodeID(),
                axis: .vertical,
                children: [
                    WeightedChild(weight: .flex(1), node: .leaf(p1)),
                    WeightedChild(weight: .flex(1), node: .leaf(p2)),
                    WeightedChild(weight: .flex(1), node: .leaf(p3)),
                ],
            ),
            activePane: p1,
        )
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { DummyPaneSession(spec: $0) },
        )
        store.paneAgentStatus[p1] = .working
        return (store, [p1, p2, p3])
    }

    // MARK: Render + odiff helpers (same contract as the L2–L4 harnesses)

    private func renderPNG(_ view: some View, size: CGSize, to outPath: String) -> Bool {
        let renderer = ImageRenderer(
            content:
            view
                .environment(\.theme, DesignTokens(theme: WarpTheme()))
                .frame(width: size.width, height: size.height)
                .background(Self.themeBg),
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

    // MARK: The composite snapshot

    func testFullWindowCompositeDiffVsWarp() throws {
        Fonts.register()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.shotsDir, withIntermediateDirectories: true)

        let (store, _) = makeSeededStore()
        let rows = RailRowsBuilder.rows(for: store)

        let window = FullWindowComposite(rows: rows, store: store)
        let outPath = Self.shotsDir + "/render-fullwindow.png"
        guard renderPNG(window, size: CGSize(width: 1280, height: 800), to: outPath) else {
            throw XCTSkip("ImageRenderer produced no bitmap (headless GPU unavailable)")
        }

        let summary = runOdiff(
            ref: Self.shotsDir + "/warp-main-window.png",
            render: outPath,
            diffOut: Self.shotsDir + "/diff-fullwindow.png",
        )

        print("=== FULL-WINDOW COMPOSITE ODIFF (informational, over #1D2022 theme base) ===")
        print("FULLWINDOW (1280x800): \(summary ?? "n/a")")
        print("CAVEAT: OS traffic-lights region + live terminal text necessarily differ.")
        print("artifacts in: \(Self.shotsDir)")

        XCTAssertTrue(fm.fileExists(atPath: outPath))
    }

    // MARK: Eager composite view (mirrors WorkspaceRootView.chrome with non-lazy containers)

    private struct FullWindowComposite: View {
        @Environment(\.theme) private var theme
        let rows: [RailRow]
        let store: WorkspaceStore

        var body: some View {
            VStack(spacing: 0) {
                WindowTopBar(
                    sidebarCollapsed: false,
                    onToggleSidebar: {},
                    onOpenSettings: {},
                    onOpenOmnibar: {},
                    hasUnread: false,
                )
                HStack(spacing: 0) {
                    railPanel
                    PanelSeparator()
                    splitBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(WarpSpace.workspacePadding)
            .background(theme.background)
        }

        /// Eager mirror of `VerticalTabRail.body` (no ScrollView/LazyVStack/interactive TextField).
        private var railPanel: some View {
            VStack(spacing: 0) {
                HStack(spacing: WarpSpace.s) {
                    HStack(spacing: WarpSpace.xs + WarpSpace.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12 * 0.85))
                            .foregroundStyle(theme.textSub)
                            .frame(width: 12, height: 12)
                        Text("Search tabs…")
                            .font(WarpType.ui(WarpType.uiSize))
                            .foregroundStyle(theme.textSub)
                        Spacer(minLength: 0)
                    }
                    IconButton(systemName: "line.3.horizontal.decrease", help: "View options", action: {})
                        .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
                    IconButton(systemName: "plus", help: "New tab", action: {})
                        .frame(width: WarpSize.controlHeightSmall, height: WarpSize.controlHeightSmall)
                }
                .padding(.horizontal, WarpSpace.m)
                .padding(.vertical, WarpSpace.s)

                VStack(spacing: WarpSpace.s) {
                    ForEach(rows) { row in
                        TabRow(row: row, onSelect: {}, onClose: {})
                    }
                }
                .padding(.horizontal, WarpSpace.m)
                .padding(.bottom, WarpSpace.m)

                Spacer(minLength: 0)
            }
            .frame(width: WarpSize.railWidth)
            .background(theme.fgOverlay1)
            .background(
                theme.surface1.opacity(0.9),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: WarpRadius.dialog,
                    topTrailingRadius: WarpRadius.dialog,
                ),
            )
        }

        /// Two stacked terminal-pane placeholders (active on top with the agent footer), split by a real
        /// `PaneDivider` — an eager stand-in for the store-driven `SplitContainer`.
        private var splitBody: some View {
            VStack(spacing: 0) {
                activePaneColumn
                // A full-width horizontal hairline between the stacked rows. The rail (248) + 1pt separator
                // occupy the left; the content column is the remaining width of the 1280-wide window minus
                // the 2pt workspace padding ⇒ 1280 − 2 − 248 − 1 = 1029pt.
                PaneDivider(
                    handle: SplitTreeRenderModel.DividerHandle(
                        splitID: SplitNodeID(),
                        childIndex: 0,
                        axis: .vertical, // vertical split axis == stacked rows == a HORIZONTAL hairline
                        rect: CGRect(x: 0, y: 0, width: 1029, height: 8),
                    ),
                    axisSpan: 1029,
                )
                plainPaneColumn
            }
            .background(theme.background)
        }

        private var activePaneColumn: some View {
            let coordinator = AgentInputFooterCoordinator(
                agentName: "Claude Code", inputBar: InputBarModel(), preferences: nil,
                cwd: "~/.config", isRemote: false,
            )
            return VStack(spacing: 0) {
                PaneHeader(title: "✳ Claude Code", isActive: true, isInSplit: true)
                ZStack(alignment: .bottomLeading) {
                    theme.background
                    CwdPill(cwd: "~/.config", interactive: false)
                        .padding(WarpSpace.m)
                }
                .frame(maxHeight: .infinity)
                AgentInputFooter(coordinator: coordinator, cwd: "~/.config", staticMirror: true)
            }
        }

        private var plainPaneColumn: some View {
            VStack(spacing: 0) {
                PaneHeader(title: "..s-Mac-Studio:~/.config", isActive: false, isInSplit: true)
                ZStack(alignment: .bottomLeading) {
                    theme.background
                    CwdPill(cwd: "~/.config", interactive: false)
                        .padding(WarpSpace.m)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
#endif
