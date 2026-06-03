import XCTest
@testable import RworkClientUI

/// The ``CommandInterpreter`` is the pure chord → ``WorkspaceCommand`` mapping (docs/22 §5): the
/// single tested core that the macOS menu bar, the iPad `UIKeyCommand` layer, and the compact
/// on-screen affordances all funnel through. These tests pin:
///
/// - **Every shipped default binding** resolves to the exact command (the load-bearing fact that
///   ⌘D splits, ⌥⌘← moves focus, ⌘1…⌘9 selects, etc.).
/// - **The case-insensitivity convention** — `KeyChord(character:)` lower-cases the base key, so
///   ⇧ is carried only by `.shift`; `"D"` and `"d"` are the same chord, and ⇧⌘D needs an explicit
///   `.shift` rather than an upper-case letter.
/// - **Unbound chords fall through** (`feed` returns `nil`) — the §5 conflict rule that lets plain
///   keys reach the focused terminal untouched.
/// - **Rebinding works** — both by mutating `bindings` and by injecting a custom table at init.
/// - **The virtual-clock seam is wired but inert** — `feed` does not currently schedule, so a
///   `ManualRepeatScheduler` advanced past any window leaves the mapping unchanged (the seam exists
///   for parity with ``KeyRepeater`` for future timed/chorded intents).
///
/// `CommandInterpreter` is `@MainActor`, so the whole suite is `@MainActor` (still synchronous —
/// no async, no client, no store).
@MainActor
final class CommandInterpreterTests: XCTestCase {

    // MARK: - Every default binding maps to the expected command

    /// Table-driven assertion over the entire shipped default binding set. If a default chord is
    /// renamed, retargeted, or dropped, this fails on the exact entry — the bindings are a public
    /// contract (menu shortcuts, muscle memory), so they are pinned individually.
    func testDefaultBindingsMapToExpectedCommands() {
        let interpreter = CommandInterpreter()

        let expected: [(KeyChord, WorkspaceCommand)] = [
            // Splits.
            (KeyChord(character: "d", [.command]),                 .splitHorizontal),
            (KeyChord(character: "d", [.command, .shift]),         .splitVertical),
            // Close.
            (KeyChord(character: "w", [.command]),                 .closePane),
            (KeyChord(character: "w", [.command, .shift]),         .closeTab),
            // Tabs.
            (KeyChord(character: "t", [.command]),                 .newTab),
            (KeyChord(.tab, [.control]),                           .nextTab),
            (KeyChord(.tab, [.control, .shift]),                   .prevTab),
            // Geometric focus.
            (KeyChord(.leftArrow, [.option, .command]),            .focus(.left)),
            (KeyChord(.rightArrow, [.option, .command]),           .focus(.right)),
            (KeyChord(.upArrow, [.option, .command]),              .focus(.up)),
            (KeyChord(.downArrow, [.option, .command]),            .focus(.down)),
            // Cycle focus.
            (KeyChord(character: "]", [.command]),                 .cycleFocus(forward: true)),
            (KeyChord(character: "[", [.command]),                 .cycleFocus(forward: false)),
            // Zoom + rename.
            (KeyChord(.return, [.command, .shift]),                .toggleZoom),
            (KeyChord(character: "r", [.command]),                 .renameTab)
        ]

        for (chord, command) in expected {
            XCTAssertEqual(interpreter.feed(chord), command, "chord \(chord) must map to \(command)")
        }
    }

    /// ⌘1…⌘9 each resolve to `selectTab(n)` with the matching 1-based position (the menu / store
    /// position convention, docs/22 §5).
    func testSelectTabDigitsOneThroughNine() {
        let interpreter = CommandInterpreter()
        for n in 1...9 {
            let chord = KeyChord(character: Character(String(n)), [.command])
            XCTAssertEqual(interpreter.feed(chord), .selectTab(n), "⌘\(n) selects tab position \(n)")
        }
    }

    // MARK: - Case-insensitivity convention (⇧ is in modifiers, not the char)

