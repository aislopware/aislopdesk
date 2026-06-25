// TextBindingResolutionTests (E1/WI-7) — the dispatcher's text-binding / unbind resolution step pinned
// headlessly. `WorkspaceKeyDispatcher.handle` resolves a `text:`/`csi:`/`esc:` config binding (→ sendBytes)
// and an `unbind:` (→ passthrough) BEFORE the action table; that resolution lives in the pure, AppKit-free
// `WorkspaceBindingRegistry.textBinding(for:)` / `isUnbound(_:)` (so it is provable without the NSEvent
// monitor). These tests pin: the chord-keyed lookup hits, the registry→preferences chord bridge round-trips
// (so a `KeybindGrammar`-parsed chord and a dispatcher-produced registry chord key the SAME entry), and the
// empty-overrides fast path is a clean miss.
//
// FAILS on the pre-WI-7 code: `textBinding(for:)` / `isUnbound(_:)` / `KeyChord.asPreferencesChord` did not
// exist (the dispatcher had no text-binding branch at all).

import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskWorkspaceCore

@MainActor
final class TextBindingResolutionTests: XCTestCase {
    override func tearDown() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        super.tearDown()
    }

    // MARK: - The reverse chord bridge (registry KeyChord → preferences KeyChord)

    /// `KeyChord.asPreferencesChord` is the exact inverse of `asRegistryChord`: a chord parsed/stored in the
    /// persisted shape, mapped to the registry shape and back, is identity. This is what makes a config
    /// binding (parsed into the persisted shape) and a live keystroke (produced as a registry chord) key the
    /// SAME `textBindings` / `unbinds` entry.
    func testPreferencesChordBridgeRoundTripsPrintableAndNamedKeys() {
        let prefsChords: [KeybindingPreferences.KeyChord] = [
            .init(key: "h", command: true, shift: true),
            .init(key: "a", control: true),
            .init(key: "]", command: true),
            .init(key: "1", command: true),
            .init(key: "return", command: true, shift: true),
            .init(key: "left", command: true, option: true),
            .init(key: "pageup", shift: true),
            .init(key: "home", shift: true),
        ]
        for original in prefsChords {
            guard let registry = original.asRegistryChord else {
                XCTFail("\(original.canonical) should map to a registry chord")
                continue
            }
            XCTAssertEqual(
                registry.asPreferencesChord, original,
                "\(original.canonical) must round-trip registry → preferences identity",
            )
        }
    }

    // MARK: - Text-binding resolution

    /// A `text:` binding on ⌘⇧H resolves to its literal payload for the registry chord the dispatcher
    /// produces — proving the chord-keyed lookup + the reverse bridge agree, so the dispatcher would inject
    /// these bytes via `sendBytes`.
    func testTextBindingResolvesForRegistryChord() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            textBindings: [
                .init(key: "h", command: true, shift: true): .init(kind: .text, payload: [0x68, 0x69]),
            ],
        )
        let chord = KeyChord(character: "h", [.command, .shift])
        XCTAssertEqual(WorkspaceBindingRegistry.textBinding(for: chord)?.payload, [0x68, 0x69])
        XCTAssertEqual(WorkspaceBindingRegistry.textBinding(for: chord)?.kind, .text)
    }

    /// A `csi:` binding carries the ESC `[` lead bytes already baked in by `KeybindGrammar` — the resolver
    /// only forwards `payload`, so it surfaces the full sequence the dispatcher hands to `sendBytes`.
    func testCSITextBindingForwardsResolvedBytes() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            textBindings: [
                .init(key: "k", control: true): .init(kind: .csi, payload: [0x1B, 0x5B, 0x31, 0x37, 0x7E]),
            ],
        )
        let chord = KeyChord(character: "k", [.control])
        XCTAssertEqual(WorkspaceBindingRegistry.textBinding(for: chord)?.payload, [0x1B, 0x5B, 0x31, 0x37, 0x7E])
    }

    /// A chord with NO text binding (a different chord, or empty overrides) resolves to `nil` — the
    /// dispatcher then falls through to the `unbind`/action-table path.
    func testTextBindingMissesForUnboundChord() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            textBindings: [.init(key: "h", command: true): .init(kind: .text, payload: [0x68])],
        )
        XCTAssertNil(WorkspaceBindingRegistry.textBinding(for: KeyChord(character: "j", [.command])))
        // Empty overrides: a clean miss (the fast path).
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        XCTAssertNil(WorkspaceBindingRegistry.textBinding(for: KeyChord(character: "h", [.command])))
    }

    // MARK: - Unbind resolution

    /// An `unbind:` target reports `true` for the registry chord the dispatcher produces — so the dispatcher
    /// passes the event THROUGH (the default action is suppressed) rather than firing the registry action.
    func testUnboundChordIsRecognised() {
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(
            unbinds: [.init(key: "d", command: true)],
        )
        XCTAssertTrue(WorkspaceBindingRegistry.isUnbound(KeyChord(character: "d", [.command])))
        // A different chord (and the empty-overrides default) is NOT unbound.
        XCTAssertFalse(WorkspaceBindingRegistry.isUnbound(KeyChord(character: "e", [.command])))
        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences()
        XCTAssertFalse(WorkspaceBindingRegistry.isUnbound(KeyChord(character: "d", [.command])))
    }

    /// An `unbind:` on a DEFAULT chord (⌘D = split-right) shadows the action-table resolution at the
    /// dispatcher: the chord still resolves in `resolvedChordTable` (the binding row is untouched), but
    /// `isUnbound` is the gate the dispatcher checks FIRST, so the default no longer fires. This pins the
    /// precedence the dispatcher relies on (unbind wins over the action table).
    func testUnbindShadowsADefaultActionChord() {
        let chord = KeyChord(character: "d", [.command])
        // Precondition: ⌘D is a live default chord (split-right).
        XCTAssertEqual(WorkspaceBindingRegistry.resolvedChordTable[chord], .splitRight)

        WorkspaceBindingRegistry.activeOverrides = KeybindingPreferences(unbinds: [.init(key: "d", command: true)])
        XCTAssertTrue(
            WorkspaceBindingRegistry.isUnbound(chord),
            "the dispatcher checks isUnbound BEFORE the action table, so ⌘D is suppressed",
        )
    }
}
