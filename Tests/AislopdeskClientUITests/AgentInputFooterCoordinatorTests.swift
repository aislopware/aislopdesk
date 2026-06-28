import AislopdeskWorkspaceCore
import XCTest
@testable import AislopdeskClientUI

/// E13 WI-4 (ES-E13-4) — the single ``AgentInputFooterCoordinator/handle(_:)`` dispatch site behind the
/// Claude bottom bar's pills. The footer view is dumb: each pill emits one ``AgentInputFooterAction`` and the
/// coordinator routes it to the real engine (InputBarModel / FileExplorerModel / PreferencesStore) or to a
/// parent-supplied hook. Before WI-4 the coordinator was BUILT BUT UNMOUNTED, so none of these dispatches had
/// a test. These pin each route so a regression that drops one (or mis-wires a pill) FAILS:
/// - `toggleRichInput`     flips the bound input bar's `richMode` (the real toggle, not a presentation flag);
/// - `toggleFileExplorer`  flips the file panel + lists the cwd;
/// - `installNotifications`/`dismissNotifications` persist the per-agent chip flag (and `enable` re-opens the
///   global OSC delivery gate) — so `showsNotificationChip` flips false;
/// - `startRemoteControl`/`openAgentSettings`/`addContext` fire their parent hooks exactly once;
/// - `selectFile(path)`    forwards the chosen absolute path verbatim to `onSelectFile`.
@MainActor
final class AgentInputFooterCoordinatorTests: XCTestCase {
    private func makeIsolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AgentInputFooterCoordinatorTest." + name
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeStore(_ name: String = #function) -> PreferencesStore {
        PreferencesStore(defaults: makeIsolatedDefaults(name), sidecarURL: nil, applyOnInit: false)
    }

    private let agentName = "Claude Code"

    private func makeCoordinator(
        inputBar: InputBarModel? = nil,
        preferences: PreferencesStore? = nil,
    ) -> AgentInputFooterCoordinator {
        AgentInputFooterCoordinator(agentName: agentName, inputBar: inputBar, preferences: preferences, cwd: nil)
    }

    func testToggleRichInputFlipsInputBarRichMode() {
        let inputBar = InputBarModel()
        let coordinator = makeCoordinator(inputBar: inputBar)
        XCTAssertFalse(inputBar.richMode, "rich mode is OFF by default")
        XCTAssertFalse(coordinator.richInputActive)

        coordinator.handle(.toggleRichInput)
        XCTAssertTrue(inputBar.richMode, "the Rich Input pill drives the REAL input-bar toggle")
        XCTAssertTrue(coordinator.richInputActive, "the derived view-state mirrors the toggle")

        coordinator.handle(.toggleRichInput)
        XCTAssertFalse(inputBar.richMode, "toggling again turns it back off")
    }

    func testToggleFileExplorerFlipsPanelOpenState() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.fileExplorerActive, "the file panel is closed by default")

        coordinator.handle(.toggleFileExplorer)
        XCTAssertTrue(coordinator.fileExplorerActive, "the File explorer pill opens the panel")
        XCTAssertTrue(coordinator.fileExplorer.isOpen)

        coordinator.handle(.toggleFileExplorer)
        XCTAssertFalse(coordinator.fileExplorerActive, "toggling again closes it")
    }

    func testInstallNotificationsRecordsEnableAndHidesChip() {
        let store = makeStore()
        let coordinator = makeCoordinator(preferences: store)
        XCTAssertTrue(coordinator.showsNotificationChip, "the green CTA shows before the user acts")

        coordinator.handle(.installNotifications)
        XCTAssertTrue(store.isNotificationChipEnabled(for: agentName), "enable is persisted per-agent")
        XCTAssertFalse(coordinator.showsNotificationChip, "an enabled chip is hidden (Warp's hide-once rule)")
    }

    func testDismissNotificationsPersistsAndHidesChip() {
        let store = makeStore()
        let coordinator = makeCoordinator(preferences: store)
        coordinator.handle(.dismissNotifications)
        XCTAssertTrue(store.isNotificationChipDismissed(for: agentName), "dismissal is persisted per-agent")
        XCTAssertFalse(coordinator.showsNotificationChip, "a dismissed chip stays hidden")
    }

    func testStartRemoteControlFiresHookOnce() {
        let coordinator = makeCoordinator()
        var fired = 0
        coordinator.onStartRemoteControl = { fired += 1 }
        coordinator.handle(.startRemoteControl)
        XCTAssertEqual(fired, 1, "the /remote-control pill fires the parent hook exactly once")
    }

    func testOpenSettingsFiresHookOnce() {
        let coordinator = makeCoordinator()
        var fired = 0
        coordinator.onOpenSettings = { fired += 1 }
        coordinator.handle(.openAgentSettings)
        XCTAssertEqual(fired, 1, "the Settings pill routes to the parent open-settings hook")
    }

    func testAddContextFiresHookOnce() {
        let coordinator = makeCoordinator()
        var fired = 0
        coordinator.onAddContext = { fired += 1 }
        coordinator.handle(.addContext)
        XCTAssertEqual(fired, 1, "the + pill routes to the parent add-context hook")
    }

    func testSelectFileForwardsPathVerbatim() {
        let coordinator = makeCoordinator()
        var captured: String?
        coordinator.onSelectFile = { captured = $0 }
        let path = "/Users/me/project/src/héllo 文字.swift"
        coordinator.handle(.selectFile(path))
        XCTAssertEqual(captured, path, "a picked file forwards its absolute path verbatim (no mangling)")
    }
}
