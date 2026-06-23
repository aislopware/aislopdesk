// L4FooterLogicTests — view-LOGIC tests for the L4 Claude-Code bottom integration bar. View-model /
// pure-helper level only; NEVER instantiates Ghostty/VT/Metal/SCStream (hang-safety rule). Covers:
//   - AgentInputFooterVisibility (W5: shown only when claudeStatus != .none),
//   - FooterPillState (fill role: surface_1 rest → surface_2 hover/active; icon-only detection),
//   - SuggestionPillCopy / GreenChip blend bytes,
//   - AgentInputFooterCoordinator action ROUTING (rich toggle / file explorer / notifications / hooks),
//   - notification dismissal + enable PERSISTENCE via PreferencesStore (injected UserDefaults, W4),
//   - InputBarModel.richMode toggle (W3),
//   - FileExplorerLister / FileExplorerModel listing (pure, W2).

import AislopdeskAgentDetect
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import Foundation
import XCTest
@testable import AislopdeskClientUI

// MARK: - W5 visibility

final class AgentInputFooterVisibilityTests: XCTestCase {
    func testHiddenWhenNoAgent() {
        // claudeStatus == .none ⇒ isNone true ⇒ NOT visible.
        XCTAssertFalse(AgentInputFooterVisibility.isVisible(isNone: true))
    }

    func testShownWhenAgentActive() {
        // Any non-.none status ⇒ visible (idle/working/done/needsPermission).
        XCTAssertTrue(AgentInputFooterVisibility.isVisible(isNone: false))
    }

    func testEveryNonNoneStatusMapsToVisible() {
        for status in ClaudeStatus.allCases {
            let isNone = (status == .none)
            XCTAssertEqual(
                AgentInputFooterVisibility.isVisible(isNone: isNone),
                status != .none,
                "footer visibility must track claudeStatus != .none for \(status)",
            )
        }
    }
}

// MARK: - FooterPill state

final class FooterPillStateTests: XCTestCase {
    func testRestIsSurface1() {
        XCTAssertEqual(FooterPillState.fill(isActive: false, isHovering: false), .surface1)
    }

    func testHoverIsSurface2() {
        XCTAssertEqual(FooterPillState.fill(isActive: false, isHovering: true), .surface2)
    }

    func testActiveToggleForcesSurface2EvenWithoutHover() {
        XCTAssertEqual(FooterPillState.fill(isActive: true, isHovering: false), .surface2)
    }

    func testStaticMirrorIgnoresHover() {
        XCTAssertEqual(
            FooterPillState.fill(isActive: false, isHovering: true, staticMirror: true),
            .surface1,
            "a static snapshot paints the at-rest fill (no hover first-responder)",
        )
    }

    func testIconOnlyDetection() {
        XCTAssertTrue(FooterPillState.isIconOnly(label: nil, hasIcon: true))
        XCTAssertTrue(FooterPillState.isIconOnly(label: "", hasIcon: true))
        XCTAssertFalse(FooterPillState.isIconOnly(label: "Rich Input", hasIcon: true))
        XCTAssertFalse(FooterPillState.isIconOnly(label: nil, hasIcon: false))
    }
}

// MARK: - Suggestion pill copy + green chip bytes

final class SuggestionPillTests: XCTestCase {
    func testDynamicLabel() {
        XCTAssertEqual(SuggestionPillCopy.label(agentName: "Claude Code"), "Enable Claude Code notifications")
        XCTAssertEqual(SuggestionPillCopy.label(agentName: "Codex"), "Enable Codex notifications")
    }

    func testEmptyAgentFallsBackToGenericLabel() {
        XCTAssertEqual(SuggestionPillCopy.label(agentName: ""), "Enable notifications")
        XCTAssertEqual(SuggestionPillCopy.label(agentName: "   "), "Enable notifications")
    }

    func testGreenBorderIsUiGreenAtAlpha80() {
        XCTAssertEqual(GreenChip.borderGreen.r, UIStatus.green.r)
        XCTAssertEqual(GreenChip.borderGreen.g, UIStatus.green.g)
        XCTAssertEqual(GreenChip.borderGreen.b, UIStatus.green.b)
        XCTAssertEqual(GreenChip.borderGreen.a, 80, "spec §4B: border = green @ a80")
    }

