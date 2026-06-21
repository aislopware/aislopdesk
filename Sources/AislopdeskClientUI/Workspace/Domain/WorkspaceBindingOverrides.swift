import AislopdeskVideoProtocol
import Foundation

// MARK: - WorkspaceBindingRegistry × KeybindingPreferences (W13 — user overrides)

/// W13: the wiring that makes the W6 ``WorkspaceBindingRegistry`` resolve a chord using the W12
/// ``KeybindingPreferences`` OVERRIDE when one is present — WITHOUT duplicating the binding table. The
/// registry stays the single source of truth for the available commands + their DEFAULT chords; this
/// extension layers a sparse `bindingID → chord` override map on top.
///
/// Two `KeyChord` shapes meet here:
///   • the registry's framework-neutral ``KeyChord`` (enum `Key` + `Modifiers` OptionSet), the keyboard
///     dispatcher's join key;
///   • W12's serialisable ``KeybindingPreferences/KeyChord`` (a `key: String` + four `Bool` modifier
///     flags), what the Settings UI stores + round-trips.
/// ``KeybindingPreferences/KeyChord/asRegistryChord`` maps the persisted shape into the dispatcher
/// shape so `resolvedChord(for:)` and `resolvedChordTable` honour an override transparently.
public extension WorkspaceBindingRegistry {
    /// The process-wide live keybinding overrides, published by the ``PreferencesStore`` on a settings
    /// change (W13 apply path #4). EMPTY by default ⇒ every binding resolves to its registry default ⇒
    /// behaviour-identical to W6. `nonisolated(unsafe)` for the same write-once-then-read-many contract
    /// as ``EnvConfig/overlay``: the store sets it on the main actor; the dispatcher reads it.
    nonisolated(unsafe) static var activeOverrides = KeybindingPreferences()

    /// The chord that should fire `action` RIGHT NOW: the user override (if one is set for the action's
    /// binding id) else the registry default. The keyboard dispatcher + the menu-shortcut derivation use
    /// this so a rebind takes effect everywhere from one place.
    static func resolvedChord(for action: WorkspaceAction) -> KeyChord? {
        resolvedChord(for: action, overrides: activeOverrides)
    }

    /// Override-aware resolution against an EXPLICIT override set (the pure, testable form). An override
    /// for the action's binding id (`KeybindingPreferences.chord(for:)`) wins; otherwise the registry
    /// default stands. An override whose persisted chord can't map to a registry chord (a malformed
    /// stored value) is IGNORED → falls back to the default (validate-then-default, never traps).
    static func resolvedChord(for action: WorkspaceAction, overrides: KeybindingPreferences) -> KeyChord? {
        guard let binding = binding(for: action) else { return nil }
        if let override = overrides.chord(for: binding.id), let mapped = override.asRegistryChord {
            return mapped
        }
        return binding.chord
    }

    /// The chord → action lookup table WITH the active overrides applied — the override-aware sibling of
    /// ``chordTable``. The keyboard dispatcher reads THIS so a rebind routes the new chord. A binding whose
    /// override collides with another binding's chord is last-writer-wins in the map (the UI surfaces the
    /// collision via ``KeybindingPreferences/conflicts()`` so the user resolves it).
    static var resolvedChordTable: [KeyChord: WorkspaceAction] {
        resolvedChordTable(overrides: activeOverrides)
    }

    /// The override-aware chord table against an explicit override set (pure, testable).
    static func resolvedChordTable(overrides: KeybindingPreferences) -> [KeyChord: WorkspaceAction] {
        var map: [KeyChord: WorkspaceAction] = [:]
        for binding in allBindings {
            if let chord = resolvedChord(for: binding.action, overrides: overrides) {
                map[chord] = binding.action
            }
        }
        return map
    }
}

// MARK: - KeybindingPreferences.KeyChord → registry KeyChord

public extension KeybindingPreferences.KeyChord {
    /// Map the persisted W12 chord (`key: String` + modifier flags) into the registry's framework-neutral
    /// ``KeyChord``. Named keys (`"return"`, `"left"`, `"tab"`, …) map to the registry's `Key` cases; a
    /// single printable character maps to `.character`. An empty / multi-char / unknown-named key yields
    /// `nil` (validate-then-default: the resolver then keeps the registry default).
    var asRegistryChord: KeyChord? {
        guard let mappedKey = Self.mapKey(key) else { return nil }
        var mods: KeyChord.Modifiers = []
        if shift { mods.insert(.shift) }
        if control { mods.insert(.control) }
        if option { mods.insert(.option) }
        if command { mods.insert(.command) }
        return KeyChord(mappedKey, mods)
    }

    /// Map a normalised key token (lowercased single char or a named key) to the registry `Key`. Returns
    /// `nil` for an empty / multi-char / unrecognised-named key.
    private static func mapKey(_ key: String) -> KeyChord.Key? {
        switch key {
        case "return",
             "enter": return .return
        case "tab": return .tab
        case "left",
             "leftarrow": return .leftArrow
        case "right",
             "rightarrow": return .rightArrow
        case "up",
             "uparrow": return .upArrow
        case "down",
             "downarrow": return .downArrow
        default:
            // A single printable character (already lowercased by KeyChord.init). Reject empty / multi.
            guard key.count == 1, let c = key.first else { return nil }
            return .character(c)
        }
    }
}
