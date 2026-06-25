## Overview

The aislopdesk client UI shell is a native SwiftUI + AppKit hybrid implementing a 3-column IDE layout
(navigator | content | inspector) modelled on CodeEdit's split shell. The macOS host is an
`NSSplitViewController` (`AislopdeskSplitViewController`) with three `NSHostingController` columns;
iOS uses `NavigationSplitView`. The window runs `.hiddenTitleBar`; otty's own hover-reveal
`OttyTitlebar` is the sole chrome. The domain model is a fully implemented `TreeWorkspace`
(`Session → Tab → SplitNode tree → Pane`) stored in `WorkspaceStore`.

All assessment is against the macOS path unless noted.

---

## Capability matrix

| Feature | Status | Evidence file(s) / symbol(s) |
|---------|--------|-------------------------------|
| **Window / shell** | | |
| 3-column IDE shell (navigator \| content \| inspector) | done | `AislopdeskSplitViewController:L16`, `WorkspaceRootView:L47` |
| Hidden-titlebar + hover-reveal chrome | done | `OttyTitlebar.swift`, `AislopdeskClientApp.swift:L282` `.windowStyle(.hiddenTitleBar)` |
| Sidebar collapse (⌘⇧L) | done | `WorkspaceChromeState:L23`, `OttyTitlebar:L101`, `applyCollapse:L210` in `AislopdeskSplitViewController` |
| Inspector collapse (⌘⇧R) | done | `WorkspaceChromeState:L25`, `OttyTitlebar:L104`, same `applyCollapse` path |
| Animated collapse (NSSplitViewItem animator) | done | `AislopdeskSplitViewController:L211–216` |
| Theme-aware flat divider (ISA-swizzle `FlatDividerSplitView`) | done | `AislopdeskSplitViewController:L54`, `FlatDividerSplitView:L226` |
| macOS window appearance pinned to active theme | done | `pinWindowAppearance():L176` |
| iOS NavigationSplitView shell | done | `WorkspaceRootView:L50–58` |
| Connect-to-host overlay (host/port editor) | partial | `OverlayCoordinator.connectVisible:L52`, `openConnect():L251` — state exists, overlay view **not mounted** in `WorkspaceRootView`; `openConnect()` in pill is a `TODO(L4b)` no-op (`WorkspaceRootView:L88`) |
| **Tab / session model** | | |
| Session → Tab → Pane domain model | done | `TreeWorkspace.swift`, `Tab.swift`, `SplitNode.swift` — full `Codable` + schema v11 |
| Multiple sessions | done | `TreeWorkspace.sessions:[Session]`; `WorkspaceStore.selectSession` |
| Multiple tabs per session | done | `Session.tabs:[Tab]`; `cycleTab(by:)`, `selectTabNumber(_:)` |
| New tab (chooser pane flow) | done | `openChooserPane(.newTab)` → `InPaneChooserView`; wired in titlebar `+`, iOS toolbar, palette |
| New session | done | `openChooserPane(.newSession)` routed via `WorkspaceBindingRouting:L125` |
| Close tab | done | `closeActiveTab()` in routing; `requestClosePaneTree` for sidebar × |
| Cycle tabs (⌘⇧\[ / ]) | done | `cycleTab(by:1/-1)` in `WorkspaceBindingRouting:L119` |
| Select tab by number (⌘1…⌘9) | done | `selectTabNumber(_:)` via `WorkspaceBindingRouting:L121` |
| Break pane to own tab | done | `breakActivePaneToTab()` in routing:L66 |
| **Sidebar / navigator** | | |
| Vertical tab list (sidebar rail) | done | `NavigatorColumn.macSidebar`, `OttyTabRow` — one row per pane of the active session |
| Otty flat white-card active row | done | `OttyTabRow:L34–44` — white card + border + faint shadow when `active` |
| Close × on hover | done | `OttyTabRow:L47–54` |
| Sort / group hamburger | done | `OttySortMenuButton` — UI present; grouping/ordering is **presentational only** (local `@State`, does not reorder the store) |
| Agent-status badge on tab row | partial | `RailRow.status:ClaudeStatus` is computed by `RailRowsBuilder:L38`; `OttyTabRow` accepts only `title/active/onSelect/onClose` — the status field is **never rendered**. Badge dot missing. |
| Pane subtitle (cwd) in sidebar | partial | `RailRow.subtitle` populated from `spec.lastKnownCwd:L39`; `OttyTabRow` shows only the title — subtitle **not displayed** |
| Tab search / filter in sidebar | missing | No search field in `NavigatorColumn`; `RailRowsBuilder.filtered(_:query:)` exists but is not called from any view |
| iOS sidebar (List + NavigationSplitView) | done | `NavigatorColumn.iosSidebar:L78` |
| **Content / pane grid** | | |
| Absolute-rect pane compositor (no nested HSplitView) | done | `SplitContainer` — identity-preserving ZStack, `SplitTreeRenderModel.layout(for:in:)` |
| Pane resize scrim (covers stale surface during drag) | done | `PaneContainer:L117–152` — three-signal OR (geometry settle + drag-sticky + model reflow) |
| Pane unfocus dimming | done | `PaneContainer:L161` `.opacity(isFocused ? 1 : Otty.Anim.unfocusedPaneOpacity)` |
| Empty-state (no session) | done | `ContentColumn:L47` `ContentUnavailableView("No Session", …)` |
| **Pane splits + resize** | | |
| Horizontal split (⌘D) | done | `openChooserPane(.split(axis:.horizontal))` in routing:L61; `InPaneChooserView` |
| Vertical split (⌘⇧D) | done | `openChooserPane(.split(axis:.vertical))` in routing:L63 |
| Live-resize divider (drag) | done | `PaneDivider` — absolute-from-start weight, stable coordinate space, no ghost-seam |
| Resize cursor on divider hover | done | `PaneDivider:L63` `.pointerStyle(…columnResize / rowResize)` |
| Double-click divider to equalize | done | `PaneDivider:L79` `.onTapGesture(count:2)` → `onReset` → `store.balanceActivePaneSplits()` |
| Keyboard equalize (⌥⌘=) | done | `WorkspaceBindingRouting:L85` `.balancePanes` → `balanceActivePaneSplits()` |
| Keyboard pane resize (⌥⌘arrow) | done | `WorkspaceBindingRouting:L80–83` `.resizePaneLeft/Right/Up/Down` → `store.resizeActivePane` |
| Commit-on-release (defer grid to host) | done | `SplitContainer:L85–96` `setTerminalResizeSuspended` + `commitDividerResize()` |
| Zoom / maximize active pane (⌥⌘↩) | done | `toggleZoomActivePane()` in routing:L95; `Tab.zoomedPane` driven by `SplitTreeRenderModel` |
| **Drag-drop drop zones** | | |
| Grab handle pill (drag to move) | done | `PaneMoveHandle` in `PaneMoveAffordance.swift` — hover-reveal capsule pill |
| Swap zone (centre of target) | done | `SplitContainer.resolveZone:L196` `.swap(target:)` |
| Re-split zone (edge band of target) | done | `SplitContainer.resolveZone:L206` `.resplit(target:edge:)` |
| Dock zone (container outer gutter) | done | `SplitContainer.resolveZone:L192` `.dock(edge:)` |
| Drag overlay (ghost chip + zone preview) | done | `PaneMoveOverlay` — swap wash, resplit slab+seam, dock rail, source dashed outline |
| **Pane focus + cycle** | | |
| Click to focus pane | done | `PaneContainer:L159` `.onTapGesture { store.focusPaneTree(paneID) }` |
| Directional focus (⌥⌘←↑↓→) | done | `moveFocusTreeUsingReportedLayout(.left/.right/.up/.down)` in routing:L90–93 |
| Sequential pane cycle | missing | No `cyclePaneFocus` / `cyclePane` action exists in `WorkspaceAction` or routing |
| Focus pane via sidebar row click | done | `NavigatorColumn.select(_:):L115` → `store.focusPaneTree` |
| **In-pane chooser** | | |
| In-pane chooser (Terminal / Remote) | done | `InPaneChooserView` — focused `.chooser` pane with keyboard mnemonics (t/r) |
| Chooser focus claim (prevent typing into old terminal) | done | `InPaneChooserView:L57–60` `@FocusState` + `onAppear` deferred claim |
| **Pane badges (notifications / agent status)** | | |
| Agent status in inspector Session section | done | `InspectorColumn:L150–157` — agent SF Symbol + tint from `StatusPresentation` |
| Agent status dot in titlebar (iOS toolbar) | done | `WorkspaceRootView:L70–75` iOS toolbar item |
| Agent status dot in sidebar tab row | missing | `RailRow.status` exists but `OttyTabRow` never renders it |
| Unread / attention dot on tab | missing | No unread-count or attention marker on sidebar rows |
| macOS Dock badge | missing | No `NSApp.dockTile` or `UNNotificationCategory` badge path |
| **Details panel (inspector)** | | |
| Inspector 3-tab segmented header (Info / Git / Files) | done | `InspectorColumn:L23–44`, `tabButton(_:):L87` |
| Info tab: connection status + host + ping | done | `InspectorColumn.sessionSection:L122–157` |
| Info tab: active agent indicator | done | `InspectorColumn:L150–156` |
| Info tab: working directory | done | `InspectorColumn:L144–148` |
| Info tab: command history (BlockHistoryView) | done | `InspectorColumn.commandsSection:L165` |
| Git tab | partial | Renders `emptyState(…)` — no live git data wired |
| Files tab | partial | Renders `emptyState(…)` — no live file tree wired |
| **Status / chrome indicators** | | |
| Connection status pill (dot + host + label + ping) | done | `ConnectionStatusPill.swift` — live `@Observable` on `AppConnection.status` |
| Retry on pill tap (give-up state) | done | `ConnectionStatusPill.tap():L58–63` |
| Ping display in pill | done | `ConnectionStatusPill:L39–43` |
| Bottom status bar | missing | No footer status bar component exists in the UI module |
| **Command palette / overlays** | | |
| OverlayCoordinator (palette / settings / toasts / cheat-sheet) | partial | `OverlayCoordinator.swift` fully implemented; **not mounted** in `WorkspaceRootView` (only referenced in `Settings` comment: `AislopdeskClientApp:L289`) |
| ⌘K command palette | partial | `PaletteModel`, `PaletteDataSource`, `SearchMixer` all implemented; palette view not wired into the live scene root (no `overlayCoordinator(_:)` call in `WorkspaceRootView`) |
| Keyboard cheat sheet (⌘/) | partial | `cheatSheetVisible` in coordinator — same wiring gap |
| Toast notifications | partial | `OverlayCoordinator.pushToast` / `Toast.swift` — same wiring gap |
| Context-menu model (pane ⋮) | done | `ContextMenuModel.paneItems(…)` — built; not yet surfaced as a view (no context menu overlay in the current shell) |
| **Window-level extras** | | |
| Pin window / always-on-top | missing | No `NSWindow.level` / `floating` window level anywhere |
| Picture-in-Picture | na-remote | PiP is not applicable; the remote-GUI surface is a UDP video stream in a pane, not a PiP window |
| **Close guard / reopen** | | |
| Close-confirm guard (busy shell) | done | `requestClosePaneTree:L589` — parks `pendingClose` when `isShellBusy`; `confirmPendingClose()` + `cancelPendingClose()` |
| Reopen closed pane (⇧⌘T) | partial | `reopenClosedPane():L635` exists in store; keybinding `.reopenClosedPane` maps `⇧⌘T` in `CommandInterpreter:L254`; BUT this is the **canvas path** — `WorkspaceBindingRouting` has no `.reopenClosedPane` case for the tree path; the chord is therefore dead under `liveModel = .tree` |
| **Floating panes** | | |
| Toggle float active pane | partial | `toggleFloatActivePaneCommand()` in store; `Tab.floatingPanes` domain field; but `SplitContainer` renders **only tiled leaves** — floating panes have no renderer in the UI shell |
| Spawn floating pane (chooser) | partial | `openChooserPane(.floating)` in routing:L73 — mints the pane; same rendering gap |
| **Multi-session sessions column** | | |
| Multiple sessions listed / switchable | partial | `TreeWorkspace.sessions` is `[Session]`; `NavigatorColumn` renders only the **active session's** tabs — no cross-session list in the sidebar |

