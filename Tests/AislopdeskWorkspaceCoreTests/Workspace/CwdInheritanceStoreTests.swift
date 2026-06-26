import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E3 WI-2 (ES-E3-2): the store-side A26 cwd-inheritance — `splitActivePane` / `newTab` resolve the
/// configured ``WorkingDirectoryPolicy`` against the active pane's ``PaneSpec/lastKnownCwd``, STAMP the
/// result on the new pane's spec, and (terminal only) deliver a deferred `cd '<cwd>'\n` to that pane's
/// session. Drives a LIVE `.tree` store through the `FakePaneSession` seam — no real client / view.
///
/// The pure policy math is pinned in `WorkingDirectoryPolicyTests`; here we pin the WIRING: the resolved
/// cwd lands on the right spec, `.home` stamps nil + sends nothing (no redundant `cd`), and with a `0`ms
/// launch grace the `cd` bytes actually reach the NEW pane's `FakePaneSession` (not the original).
@MainActor
final class CwdInheritanceStoreTests: XCTestCase {
    private let policyKeys = [
        SettingsKey.workingDirectoryNewWindowKey,
        SettingsKey.workingDirectoryNewTabKey,
        SettingsKey.workingDirectoryNewSplitKey,
    ]

    override func setUp() {
        super.setUp()
        for key in policyKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in policyKeys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
    }