    func testHoverFillIsGreenerThanRest() {
        // The hover fill blends green @15% vs rest @8% over the same low neutral surface ⇒ a stronger tint.
        let pillSurface = DesignTokens.warpDark.resolved.neutral(13)
        let rest = GreenChip.fill(pillSurface: pillSurface, hovered: false)
        let hover = GreenChip.fill(pillSurface: pillSurface, hovered: true)
        XCTAssertNotEqual(rest, hover)
        // Green channel rises with more green overlay.
        XCTAssertGreaterThanOrEqual(Int(hover.g), Int(rest.g))
    }

    func testMutedSuggestionGreenMatchesLiveWindow() {
        // Live-window match: rest green chip ≈ #384541 (sampled live ≈ #374442), a grayed DARK green —
        // far less saturated/bright than the old neutral25⊕green@25% (#486A59).
        let pillSurface = DesignTokens.warpDark.resolved.neutral(13)
        let rest = GreenChip.fill(pillSurface: pillSurface, hovered: false)
        XCTAssertEqual(rest, ColorU(r: 0x38, g: 0x45, b: 0x41, a: 255))
        XCTAssertEqual(rest, DesignTokens.warpDark.resolved.suggestionGreenFill)
    }
}

// MARK: - Coordinator action routing (the single dispatch site)

@MainActor
final class AgentInputFooterCoordinatorTests: XCTestCase {
    /// A throwaway PreferencesStore over an isolated UserDefaults suite (no sidecar, no apply).
    private func makePrefs() -> (PreferencesStore, UserDefaults, String) {
        let suite = "test.footer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        return (prefs, defaults, suite)
    }

    func testRichInputToggleFlipsInputBarMode() {
        let bar = InputBarModel()
        let coord = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: bar, preferences: nil, cwd: nil,
        )
        XCTAssertFalse(coord.richInputActive)
        coord.handle(.toggleRichInput)
        XCTAssertTrue(bar.richMode)
        XCTAssertTrue(coord.richInputActive)
        coord.handle(.toggleRichInput)
        XCTAssertFalse(bar.richMode)
    }

    func testFileExplorerToggleOpensAndCloses() {
        let coord = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: nil, preferences: nil,
            cwd: NSTemporaryDirectory(), isRemote: false,
        )
        XCTAssertFalse(coord.fileExplorerActive)
        coord.handle(.toggleFileExplorer)
        XCTAssertTrue(coord.fileExplorerActive)
        coord.handle(.toggleFileExplorer)
        XCTAssertFalse(coord.fileExplorerActive)
    }

    func testDismissNotificationsPersists() {
        let (prefs, _, _) = makePrefs()
        let coord = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: nil, preferences: prefs, cwd: nil,
        )
        XCTAssertTrue(coord.showsNotificationChip, "chip shows by default")
        coord.handle(.dismissNotifications)
        XCTAssertTrue(prefs.isNotificationChipDismissed(for: "Claude Code"))
        XCTAssertFalse(coord.showsNotificationChip, "dismissed ⇒ hidden")
    }

    func testEnableNotificationsHidesChip() {
        let (prefs, _, _) = makePrefs()
        let coord = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: nil, preferences: prefs, cwd: nil,
        )
        coord.handle(.installNotifications)
        XCTAssertTrue(prefs.isNotificationChipEnabled(for: "Claude Code"))
        XCTAssertFalse(coord.showsNotificationChip, "enabled ⇒ chip hidden")
    }

    func testDismissalSurvivesAcrossStoreInstances() throws {
        // W4: dismissal is persisted to UserDefaults — a NEW store over the same suite still sees it.
        let suite = "test.footer.persist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs1 = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        prefs1.dismissNotificationChip(for: "Claude Code")
        let prefs2 = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        XCTAssertTrue(prefs2.isNotificationChipDismissed(for: "Claude Code"))
        XCTAssertFalse(prefs2.shouldShowNotificationChip(for: "Claude Code"))
    }

    func testParentHooksFire() {
        var startedRemote = false
        var openedSettings = false
        var added = false
        var selected: String?
        let coord = AgentInputFooterCoordinator(
            agentName: "Claude Code", inputBar: nil, preferences: nil, cwd: nil,
        )
        coord.onStartRemoteControl = { startedRemote = true }
        coord.onOpenSettings = { openedSettings = true }
        coord.onAddContext = { added = true }
        coord.onSelectFile = { selected = $0 }

        coord.handle(.startRemoteControl)
        coord.handle(.openAgentSettings)
        coord.handle(.addContext)
        coord.handle(.selectFile("/tmp/x.txt"))

        XCTAssertTrue(startedRemote)
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(added)
        XCTAssertEqual(selected, "/tmp/x.txt")
    }
}