    /// `KeyChord(character:)` lower-cases the base key, so an upper-case letter without `.shift` is
    /// the same chord as the lower-case one — `⌘D` (typed with caps) still maps to splitHorizontal,
    /// it is NOT mistaken for ⇧⌘D.
    func testUpperCaseCharIsNormalizedToLowerCaseBaseKey() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(
            KeyChord(character: "D", [.command]),
            KeyChord(character: "d", [.command]),
            "the convenience init lower-cases the base key — case is not part of identity"
        )
        XCTAssertEqual(interpreter.feed(KeyChord(character: "D", [.command])), .splitHorizontal)
        // The vertical split requires an EXPLICIT .shift, not an upper-case char.
        XCTAssertEqual(interpreter.feed(KeyChord(character: "D", [.command, .shift])), .splitVertical)
        XCTAssertEqual(
            interpreter.feed(KeyChord(character: "d", [.command, .shift])),
            .splitVertical,
            "shift is carried by the modifier set, identically for 'd' and 'D'"
        )
    }

    // MARK: - Unbound chords fall through (nil)

    /// A chord that is not in the table returns `nil` — the interpreter consumes nothing it does
    /// not own, so plain keys reach the focused terminal (the §5 terminal-conflict rule).
    func testUnboundChordReturnsNil() {
        let interpreter = CommandInterpreter()
        // A bare letter (no ⌘/⌥) is never a workspace chord — it belongs to the terminal.
        XCTAssertNil(interpreter.feed(KeyChord(character: "a")))
        // A bound base key with the WRONG modifiers is also unbound.
        XCTAssertNil(interpreter.feed(KeyChord(character: "d")), "⌘ is required — bare 'd' falls through")
        XCTAssertNil(interpreter.feed(KeyChord(character: "d", [.control])), "⌃D is not a workspace chord")
        // A named key with no binding.
        XCTAssertNil(interpreter.feed(KeyChord(.return)))
        // ⌘0 is not bound (digits are 1...9 only).
        XCTAssertNil(interpreter.feed(KeyChord(character: "0", [.command])))
    }

    // MARK: - Rebinding

    /// Mutating `bindings` at runtime takes effect on the next `feed` (a settings screen can rebind
    /// live); the old chord stops resolving and the new chord resolves to the remapped command.
    func testRebindingViaMutableBindingsTakesEffect() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command])), .splitHorizontal)

        // Remap ⌘D to newTab and drop the old meaning.
        interpreter.bindings[KeyChord(character: "d", [.command])] = .newTab
        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command])), .newTab, "rebind takes effect")

        // Remove a binding entirely → it falls through.
        interpreter.bindings[KeyChord(character: "w", [.command])] = nil
        XCTAssertNil(interpreter.feed(KeyChord(character: "w", [.command])), "removed binding falls through")
    }

    /// A fully custom table injected at init replaces the defaults wholesale — only the supplied
    /// chords resolve, everything else falls through.
    func testCustomBindingsAtInitReplaceDefaults() {
        let custom: [KeyChord: WorkspaceCommand] = [
            KeyChord(character: "x", [.command]): .closePane
        ]
        let interpreter = CommandInterpreter(bindings: custom)
        XCTAssertEqual(interpreter.feed(KeyChord(character: "x", [.command])), .closePane)
        // A DEFAULT chord is NOT present because the custom table replaced the defaults.
        XCTAssertNil(interpreter.feed(KeyChord(character: "d", [.command])), "custom table replaces, not merges")
    }

    /// `defaultBindings` is a COMPUTED property — each access rebuilds a fresh, equal table. Pin
    /// that (a) it is non-empty, (b) two accesses are equal, and (c) mutating an interpreter's copy
    /// does not leak back into the static default.
    func testDefaultBindingsIsFreshlyRebuiltAndIsolated() {
        let a = CommandInterpreter.defaultBindings
        let b = CommandInterpreter.defaultBindings
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "defaultBindings is deterministic across accesses")

        let interpreter = CommandInterpreter()
        interpreter.bindings.removeAll()
        XCTAssertTrue(interpreter.bindings.isEmpty)
        XCTAssertFalse(CommandInterpreter.defaultBindings.isEmpty, "mutating an instance does not corrupt the static default")
    }

    // MARK: - The injected clock seam (parity, currently inert)

    /// The interpreter accepts a `RepeatScheduler` for parity with ``KeyRepeater`` (future timed /
    /// chorded intents), but the current pure mapping does not schedule. Advancing the injected
    /// virtual clock past any plausible window must therefore change nothing — `feed` stays a pure
    /// function of the chord. This both documents the seam and guards against an accidental
    /// time-dependence creeping into the mapping.
    func testInjectedClockDoesNotAffectMappingAndArmsNoTimers() {
        let scheduler = ManualRepeatScheduler()
        let interpreter = CommandInterpreter(clock: scheduler)

        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command])), .splitHorizontal)
        XCTAssertEqual(scheduler.pendingCount, 0, "feed schedules nothing on the injected clock")

        // Advance virtual time well past any prefix/timeout window — mapping is unchanged.
        scheduler.advance(by: .seconds(10))
        XCTAssertEqual(interpreter.feed(KeyChord(character: "d", [.command])), .splitHorizontal, "mapping is time-independent")
        XCTAssertEqual(scheduler.pendingCount, 0, "still no armed timers after advancing the clock")
    }

    // MARK: - WorkspaceCommand value semantics (associated values compare)

    /// `WorkspaceCommand` is `Equatable` with its associated values significant — `selectTab(1)` is
    /// not `selectTab(2)`, `focus(.left)` is not `focus(.right)`, `cycleFocus(forward:)` is
    /// direction-sensitive. The whole binding-assertion strategy above relies on this; pin it.
    func testWorkspaceCommandEqualityIsAssociatedValueSensitive() {
        XCTAssertNotEqual(WorkspaceCommand.selectTab(1), .selectTab(2))
        XCTAssertEqual(WorkspaceCommand.selectTab(3), .selectTab(3))
        XCTAssertNotEqual(WorkspaceCommand.focus(.left), .focus(.right))
        XCTAssertNotEqual(WorkspaceCommand.cycleFocus(forward: true), .cycleFocus(forward: false))
        XCTAssertEqual(WorkspaceCommand.toggleZoom, .toggleZoom)
    }
}