---

## Key files

- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/AislopdeskClientApp.swift` — app scene, store/connection init, lifecycle
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/WorkspaceRootView.swift` — root SwiftUI view, iOS split view
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/App/AislopdeskSplitViewController.swift` — macOS 3-column AppKit shell
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/App/WorkspaceChromeState.swift` — sidebar/inspector collapse flags
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Chrome/OttyTitlebar.swift` — hover-reveal titlebar + title menu
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Chrome/OttyTabRow.swift` — sidebar tab row + sort hamburger
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Chrome/InPaneChooserView.swift` — in-pane new-pane chooser
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Columns/NavigatorColumn.swift` — left sidebar column
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Columns/ContentColumn.swift` — centre content + titlebar overlay
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Columns/InspectorColumn.swift` — right details panel
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Pane/SplitContainer.swift` — absolute-rect pane compositor + drag drop zones
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Pane/PaneContainer.swift` — per-leaf view (routing + resize scrim + focus dim)
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Pane/PaneDivider.swift` — live-resize drag handle
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Pane/PaneMoveAffordance.swift` — grab-pill + drag overlay + drop zones
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Rail/RailRowsBuilder.swift` — pure store→rail row mapping (carries `ClaudeStatus`)
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Overlays/OverlayCoordinator.swift` — palette/settings/toast/cheat-sheet state (unmounted)
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Overlays/ContextMenuModel.swift` — pane/tab context menu item catalog (unrendered)
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/App/ConnectionStatusPill.swift` — connection status pill
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/App/StatusPresentation.swift` — connection + agent colour/label mapping
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskClientUI/Input/WorkspaceKeyDispatcher.swift` — NSEvent keybinding dispatcher
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskWorkspaceCore/Workspace/Domain/Tree/TreeWorkspace.swift` — top-level domain model
- `/Volumes/Lacie/Workspace/oss/aislopdesk/Sources/AislopdeskWorkspaceCore/Workspace/Store/WorkspaceBindingRouting.swift` — action → store-op dispatch (single source of truth)

---

## Notes (wiring gaps, dead seams, traps)

### Dead seam: OverlayCoordinator not mounted
`OverlayCoordinator` is fully implemented (palette, settings, toasts, cheat-sheet, connect-to-host,
remote picker) but `WorkspaceRootView` does not mount it (no `overlayCoordinator(_:)` call, no
`OverlayCoordinator` `@State`). The key dispatcher (`WorkspaceKeyDispatcher`) is built with nil
toggles for palette and cheat-sheet so those chords are no-ops at runtime. The settings surface
falls back to a separate macOS `Settings` scene window (`AislopdeskSettingsScene`). All of the
coordinator's overlay surfaces are behind a single mount wiring gap — adding it to `WorkspaceRootView`
would unlock palette + cheat-sheet + toasts + connect-to-host in one shot.

### Dead seam: ⇧⌘T reopen in tree mode
`reopenClosedPane()` is implemented in `WorkspaceStore` (canvas path, L635). The keybinding
`.reopenClosedPane` is declared in `CommandInterpreter:L254` and tested in `CloseUndoTests.swift`.
However, `WorkspaceBindingRouting.routeTree(_:)` has no `case .reopenClosedPane` — the action is
missing from the tree-path switch (only the canvas path, `CommandInterpreter.apply`, handles it).
Under `liveModel = .tree` (the live app), ⇧⌘T is dead.

### Partial seam: agent-status badge never rendered in sidebar
`RailRow.status: ClaudeStatus` is computed per pane by `RailRowsBuilder` and held in each row's
model, but `OttyTabRow` accepts no status parameter. The dot that should appear on the tab row
(orange/amber working, green done, red needs-permission) is never shown. The data pipeline
(`setAgentStatus` → `paneAgentStatus` → `RailRowsBuilder.rows`) is complete; only the view is missing.

### Partial seam: floating panes not rendered
`toggleFloatActivePaneCommand()` and `openChooserPane(.floating)` are wired. `Tab.floatingPanes`
holds the floating pane IDs. However, `SplitContainer` only iterates `layout.leaves`
(from `SplitTreeRenderModel.layout(for: tab, in: bounds)`) which produces **only tiled leaves** — it
never renders `tab.floatingPanes`. There is no overlay layer for draggable/resizable floating cards.

### Partial seam: multi-session UI
`TreeWorkspace.sessions` supports N sessions, and `WorkspaceStore` has `selectSession(at:)` and
`openChooserPane(.newSession)`. However, `NavigatorColumn` renders only the active session's tabs
— there is no session list or session switcher in the sidebar or elsewhere. Other sessions are
reachable only via palette or keybinding.

### Sort hamburger is presentational only
`OttySortMenuButton` renders a group/order popover with local `@State` booleans. Changing the group
or order does nothing to the store or the rendered row order. It is purely cosmetic scaffolding.

### No pane cycle action
There is no sequential "cycle focus to next/previous pane" action in `WorkspaceAction` or routing.
Directional focus (`focusLeft/Right/Up/Down`) exists; a tmux-style bare-cycle does not.

### No status bar
There is no bottom footer status bar anywhere in `AislopdeskClientUI`. The connection pill in the
titlebar / iOS toolbar serves as the only persistent status indicator.

### Pin window / PiP
Pin window (always-on-top `NSWindow.level`) is not implemented. PiP is not applicable — the
remote-GUI surface is a UDP video stream displayed as an in-pane `GuiLeafView`, not a separate
floating window.

### Connect-to-host overlay
`OverlayCoordinator.connectVisible` / `openConnect()` exist and are called from `ConnectionStatusPill`
via `onTap`, but the overlay itself is not mounted (same OverlayCoordinator gap above). The current
give-up path (Retry in the pill) is the only interactive reconnect path.
