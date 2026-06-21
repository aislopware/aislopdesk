import Foundation

// MARK: - TerminalContextMenu (pure right-click menu model + enablement)

/// The PURE model behind the terminal right-click context menu (docs/42 W14 #10, Ghostty/Warp parity):
/// the ordered item list and — the testable heart — each item's **enablement** for the current pane
/// state (copy needs a selection, paste needs clipboard text, splits need a connected pane). The GUI
/// `NSMenu` built in `GhosttyLayerBackedView.menu(for:)` is a thin renderer over this; routing each item
/// to libghostty (`copy_to_clipboard` / `paste_from_clipboard` / `select_all` / `clear_screen` binding
/// actions) and to the ``WorkspaceStore`` split/find ops is compile-only. Factoring enablement here keeps
/// it unit-testable with no view (the W14 brief's explicit ask).
public enum TerminalContextMenu {
    /// One menu action. Raw `String` so the GUI can tag each `NSMenuItem.representedObject` and dispatch
    /// without a parallel switch, and so the cheat-sheet/tests reference stable ids.
    public enum Item: String, CaseIterable, Sendable, Equatable {
        case copy
        case paste
        case pasteAsKeystrokes
        case selectAll
        case clear
        case copyOutput // WB2: copy the latest command BLOCK's output (request type 15 → VT-strip → clipboard)
        case splitRight
        case splitDown
        case find

        /// The menu label (sentence case, matching the macOS HIG + the rest of the app's verbs).
        public var title: String {
            switch self {
            case .copy: "Copy"
            case .paste: "Paste"
            case .pasteAsKeystrokes: "Paste as Keystrokes"
            case .selectAll: "Select All"
            case .clear: "Clear"
            case .copyOutput: "Copy Command Output"
            case .splitRight: "Split Right"
            case .splitDown: "Split Down"
            case .find: "Find…"
            }
        }

        /// SF Symbol for the menu row (matches the binding-registry glyph vocabulary).
        public var symbol: String {
            switch self {
            case .copy: "doc.on.doc"
            case .paste: "clipboard"
            case .pasteAsKeystrokes: "keyboard"
            case .selectAll: "selection.pin.in.out"
            case .clear: "eraser"
            case .copyOutput: "text.alignleft"
            case .splitRight: "rectangle.split.2x1"
            case .splitDown: "rectangle.split.1x2"
            case .find: "magnifyingglass"
            }
        }

        /// Whether a thin SEPARATOR is drawn ABOVE this item, grouping clipboard / edit / blocks / split / find.
        public var separatorBefore: Bool {
            switch self {
            case .selectAll,
                 .copyOutput,
                 .splitRight,
                 .find: true
            default: false
            }
        }
    }

    /// The inputs that decide each item's enablement — a pure snapshot the view captures at right-click
    /// time (libghostty `has_selection`, the host pasteboard, and whether the pane's transport is live).
    public struct Context: Equatable, Sendable {
        /// The surface currently holds a text selection (`ghostty_surface_has_selection`).
        public var hasSelection: Bool
        /// The host pasteboard has a non-empty string (so Paste / Paste-as-Keystrokes have something to do).
        public var clipboardHasText: Bool
        /// The pane's PTY/transport is connected (splits/find are pointless on a dead pane — but they
        /// stay enabled here because they target the WORKSPACE, not the byte stream; only the byte-stream
        /// items gate on it). Kept for symmetry / future gating.
        public var paneConnected: Bool
        /// WB2: the pane has at least one completed command BLOCK whose output can be fetched (gates
        /// "Copy Command Output"). The request still tolerates an empty reply, but greying it out when there
        /// is no block at all is the honest affordance.
        public var hasCommandOutput: Bool

        public init(
            hasSelection: Bool,
            clipboardHasText: Bool,
            paneConnected: Bool = true,
            hasCommandOutput: Bool = false,
        ) {
            self.hasSelection = hasSelection
            self.clipboardHasText = clipboardHasText
            self.paneConnected = paneConnected
            self.hasCommandOutput = hasCommandOutput
        }
    }

    /// The menu items in display order. Stable; the view renders separators from `Item.separatorBefore`.
    public static let items: [Item] = Item.allCases

    /// Whether `item` is enabled for `context` — the testable enablement rule:
    /// - **Copy** needs a live selection.
    /// - **Paste / Paste as Keystrokes** need non-empty clipboard text.
    /// - **Copy Command Output** (WB2) needs a completed command block to fetch.
    /// - **Select All / Clear / Split Right / Split Down / Find** are always available (Select-All/Clear
    ///   act on the surface regardless of selection; splits + find act on the workspace).
    public static func isEnabled(_ item: Item, context: Context) -> Bool {
        switch item {
        case .copy:
            context.hasSelection
        case .paste,
             .pasteAsKeystrokes:
            context.clipboardHasText
        case .copyOutput:
            context.hasCommandOutput
        case .selectAll,
             .clear,
             .splitRight,
             .splitDown,
             .find:
            true
        }
    }
}
