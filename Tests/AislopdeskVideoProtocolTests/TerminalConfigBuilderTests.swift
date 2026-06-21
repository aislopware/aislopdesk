import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// W13 — the PURE `TerminalPreferences → ghostty config string` builder. Pins every field to its
/// Ghostty config key (`font-family`, `font-size`, `font-style`, `theme`, `cursor-style`,
/// `cursor-style-blink`, `scrollback-limit`) + the keybind lines, headlessly (no libghostty surface).
final class TerminalConfigBuilderTests: XCTestCase {
    /// Split the config string into its `key` set + a `[key: value]` map (keys are unique per build).
    private func parse(_ config: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in config.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            map[key] = value
        }
        return map
    }

    func testDefaultPrefsMapEachFieldToTheRightGhosttyKey() {
        let config = TerminalConfigBuilder.string(for: TerminalPreferences())
        let map = parse(config)
        XCTAssertEqual(map["font-family"], "SF Mono")
        XCTAssertEqual(map["font-size"], "13") // integral → no decimal
        XCTAssertEqual(map["font-style"], "regular")
        XCTAssertEqual(map["theme"], "Aislopdesk Dark")
        XCTAssertEqual(map["cursor-style"], "block")
        XCTAssertEqual(map["cursor-style-blink"], "true")
        // 10000 lines × 256 B/line.
        XCTAssertEqual(map["scrollback-limit"], "2560000")
    }

    func testEachCustomFieldChangesItsLine() {
        let prefs = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14.5, fontWeight: "bold", theme: "Light",
            cursorStyle: .bar, cursorBlink: false, scrollbackLines: 5000,
        )
        let map = parse(TerminalConfigBuilder.string(for: prefs))
        XCTAssertEqual(map["font-family"], "JetBrains Mono")
        XCTAssertEqual(map["font-size"], "14.5") // fractional preserved
        XCTAssertEqual(map["font-style"], "bold")
        XCTAssertEqual(map["theme"], "Light")
        XCTAssertEqual(map["cursor-style"], "bar")
        XCTAssertEqual(map["cursor-style-blink"], "false")
        XCTAssertEqual(map["scrollback-limit"], "1280000") // 5000 × 256
    }

    func testEveryCursorStyleRawValueIsAValidGhosttyToken() {
        for style in TerminalPreferences.CursorStyle.allCases {
            let prefs = TerminalPreferences(cursorStyle: style)
            let map = parse(TerminalConfigBuilder.string(for: prefs))
            XCTAssertEqual(map["cursor-style"], style.rawValue)
            XCTAssertTrue(["block", "bar", "underline"].contains(style.rawValue))
        }
    }

    func testEmptyFamilyOrThemeIsSkippedNotEmittedEmpty() {
        // An empty `font-family =` would CLEAR Ghostty's default to nothing — so it is skipped, not
        // emitted as a blank line. font-size / cursor / scrollback always emit (they have real values).
        let prefs = TerminalPreferences(fontFamily: "  ", theme: "")
        let map = parse(TerminalConfigBuilder.string(for: prefs))
        XCTAssertNil(map["font-family"], "an empty family is omitted, not emitted blank")
        XCTAssertNil(map["theme"], "an empty theme is omitted")
        XCTAssertNotNil(map["font-size"], "size always emits")
        XCTAssertNotNil(map["cursor-style"])
    }

    func testScrollbackLimitClampsNonPositiveToZero() {
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: 0), 0)
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: -5), 0)
        XCTAssertEqual(TerminalConfigBuilder.scrollbackLimitBytes(lines: 1), 256)
    }

    func testKeybindLinesAreAppendedAndEmptyOnesSkipped() {
        let config = TerminalConfigBuilder.string(
            for: TerminalPreferences(),
            keybinds: ["cmd+d=new_split:right", "  ", "cmd+w=close_surface"],
        )
        let keybindLines = config.split(separator: "\n").filter { $0.hasPrefix("keybind = ") }
        XCTAssertEqual(keybindLines.count, 2, "two real binds, the blank one skipped")
        XCTAssertTrue(config.contains("keybind = cmd+d=new_split:right"))
        XCTAssertTrue(config.contains("keybind = cmd+w=close_surface"))
    }

    func testBuildIsDeterministicAndStableOrdered() {
        // The same prefs always produce byte-identical output (deterministic order: font → theme →
        // cursor → scrollback). A round-trip of the prefs → config → re-parse recovers the fields.
        let prefs = TerminalPreferences(fontFamily: "Menlo", fontSize: 12)
        let a = TerminalConfigBuilder.string(for: prefs)
        let b = TerminalConfigBuilder.string(for: prefs)
        XCTAssertEqual(a, b)
        let lines = a.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "font-family = Menlo", "font-family leads the stable order")
    }
}
