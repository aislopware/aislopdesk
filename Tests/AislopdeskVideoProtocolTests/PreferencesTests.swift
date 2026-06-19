import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + default tests for the four W12 settings models. Each model is a pure `Codable` value
/// type; this proves `encode |> decode == value`, that defaults are sensible, and (for keybindings)
/// the chord canonicalisation + conflict detection.
final class PreferencesTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testVideoPreferencesRoundTrip() throws {
        let prefs = VideoPreferences(
            qpSharp: 22, qpCoarse: 44, qpDecouple: true, fecM: 2, fecK: 5,
            pacer: .arrival, playoutMs: 12.5, captureScale: 1, displayCapture: .window,
            virtualDisplay: false, sharpen: 0.4,
        )
        XCTAssertEqual(try roundTrip(prefs), prefs)
        XCTAssertEqual(VideoPreferences(), VideoPreferences()) // default is all-nil
        XCTAssertNil(VideoPreferences().qpSharp)
    }

    func testTerminalPreferencesRoundTripAndDefaults() throws {
        let def = TerminalPreferences()
        XCTAssertEqual(def.fontFamily, "SF Mono")
        XCTAssertEqual(def.scrollbackLines, 10000)
        XCTAssertEqual(def.cursorStyle, .block)
        let custom = TerminalPreferences(
            fontFamily: "JetBrains Mono", fontSize: 14, fontWeight: "bold", theme: "Light",
            cursorStyle: .bar, cursorBlink: false, scrollbackLines: 50000,
        )
        XCTAssertEqual(try roundTrip(custom), custom)
    }

    func testAgentPreferencesRoundTrip() throws {
        XCTAssertNil(AgentPreferences().agentDetect)
        let custom = AgentPreferences(agentDetect: true, agentHooks: false)
        XCTAssertEqual(try roundTrip(custom), custom)
    }

    // MARK: Keybindings

    func testKeyChordCanonical() {
        let c = KeybindingPreferences.KeyChord(key: "D", command: true, shift: true)
        XCTAssertEqual(c.key, "d") // lowercased on init
        XCTAssertEqual(c.canonical, "shift+cmd+d") // stable modifier order
    }

    func testKeybindingPreferencesRoundTrip() throws {
        let prefs = KeybindingPreferences(overrides: [
            "pane.splitRight": .init(key: "d", command: true),
            "pane.splitDown": .init(key: "d", command: true, shift: true),
        ])
        XCTAssertEqual(try roundTrip(prefs), prefs)
        XCTAssertEqual(prefs.chord(for: "pane.splitRight")?.canonical, "cmd+d")
        XCTAssertNil(prefs.chord(for: "pane.notOverridden"))
    }

    func testKeybindingConflictDetection() {
        // Two ids bound to the SAME chord ⇒ a conflict; a unique binding ⇒ none.
        let prefs = KeybindingPreferences(overrides: [
            "a": .init(key: "x", command: true),
            "b": .init(key: "x", command: true), // collides with a
            "c": .init(key: "y", command: true), // unique
        ])
        let conflicts = prefs.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts["cmd+x"].map { Set($0) }, Set(["a", "b"]))
        XCTAssertTrue(KeybindingPreferences().conflicts().isEmpty) // empty ⇒ no conflicts
    }
}
