import Foundation
import XCTest
@testable import AislopdeskClientUI

/// The pure launch-preset model + expansion (docs/42 W14 #9, Warp launch-configuration parity): a preset
/// → the pane spec(s) + the keystrokes to type after each pane connects, including the `cd` prefix, the
/// optional split, and the shipped built-ins. No store, no transport.
final class LaunchPresetEngineTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(bytes: bytes, encoding: .utf8) ?? "" }

    // MARK: Single-pane expansion

    func testSimpleCommandPreset() {
        let preset = LaunchPreset(name: "htop", command: "htop")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertNil(plan.splitAxis)
        XCTAssertEqual(plan.panes.count, 1)
        XCTAssertEqual(plan.panes[0].spec.kind, .terminal)
        XCTAssertEqual(plan.panes[0].spec.title, "htop")
        XCTAssertEqual(text(plan.panes[0].keystrokes), "htop\n")
    }

    func testEmptyCommandSendsNoKeystrokes() {
        let preset = LaunchPreset(name: "Shell", command: "")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.panes.count, 1)
        XCTAssertTrue(plan.panes[0].keystrokes.isEmpty)
    }

    func testWorkingDirectoryEmitsCdPrefix() {
        let preset = LaunchPreset(name: "Build", command: "make", workingDirectory: "/Users/me/proj")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/Users/me/proj'\nmake\n")
    }

    func testWorkingDirectoryWithSpacesIsQuoted() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/a b/c")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/a b/c'\nls\n")
    }

    func testWorkingDirectoryWithSingleQuoteIsEscaped() {
        let preset = LaunchPreset(name: "X", command: "ls", workingDirectory: "/it's/here")
        let plan = LaunchPresetEngine.plan(for: preset)
        // POSIX single-quote escape: ' -> '\''
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/it'\\''s/here'\nls\n")
    }

    func testEmptyCwdAndCommandIsPlainShell() {
        let preset = LaunchPreset(name: "Shell", command: "  ", workingDirectory: "")
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertTrue(plan.panes[0].keystrokes.isEmpty)
    }

    // MARK: Two-pane (split) expansion

    func testSplitPresetMakesTwoPanesAndCarriesAxis() {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .",
            split: .init(axis: .horizontal, secondaryCommand: "npm run watch"),
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.splitAxis, .horizontal)
        XCTAssertEqual(plan.panes.count, 2)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "nvim .\n")
        XCTAssertEqual(text(plan.panes[1].keystrokes), "npm run watch\n")
    }

    func testSplitSecondPaneInheritsWorkingDirectory() {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .", workingDirectory: "/proj",
            split: .init(axis: .vertical, secondaryCommand: "ls"),
        )
        let plan = LaunchPresetEngine.plan(for: preset)
        XCTAssertEqual(plan.splitAxis, .vertical)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "cd '/proj'\nnvim .\n")
        XCTAssertEqual(text(plan.panes[1].keystrokes), "cd '/proj'\nls\n")
    }

    // MARK: Built-ins

    func testBuiltInsArePresentAndStable() {
        let names = LaunchPreset.builtIns.map(\.name)
        XCTAssertEqual(names, ["Claude Code", "htop", "Git log"])
        XCTAssertTrue(LaunchPreset.builtIns.allSatisfy(\.isBuiltIn))
        // Stable UUIDs so a re-seed matches the same row (idempotent).
        XCTAssertEqual(LaunchPreset.builtIns.map(\.id), LaunchPreset.builtIns.map(\.id))
    }

    func testClaudeCodeBuiltInRunsClaude() throws {
        let claude = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "Claude Code" })
        let plan = LaunchPresetEngine.plan(for: claude)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "claude\n")
        XCTAssertNil(plan.splitAxis)
    }

    func testGitLogBuiltInExpands() throws {
        let gitLog = try XCTUnwrap(LaunchPreset.builtIns.first { $0.name == "Git log" })
        let plan = LaunchPresetEngine.plan(for: gitLog)
        XCTAssertEqual(text(plan.panes[0].keystrokes), "git log --oneline --graph --decorate -30\n")
    }

    // MARK: Codable round-trip (it persists on the workspace like LayoutPreset/Snippet)

    func testCodableRoundTrip() throws {
        let preset = LaunchPreset(
            name: "Dev", command: "nvim .", workingDirectory: "/proj",
            split: .init(axis: .horizontal, secondaryCommand: "watch"), symbol: "hammer",
        )
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(LaunchPreset.self, from: data)
        XCTAssertEqual(preset, back)
    }
}