    /// A single-session, single-pane workspace whose pane carries `cwd` as its last-known cwd (the inherit
    /// source).
    private func singlePaneWorkspace(_ pane: PaneID, cwd: String?) -> TreeWorkspace {
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: cwd)]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    private func allPaneIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        Set(store.tree.allPaneIDs())
    }

    /// Drains the deferred (0 ms-grace) send Task by yielding the main actor until `fake` has recorded bytes
    /// or the budget runs out (mirrors `SessionTemplateStoreTests`).
    private func waitForBytes(_ fake: FakePaneSession?) async {
        for _ in 0..<200 {
            if (fake?.sentBytes.count ?? 0) > 0 { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets any (possibly erroneously-scheduled) deferred send land, so a "sent NOTHING" assertion is not
    /// vacuously true because the send simply hadn't run yet.
    private func settleDeferredSends() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Stamp resolved cwd on the new spec

    func testSplitInheritStampsActiveCwdOnNewSpec() throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewSplitKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first, "a split mints a new pane")
        XCTAssertEqual(
            store.tree.spec(for: newPane)?.lastKnownCwd, "/Users/me/project",
            "inherit stamps the active pane's cwd on the new split spec",
        )
    }

    func testNewTabInheritStampsActiveCwdOnNewSpec() throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first, "a new tab mints a new pane")
        XCTAssertEqual(store.tree.spec(for: newPane)?.lastKnownCwd, "/Users/me/project")
    }

    func testHomeStampsNilEvenWithAnActiveCwd() throws {
        UserDefaults.standard.set("home", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        XCTAssertNil(
            store.tree.spec(for: newPane)?.lastKnownCwd,
            "home ignores the active cwd → nil (no redundant cd)",
        )
    }

    func testPathStampsTheConfiguredPath() throws {
        UserDefaults.standard.set("/opt/work", forKey: SettingsKey.workingDirectoryNewSplitKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.splitActivePane(axis: .vertical, kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        XCTAssertEqual(store.tree.spec(for: newPane)?.lastKnownCwd, "/opt/work", "a path policy stamps that path")
    }

    func testInheritReadsTheFreshnessRefreshedCwd() throws {
        // The freshness refresh (the `onCommandCompleted` OSC-7-equivalent) writes the pane's cwd via
        // `setLastKnownCwd`; `inherit` must read that SAME field — proving the single-source loop (the
        // "don't double-source cwd" invariant) rather than reading some stale alternate field.
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewSplitKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        store.setLastKnownCwd("/refreshed/dir", for: pane) // stands in for the post-command cwd refresh
        let before = allPaneIDs(store)

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        XCTAssertEqual(
            store.tree.spec(for: newPane)?.lastKnownCwd, "/refreshed/dir",
            "inherit sources the cwd the freshness refresh wrote",
        )
    }

    func testInheritWithNoActiveCwdStampsNil() throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        XCTAssertNil(store.tree.spec(for: newPane)?.lastKnownCwd, "nothing to inherit → nil")
    }

    // MARK: - Deferred `cd` send (launchGrace: 0)

    func testSplitInheritSendsDeferredCdToTheNewPane() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewSplitKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        let newFake = store.handle(for: newPane) as? FakePaneSession
        await waitForBytes(newFake)

        XCTAssertEqual(
            newFake?.sentBytes, [Array("cd '/Users/me/project'\n".utf8)],
            "the inherited cwd is `cd`-ed into the new split pane",
        )
        // The ORIGINAL pane must receive nothing (the `cd` targets only the freshly-minted pane).
        XCTAssertEqual((store.handle(for: pane) as? FakePaneSession)?.sentBytes ?? [], [])
    }

    func testNewTabInheritSendsDeferredCdToTheNewPane() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/srv/app"))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal, launchGrace: .zero)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        let newFake = store.handle(for: newPane) as? FakePaneSession
        await waitForBytes(newFake)

        XCTAssertEqual(newFake?.sentBytes, [Array("cd '/srv/app'\n".utf8)])
    }

    func testHomeSendsNoCd() async throws {
        UserDefaults.standard.set("home", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal, launchGrace: .zero)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        let newFake = store.handle(for: newPane) as? FakePaneSession
        await settleDeferredSends()
        XCTAssertEqual(newFake?.sentBytes ?? [], [], "home resolves nil → no `cd` keystrokes")
    }

    func testInheritWithNoActiveCwdSendsNothing() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        let before = allPaneIDs(store)

        store.newTab(kind: .terminal, launchGrace: .zero)

        let newPane = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        let newFake = store.handle(for: newPane) as? FakePaneSession
        await settleDeferredSends()
        XCTAssertEqual(newFake?.sentBytes ?? [], [], "no inherit source → no `cd`")
    }

    // MARK: - The PRIMARY ⌘T / ⌘D chooser flow delivers the deferred `cd` (ES-E3-2)

    // The dominant new-tab / split gestures route through a `.chooser` pane (`openChooserPane`), NOT a direct
    // `.terminal` `newTab` / `splitActivePane`. The `cd` must reach the new terminal once the user PICKS
    // Terminal (`choosePaneKind`) — the path the direct-`.terminal` tests above never exercise. These FAIL on
    // the pre-fix store (the chooser→terminal flip never re-issued the deferred inheritance `cd`).

    func testChooserNewTabThenPickTerminalSendsDeferredCd() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        // ⌘T routes through the chooser (the generic new-tab action), not `newTab(kind: .terminal)`.
        store.openChooserPane(.newTab)
        let chooser = try XCTUnwrap(allPaneIDs(store).subtracting(before).first, "the chooser path mints a new pane")
        XCTAssertEqual(store.tree.spec(for: chooser)?.kind, .chooser, "⌘T opens a chooser pane")
        // While it is still a chooser there is no PTY — nothing is sent.
        await settleDeferredSends()
        XCTAssertEqual((store.handle(for: chooser) as? FakePaneSession)?.sentBytes ?? [], [])

        // Picking Terminal flips the chooser → terminal and must NOW deliver the inherited `cd`.
        store.choosePaneKind(chooser, kind: .terminal, launchGrace: .zero)
        let newFake = store.handle(for: chooser) as? FakePaneSession
        await waitForBytes(newFake)
        XCTAssertEqual(
            newFake?.sentBytes, [Array("cd '/Users/me/project'\n".utf8)],
            "the chooser-resolved terminal lands in the inherited cwd (the real ⌘T flow, not just the palette path)",
        )
        // The original pane is untouched (the `cd` targets only the freshly-resolved pane).
        XCTAssertEqual((store.handle(for: pane) as? FakePaneSession)?.sentBytes ?? [], [])
    }

    func testChooserSplitThenPickTerminalSendsDeferredCd() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewSplitKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/srv/app"))
        let before = allPaneIDs(store)

        store.openChooserPane(.split(axis: .horizontal))
        let chooser = try XCTUnwrap(allPaneIDs(store).subtracting(before).first, "a chooser split mints a new pane")

        store.choosePaneKind(chooser, kind: .terminal, launchGrace: .zero)
        let newFake = store.handle(for: chooser) as? FakePaneSession
        await waitForBytes(newFake)
        XCTAssertEqual(
            newFake?.sentBytes, [Array("cd '/srv/app'\n".utf8)],
            "the chooser-resolved split terminal inherits the active pane's cwd",
        )
    }

    func testChooserHomePolicyThenPickTerminalSendsNoCd() async throws {
        UserDefaults.standard.set("home", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.openChooserPane(.newTab)
        let chooser = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)
        XCTAssertNil(store.tree.spec(for: chooser)?.lastKnownCwd, "home stamps nil on the chooser spec")

        store.choosePaneKind(chooser, kind: .terminal, launchGrace: .zero)
        let newFake = store.handle(for: chooser) as? FakePaneSession
        await settleDeferredSends()
        XCTAssertEqual(newFake?.sentBytes ?? [], [], "home resolves nil → no `cd` even via the chooser flow")
    }

    func testChooserPickRemoteGuiSendsNoCd() async throws {
        UserDefaults.standard.set("inherit", forKey: SettingsKey.workingDirectoryNewTabKey)
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        let before = allPaneIDs(store)

        store.openChooserPane(.newTab)
        let chooser = try XCTUnwrap(allPaneIDs(store).subtracting(before).first)

        // Resolving the chooser to a NON-terminal kind must never send a `cd` (a video pane has no shell).
        store.choosePaneKind(chooser, kind: .remoteGUI, launchGrace: .zero)
        let newFake = store.handle(for: chooser) as? FakePaneSession
        await settleDeferredSends()
        XCTAssertEqual(newFake?.sentBytes ?? [], [], "a remote-GUI pane takes no `cd`")
    }
}
