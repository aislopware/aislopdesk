import XCTest
@testable import AislopdeskWorkspaceCore

/// O1 — the otty `On Launch` general setting is a LIVE control, not a dead accessor. Before this wiring the
/// General → On Launch picker persisted ``OnLaunchBehavior`` but NO launch path read it, so picking "New
/// Window" was a silent no-op (`AislopdeskClientApp.init` always restored the persisted tree via
/// `loadTree()`). The fix routes the app's store-construction site through
/// ``WorkspacePersistence/launchTree(behavior:persistence:)``; these pins prove the launch branch picks
/// fresh-vs-restore based on the persisted key, headlessly — against a temp-file persistence seam, with no
/// window / store / UI / SCStream / VT / Metal constructed (the hang-safety rule).
final class OnLaunchBehaviorWiringTests: XCTestCase {
    /// A temp-file persistence holding a tree distinguishable from a fresh `defaultWorkspace()` (its active
    /// session is renamed to a marker), plus the temp dir to clean up.
    private func makeMarkedPersistence(
        marker: String,
    ) throws -> (persistence: WorkspacePersistence, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-onlaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))

        var tree = TreeWorkspace.defaultWorkspace().normalized()
        // Rename the active session so the restored tree is NOT byte-identical to a fresh default — this is
        // the marker the restore branch must surface and the fresh branch must NOT.
        tree.sessions[0].name = marker
        try persistence.save(tree)
        return (persistence, dir)
    }

    /// `.restoreLastSession` (the default) restores the persisted tree, while `.newWindow` returns `nil` so
    /// the store seeds `TreeWorkspace.defaultWorkspace()` — proven with the SAME persistence handle so the
    /// ONLY thing flipping the outcome is the persisted ``OnLaunchBehavior``. (Revert-to-confirm-fail: before
    /// the wiring there was no `launchTree`, and the app's `persistence?.loadTree()` returned the marked tree
    /// for BOTH values — this test could not have been written, let alone pass.)
    func testLaunchTreeBranchesOnBehavior() throws {
        let marker = "Restored-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        defer { try? FileManager.default.removeItem(at: dir) }

        // restoreLastSession → the persisted (marked) tree.
        let restored = WorkspacePersistence.launchTree(
            behavior: .restoreLastSession, persistence: persistence,
        )
        XCTAssertEqual(
            restored?.activeSession?.name, marker,
            ".restoreLastSession must restore the persisted tree",
        )

        // newWindow → nil (the store then seeds a fresh single-pane defaultWorkspace), NOT the marked tree —
        // even though the very same persistence handle could have restored it.
        let fresh = WorkspacePersistence.launchTree(behavior: .newWindow, persistence: persistence)
        XCTAssertNil(fresh, ".newWindow must NOT restore the persisted tree (store seeds defaultWorkspace)")

        // The fresh default the store would seed is genuinely distinct from the persisted session.
        XCTAssertNotEqual(
            TreeWorkspace.defaultWorkspace().activeSession?.name, marker,
            "a fresh default session is not the persisted (marked) session",
        )
    }

    /// The launch path reads the PERSISTED key end-to-end: setting `general.onLaunch` in `UserDefaults` (the
    /// store the `@Default(.onLaunch)` picker binds) flips the resolved tree exactly as the app does
    /// (`launchTree(behavior: SettingsKey.onLaunch, persistence:)`). This is the proof the dead accessor is
    /// now wired: the persisted choice — not a hardcoded restore — drives the branch.
    func testPersistedKeyDrivesLaunchBranch() throws {
        let marker = "Persisted-Key-Marker"
        let (persistence, dir) = try makeMarkedPersistence(marker: marker)
        let key = SettingsKey.onLaunchKey
        let prior = UserDefaults.standard.string(forKey: key)
        defer {
            try? FileManager.default.removeItem(at: dir)
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Persisted "new-window" → the app-shaped read resolves to a fresh window (nil tree).
        UserDefaults.standard.set("new-window", forKey: key)
        XCTAssertEqual(SettingsKey.onLaunch, .newWindow)
        XCTAssertNil(
            WorkspacePersistence.launchTree(behavior: SettingsKey.onLaunch, persistence: persistence),
            "a persisted new-window key must seed a fresh window",
        )

        // Persisted "restore-last-session" → the app-shaped read restores the marked tree.
        UserDefaults.standard.set("restore-last-session", forKey: key)
        XCTAssertEqual(SettingsKey.onLaunch, .restoreLastSession)
        XCTAssertEqual(
            WorkspacePersistence.launchTree(behavior: SettingsKey.onLaunch, persistence: persistence)?
                .activeSession?.name,
            marker,
            "a persisted restore-last-session key must restore the persisted tree",
        )
    }

    /// With NO persistence handle (the automation shape — the store is built without one so a throwaway
    /// autoconnect tree can't clobber the real `workspace.json`), the default `.restoreLastSession` resolves
    /// to `nil` exactly as the pre-wiring `persistence?.loadTree()` did, so automation launch is unchanged.
    func testNoPersistenceIsNilRegardlessOfBehavior() {
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .restoreLastSession, persistence: nil))
        XCTAssertNil(WorkspacePersistence.launchTree(behavior: .newWindow, persistence: nil))
    }
}
