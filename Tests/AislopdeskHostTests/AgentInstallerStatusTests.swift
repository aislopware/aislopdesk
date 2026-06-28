import Foundation
import XCTest
@testable import AislopdeskHost

/// E13 WI-1 — the PURE ``AgentInstaller/isInstalled(settingsPath:fileManager:)`` marker read that backs
/// the host's `agentHookStatus` (verb 13) wire reply + the Agents settings card's status row. Proves it
/// is `true` only after a real install, `false` after uninstall, and TOLERANT of a missing / hook-less /
/// corrupt settings file (returns `false`, never traps). Every assertion reverts-to-confirm-fail:
/// a hard-coded `true`/`false` would fail the opposite-state case; trapping on a corrupt file would crash
/// the tolerance test.
final class AgentInstallerStatusTests: XCTestCase {
    /// Makes a fresh, unique temp dir + the settings/script paths under it; cleaned up by the caller.
    private func makePaths() -> (dir: URL, settings: String, script: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aislopdesk-installer-status-\(UUID().uuidString)")
        return (
            dir,
            dir.appendingPathComponent("settings.json").path,
            dir.appendingPathComponent("hooks/aislopdesk-agent.sh").path,
        )
    }

    func testIsInstalledFalseWhenSettingsFileMissing() {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The file was never created → tolerant false (no trap on a missing file).
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledTrueAfterInstallThenFalseAfterUninstall() throws {
        let (dir, settings, script) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings), "not installed before install")

        _ = try AgentInstaller.install(settingsPath: settings, scriptPath: script)
        XCTAssertTrue(AgentInstaller.isInstalled(settingsPath: settings), "installed after install")

        _ = try AgentInstaller.uninstall(settingsPath: settings)
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings), "not installed after uninstall")
    }

    func testIsInstalledFalseWhenOnlyTheUsersOwnHookPresent() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A settings file with a hook that is NOT ours (no marker) → false (we never claim the user's hook).
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """.utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledTrueWhenOursSitsAlongsideTheUsersHook() throws {
        let (dir, settings, script) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify-me"}]}]}}
        """.utf8).write(to: URL(fileURLWithPath: settings))
        _ = try AgentInstaller.install(settingsPath: settings, scriptPath: script)
        XCTAssertTrue(AgentInstaller.isInstalled(settingsPath: settings), "ours is detected next to the user's hook")
    }

    func testIsInstalledFalseOnCorruptSettingsFile() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Non-JSON garbage → readSettings repairs to an empty root → false, never a trap.
        try Data("this is not json {{{".utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }

    func testIsInstalledFalseWhenHooksKeyAbsent() throws {
        let (dir, settings, _) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Valid settings with NO hooks key at all → false.
        try Data(#"{"theme":"dark"}"#.utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertFalse(AgentInstaller.isInstalled(settingsPath: settings))
    }
}