// MARK: - InputBarModel rich-mode (W3)

@MainActor
final class InputBarRichModeTests: XCTestCase {
    func testToggleRichModeFlipsAndReturnsNewValue() {
        let bar = InputBarModel()
        XCTAssertFalse(bar.richMode)
        XCTAssertTrue(bar.toggleRichMode())
        XCTAssertTrue(bar.richMode)
        XCTAssertFalse(bar.toggleRichMode())
        XCTAssertFalse(bar.richMode)
    }
}

// MARK: - File explorer listing (W2)

final class FileExplorerListerTests: XCTestCase {
    func testRemoteIsUnavailable() {
        XCTAssertEqual(FileExplorerLister.list(cwd: "/tmp", isRemote: true), .remoteUnavailable)
    }

    func testNilOrEmptyCwdIsUnknown() {
        XCTAssertEqual(FileExplorerLister.list(cwd: nil, isRemote: false), .unknownCwd)
        XCTAssertEqual(FileExplorerLister.list(cwd: "   ", isRemote: false), .unknownCwd)
    }

    func testNonexistentPathIsUnreadable() {
        let path = "/this/path/should/not/exist/\(UUID().uuidString)"
        if case .unreadable = FileExplorerLister.list(cwd: path, isRemote: false) {
            // ok
        } else {
            XCTFail("a missing directory must list as .unreadable")
        }
    }

    func testListsRealDirectorySortedDirsFirst() throws {
        // Build a deterministic temp tree: a dir "zdir" and two files "b.txt", "A.txt".
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fe-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("zdir"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("b.txt"))
        try Data().write(to: root.appendingPathComponent("A.txt"))

        guard case let .entries(entries) = FileExplorerLister.list(cwd: root.path, isRemote: false) else {
            XCTFail("expected .entries")
            return
        }
        XCTAssertEqual(entries.count, 3)
        // Directory first, then case-insensitive name (A.txt before b.txt).
        XCTAssertEqual(entries.map(\.name), ["zdir", "A.txt", "b.txt"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertFalse(entries[1].isDirectory)
    }

    func testSortIsStableDirsThenName() {
        let input = [
            FileEntry(name: "b", isDirectory: false),
            FileEntry(name: "Adir", isDirectory: true),
            FileEntry(name: "a", isDirectory: false),
            FileEntry(name: "Bdir", isDirectory: true),
        ]
        XCTAssertEqual(FileExplorerLister.sorted(input).map(\.name), ["Adir", "Bdir", "a", "b"])
    }
}

@MainActor
final class FileExplorerModelTests: XCTestCase {
    func testToggleRefreshesListing() {
        let model = FileExplorerModel()
        XCTAssertFalse(model.isOpen)
        XCTAssertTrue(model.toggle(cwd: NSTemporaryDirectory(), isRemote: false))
        XCTAssertTrue(model.isOpen)
        if case .entries = model.listing {} else if case .unreadable = model.listing {
            XCTFail("temp dir should be readable")
        }
        XCTAssertFalse(model.toggle(cwd: nil, isRemote: false))
        XCTAssertFalse(model.isOpen)
    }

    func testRemoteListingStub() {
        let model = FileExplorerModel()
        model.refresh(cwd: "/some/remote/cwd", isRemote: true)
        XCTAssertEqual(model.listing, .remoteUnavailable)
    }
}
