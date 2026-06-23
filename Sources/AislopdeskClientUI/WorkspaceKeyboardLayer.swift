// WorkspaceKeyboardLayer — the rebuilt UI's keyboard surface (W11 regression fix).
//
// The L0 rewrite dropped the old `.commands { WorkspaceCommands() }` menu/keyboard layer; only ⌘K / ⌘⇧P
// survived. This restores keyboard reach for every workspace verb WITHOUT resurrecting the deleted
// `WorkspaceCommands(store:overlay:)`: a hidden, zero-size bank of `Button`s — one per
// `WorkspaceBindingRegistry` binding, each carrying the registry's own chord via `.keyboardShortcut(...)`
// and firing `WorkspaceBindingRegistry.route(action, to: store, …)`. This funnels through the SAME single
// source of truth the ⌘K palette rows display, so the displayed `shortcut:` glyph and the real binding
// can't drift (DECISIONS "no dead chord / glyph cannot drift"). Every chord is ⌘/⌥-prefixed (the registry
// guards that), so it never collides with a bare ⌘A/C/V/W or a Ctrl-letter the terminal wants.
//
// Reuses the same hidden-button mechanism the rebuilt root already used for ⌘K/⌘⇧P; works on macOS + iOS
// (no NSMenu), per the W11 "Option 2" shape.

import AislopdeskWorkspaceCore
import SwiftUI

/// Converts a headless ``KeyChord`` into the SwiftUI `(KeyEquivalent, EventModifiers)` a
/// `.keyboardShortcut` needs. Pure; lives in ClientUI because `KeyEquivalent`/`EventModifiers` are SwiftUI.
enum WorkspaceChordBridge {
    static func keyEquivalent(_ key: KeyChord.Key) -> KeyEquivalent? {
        switch key {
        case let .character(c): KeyEquivalent(Character(c.lowercased()))
        case .tab: .tab
        case .return: .return
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        }
    }

    static func modifiers(_ mods: KeyChord.Modifiers) -> EventModifiers {
        var out: EventModifiers = []
        if mods.contains(.command) { out.insert(.command) }
        if mods.contains(.shift) { out.insert(.shift) }
        if mods.contains(.option) { out.insert(.option) }
        if mods.contains(.control) { out.insert(.control) }
        return out
    }
}

/// A hidden zero-size button bank that registers every `WorkspaceBindingRegistry` chord. Mounted in the
/// root view's `.background`; SwiftUI routes the matching chord to the button's action even though it is
/// invisible. The palette / cheat-sheet / find / peek-reply view toggles are passed as closures so the
/// registry routing reaches them; everything else lands on a `WorkspaceStore` tree op.
struct WorkspaceKeyboardBank: View {
    let store: WorkspaceStore
    /// ⌘K command-palette toggle (also drives ⌘⇧P below).
    var togglePalette: () -> Void = {}

    var body: some View {
        Group {
            ForEach(Array(WorkspaceBindingRegistry.allBindings.enumerated()), id: \.offset) { _, binding in
                if let chord = binding.chord,
                   let key = WorkspaceChordBridge.keyEquivalent(chord.key)
                {
                    Button("") {
                        WorkspaceBindingRegistry.route(
                            binding.action,
                            to: store,
                            togglePalette: togglePalette,
                            // cheatSheet / peekReply have no overlay in the rebuilt tree yet → no-op (the
                            // registry routing tolerates nil); find lands on the store's active-pane hook.
                            toggleCheatSheet: nil,
                            toggleFind: nil,
                            togglePeekReply: nil,
                        )
                    }
                    .keyboardShortcut(key, modifiers: WorkspaceChordBridge.modifiers(chord.modifiers))
                }
            }
            // ⌘⇧P — open the palette in command mode (kept from the rebuilt root; the registry only carries
            // ⌘K for the palette, so this is an explicit extra entry, not a registry chord).
            Button("") { togglePalette() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
