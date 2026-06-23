// ContextMenuModel — the pure per-pane / per-tab overflow-menu item catalog (warp-overlays-actions.md
// §3.3 `Menu<WorkspaceAction>`). The PaneHeader ⋮ and the rail TabRow kebab both build their items from
// here so the action mapping is one auditable, unit-testable place (no view).
//
// Each `ContextMenuItem` carries a typed `run` closure over the store + the specific pane/tab id, plus an
// optional shortcut hint and a `role` (so the view can tint a destructive "Close" red). Separators are
// `nil`-action divider markers.

import AislopdeskWorkspaceCore
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Write `text` to the system clipboard (platform-specific). Used by the "Copy Path" menu item.
@MainActor
func copyTextToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = text
    #endif
}

/// One context-menu row. A separator carries an empty title + `isSeparator`.
public struct ContextMenuItem: Identifiable, Sendable {
    public enum Role: Sendable, Equatable { case normal, destructive }

    public let id: String
    public let icon: String
    public let title: String
    public let shortcut: String?
    public let role: Role
    public let isSeparator: Bool
    /// The store mutation this item runs (nil for a separator).
    public let run: (@MainActor @Sendable (WorkspaceStore) -> Void)?

    @preconcurrency
    public init(
        id: String,
        icon: String,
        title: String,
        shortcut: String? = nil,
        role: Role = .normal,
        isSeparator: Bool = false,
        run: (@MainActor @Sendable (WorkspaceStore) -> Void)? = nil,
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.role = role
        self.isSeparator = isSeparator
        self.run = run
    }

    static func separator(_ id: String) -> Self {
        Self(id: "sep.\(id)", icon: "", title: "", isSeparator: true)
    }
}

/// Builds the menu item lists for a pane (the ⋮ header overflow) and a tab (the rail kebab).
public enum ContextMenuModel {
    /// The pane overflow (⋮) menu for `paneID`. Split / rename / reconnect / copy-path / close — each routed
    /// to the tree-path store API. `isInSplit` gates the "Close Pane" destructive row (a lone pane in a tab
    /// closes the tab via a separate item).
    public static func paneItems(paneID: PaneID, lastKnownCwd: String?, isInSplit: Bool) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = [
            ContextMenuItem(
                id: "pane.splitRight", icon: "rectangle.split.2x1", title: "Split Right",
                run: { store in
                    store.focusPaneTree(paneID)
                    store.splitActivePane(axis: .horizontal, kind: .terminal)
                },
            ),
            ContextMenuItem(
                id: "pane.splitDown", icon: "rectangle.split.1x2", title: "Split Down",
                run: { store in
                    store.focusPaneTree(paneID)
                    store.splitActivePane(axis: .vertical, kind: .terminal)
                },
            ),
            .separator("pane.1"),
            ContextMenuItem(
                id: "pane.rename", icon: "pencil", title: "Rename…",
                run: { store in
                    store.focusPaneTree(paneID)
                    store.requestRenameActivePane()
                },
            ),
            ContextMenuItem(
                id: "pane.reconnect", icon: "arrow.clockwise", title: "Reconnect",
                run: { store in store.reconnect(paneID) },
            ),
        ]
        if let cwd = lastKnownCwd, !cwd.isEmpty {
            items.append(ContextMenuItem(
                id: "pane.copyPath", icon: "doc.on.doc", title: "Copy Path",
                run: { _ in copyTextToClipboard(cwd) },
            ))
        }
        items.append(.separator("pane.2"))
        items.append(ContextMenuItem(
            id: "pane.close", icon: "xmark", title: isInSplit ? "Close Pane" : "Close Tab",
            role: .destructive,
            run: { store in store.requestClosePaneTree(paneID) },
        ))
        return items
    }

    /// The tab kebab menu for the tab containing `paneID` (`tabID`). Focus / split / rename-tab / close-tab.
    public static func tabItems(paneID: PaneID, tabID: TabID) -> [ContextMenuItem] {
        [
            ContextMenuItem(
                id: "tab.focus", icon: "scope", title: "Go to Pane",
                run: { store in store.focusPaneTree(paneID) },
            ),
            ContextMenuItem(
                id: "tab.splitRight", icon: "rectangle.split.2x1", title: "Split Right",
                run: { store in
                    store.focusPaneTree(paneID)
                    store.splitActivePane(axis: .horizontal, kind: .terminal)
                },
            ),
            .separator("tab.1"),
            ContextMenuItem(
                id: "tab.close", icon: "xmark", title: "Close Tab", role: .destructive,
                run: { store in store.closeTab(tabID) },
            ),
        ]
    }
}
