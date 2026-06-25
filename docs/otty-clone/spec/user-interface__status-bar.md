# Status Bar

## Summary

The status bar is listed as a planned feature in the Otty user-interface navigation ("User Interface → Status Bar") but is **not yet implemented**. The docs page at https://docs.otty.sh/user-interface/status-bar contains only the single statement:

> "The status bar is planned, but not implemented yet."

No screenshots, no configuration keys, no keybindings, and no behavioral specification have been published. The config file reference (`/reference/configuration`) similarly contains no keys matching "status", "statusbar", or "status-bar". This was confirmed via both the rendered page content and a raw HTML curl.

The status bar appears in the sidebar between "Details Panel" and "Files and Links", suggesting it will occupy a persistent horizontal strip (most likely below the tab/title bar or at the bottom of the window) showing per-pane or per-window context — a standard terminal UX pattern.

## Behaviors

- **NONE SPECIFIED** — feature is unimplemented as of 2026-06-25.
- Anticipated (inferred from position in navigation and common terminal conventions):
  - Would display per-pane context: working directory, running process, git branch, or similar metadata surfaced from the Details Panel's Info tab.
  - Would provide a persistent, always-visible strip so the user does not need to open the Details Panel for quick context.
  - May mirror or summarize information from the Details Panel (Info tab: cwd, process list, listening ports).

## Keybindings

| Action | Keys |
|--------|------|
| *(none — feature not implemented)* | — |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none — feature not implemented)* | — | — |

## Visual spec

### No screenshots available

The page contains no screenshots. The only image on the page is the site-wide Otty logo (`/otty-icon.png`):

- **Icon**: a rounded-square (squircle) app icon with a medium charcoal dark-gray background (~#3a3a3a). Foreground glyphs in off-white (~#e8e6e0): a `>` prompt chevron (left-center), an underscore cursor (`_`, baseline of the chevron), a `*` glob/asterisk (upper-right, slightly smaller), and a `-` dash (lower-right). The overall composition reads as a playful terminal-face emoji. Corner radius is generous; the squircle sits on a neutral light-gray background (`#f0efed`). No drop shadow visible. Typography is monospace-inspired but rendered as paths. Size appears ~512×512 px logical.

## Screenshots

- `otty-icon.png` (site logo only — no status-bar screenshots exist)

## Aislopdesk mapping notes

### What cannot map 1:1

1. **Working directory (cwd)** — In aislopdesk the terminal runs on the *remote macOS host*, not the client. The cwd would need to be forwarded over the wire (OSC 7 is already supported in the ghostty terminal and the shell-integration path; this should be the source of truth). The client can display the host-reported cwd, but it cannot resolve it locally (e.g. for Finder "reveal").

2. **Running process list** — Process introspection (what's running in the PTY) is host-side. The client would need the host to emit process metadata (process name, PID) over the control channel or a side-band. Currently `AislopdeskWorkspaceCore` has Claude auto-detect and OSC-133 shell integration; a status bar could consume those events.

3. **Listening ports** — Port enumeration is host-side only; it cannot be inferred client-side without an explicit host probe and wire protocol extension.

4. **Git status** — Repository state lives on the host filesystem. Showing it in a client status bar requires either the host to push git metadata (branch, dirty flag, ahead/behind count) over the control channel, or the client to run `git` remotely — neither is currently in the aislopdesk wire protocol.

5. **macOS system integrations** — Any macOS-native status-bar affordances (menu-bar extras, NSStatusItem) are irrelevant on iOS; the iOS client would need an equivalent in-window strip.

### What maps cleanly

- **Shell-integration marks (OSC 133)** — Already supported; a status bar could show the last command exit code and command text from the OSC-133 sequence stream without any new wire protocol work.
- **Session/pane identity** — PaneID, tab label, and connection state are all client-side and available directly from `WorkspaceStore`.
- **Theme integration** — The status bar strip would follow the existing `OttyDesign` / Monokai Pro token system (flat, zero-radius, bg matches pane background).

### Implementation recommendation

When otty publishes a status-bar spec, implement it as a thin SwiftUI `HStack` strip pinned to the bottom of each `TerminalSurface` pane (or the window bottom). Consume:
- OSC 7 (cwd) → displayed path, truncated to the last 2 components.
- OSC 133 (shell integration) → last exit code badge (green/red).
- `WorkspaceStore` → pane kind, session state, active connection host.
- A future host-side metadata push for git branch / process name.

Keep the strip height ≤ 20 pt so it does not intrude on terminal real estate.
