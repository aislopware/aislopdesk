// WorkspaceKeyboardLayerTests — pins the W11 keyboard-surface bridge: every WorkspaceBindingRegistry chord
// converts to a SwiftUI (KeyEquivalent, EventModifiers) so the hidden button bank can register it, and the
// modifier mapping is faithful. This is the novel logic of the W11 regression fix (the action→store-op
// routing itself is already pinned by WorkspaceCore's TreeCommandRoutingTests).

import AislopdeskWorkspaceCore
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

final class WorkspaceKeyboardLayerTests: XCTestCase {
    func testEveryRegistryChordConvertsToAKeyEquivalent() {
        for binding in WorkspaceBindingRegistry.allBindings {
            guard let chord = binding.chord else { continue }
            XCTAssertNotNil(
                WorkspaceChordBridge.keyEquivalent(chord.key),
                "binding \(binding.id) has a chord the bank cannot bind",
            )
        }
    }

    func testModifierMappingIsFaithful() {
        XCTAssertEqual(WorkspaceChordBridge.modifiers([.command]), .command)
        XCTAssertEqual(WorkspaceChordBridge.modifiers([.command, .shift]), [.command, .shift])
        XCTAssertEqual(WorkspaceChordBridge.modifiers([.option, .command]), [.option, .command])
        XCTAssertEqual(
            WorkspaceChordBridge.modifiers([.control, .command, .shift]),
            [.control, .command, .shift],
        )
    }

    func testCharacterKeyLowerCases() {
        // The registry carries lower-cased chord chars; the bridge preserves that (case lives in .shift).
        XCTAssertEqual(WorkspaceChordBridge.keyEquivalent(.character("d")), KeyEquivalent("d"))
    }

    func testEveryRegistryChordIsCommandOrOptionPrefixed() {
        // The bank must never register a bare key / Ctrl-letter (it would steal it from the terminal).
        for binding in WorkspaceBindingRegistry.allBindings {
            guard let chord = binding.chord else { continue }
            let mods = chord.modifiers
            XCTAssertTrue(
                mods.contains(.command) || mods.contains(.option),
                "binding \(binding.id) is not ⌘/⌥-prefixed",
            )
        }
    }
}
