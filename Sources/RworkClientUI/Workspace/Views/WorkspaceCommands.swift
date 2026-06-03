#if canImport(SwiftUI)
import SwiftUI

// MARK: - WorkspaceCommands (native menu-bar / hardware-keyboard shortcuts)

/// The native command surface for the workspace: a `Pane` menu and a `Tab` menu whose every item is
/// a `.keyboardShortcut`-decorated `Button` that builds a ``WorkspaceCommand`` and applies it — via
/// the one tested `apply(_:to:)` free function — to the focused scene's ``WorkspaceStore`` (docs/22
/// §5). This is the *thin adapter* the architecture calls for: it owns no logic, it maps a menu
/// click / shortcut onto the same pure command enum the ``CommandInterpreter`` produces and the
/// compact on-screen affordances emit.
///
/// ### The conflict rule, expressed in shortcuts (load-bearing — docs/22 §5)
/// Every shortcut here is ⌘- or ⌥-prefixed, mirroring ``CommandInterpreter/defaultBindings`` exactly.
/// That is what lets plain keys and Ctrl-letters fall through to the focused terminal untouched
/// (`TerminalInputHost.encode` returns `nil` for ⌘/⌥ combos): the menu bar claims a chord only when
/// it carries ⌘ or ⌥, so the shell keeps every bare key. Focus-move is ⌥⌘+arrows specifically
/// because the plain arrows belong to the shell. There is no bare-key shortcut anywhere in this file.
///
/// ### One surface, two platforms
/// On macOS this renders as menu-bar menus. On iPadOS the same `Commands` drive the hardware-keyboard
/// shortcut HUD (hold ⌘) and the discoverability list — so the iPad gets the identical command
/// surface for free, with no separate `UIKeyCommand` table to keep in sync.
///
/// ### Targeting the active window
/// Items act on `@FocusedValue(\.workspaceStore)` — the store the key scene published via
/// `.publishingWorkspaceStore(_:)`. When no workspace window is key the value is `nil` and every item
/// disables itself, which is the native, correct grey-out.
///
/// Mount it on the `WindowGroup` scene: `WindowGroup { … }.commands { WorkspaceCommands() }`.
public struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceStore) private var store: WorkspaceStore?

    public init() {}

    public var body: some Commands {
        // The Pane menu reads as a workspace-level menu alongside the OS chrome. `CommandMenu`'s
        // trailing closure is a `@ViewBuilder` (Buttons + Dividers), not nested `Commands` — every
        // Button funnels its `WorkspaceCommand` through `apply(_:to:)`.
        CommandMenu("Pane") {
            paneMenu
        }
        CommandMenu("Tab") {
            tabMenu
        }
    }

    // MARK: - Pane menu

    @ViewBuilder
    private var paneMenu: some View {
        commandButton("Split Horizontally", .splitHorizontal)
            .keyboardShortcut("d", modifiers: .command)
        commandButton("Split Vertically", .splitVertical)
            .keyboardShortcut("d", modifiers: [.command, .shift])

        Divider()

        commandButton("Focus Left", .focus(.left))
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
        commandButton("Focus Right", .focus(.right))
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
        commandButton("Focus Up", .focus(.up))
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
        commandButton("Focus Down", .focus(.down))
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])

        Divider()

        commandButton("Cycle Forward", .cycleFocus(forward: true))
            .keyboardShortcut("]", modifiers: .command)
        commandButton("Cycle Back", .cycleFocus(forward: false))
            .keyboardShortcut("[", modifiers: .command)

        Divider()

        commandButton("Zoom Pane", .toggleZoom)
            // ⇧⌘↩ — the zoom toggle. `.return` is the named key equivalent.
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        commandButton("Close Pane", .closePane)
            .keyboardShortcut("w", modifiers: .command)
    }

    // MARK: - Tab menu

    @ViewBuilder
    private var tabMenu: some View {
        commandButton("New Tab", .newTab)
            .keyboardShortcut("t", modifiers: .command)
        commandButton("Rename Tab…", .renameTab)
            .keyboardShortcut("r", modifiers: .command)

        Divider()

        commandButton("Next Tab", .nextTab)
            .keyboardShortcut(.tab, modifiers: .control)
        commandButton("Previous Tab", .prevTab)
            .keyboardShortcut(.tab, modifiers: [.control, .shift])

        Divider()

        // Select tab ⌘1…⌘9 (1-based menu position; ⌘9 = last by store convention). The digit key is
        // a `KeyEquivalent` from its Character.
        ForEach(1...9, id: \.self) { position in
            commandButton("Select Tab \(position)", .selectTab(position))
                .keyboardShortcut(
                    KeyEquivalent(Character(String(position))),
                    modifiers: .command
                )
        }

        Divider()

        commandButton("Close Tab", .closeTab)
            .keyboardShortcut("w", modifiers: [.command, .shift])
    }

    // MARK: - Item builder

    /// A menu `Button` that applies `command` to the focused store, disabled when no store is key.
    @ViewBuilder
    private func commandButton(_ title: String, _ command: WorkspaceCommand) -> some View {
        Button(title) {
            if let store { apply(command, to: store) }
        }
        .disabled(store == nil)
    }
}
#endif
