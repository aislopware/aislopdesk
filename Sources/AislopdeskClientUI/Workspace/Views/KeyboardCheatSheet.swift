#if canImport(SwiftUI)
import SwiftUI

// MARK: - KeyboardCheatSheet (the ⌘/ shortcut reference, generated from the bindings table)

/// The data behind the ⌘/ keyboard-shortcut overlay. Every workspace row's GLYPH is resolved from
/// ``CommandInterpreter/defaultBindings`` via ``CommandPaletteView/shortcutHint(for:)`` — the SAME
/// single source of truth the menu bar + palette use — so a rebinding can never drift the cheat sheet.
/// A small curated "Terminal" section covers the chords the focused libghostty surface handles itself
/// (⌘C/V/A, font sizing) which live outside the workspace table, plus the ⌘K palette + ⌘/ itself.
///
/// `@MainActor` because `shortcutHint` reads the main-actor `defaultBindings`. Pure (no view state) —
/// the overlay just renders ``sections()``.
@MainActor
enum KeyboardCheatSheet {
    struct Item: Identifiable, Equatable {
        let glyph: String
        let label: String
        var id: String { label }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    /// Every WORKSPACE command the sheet documents, grouped, in display order. Used both to build the
    /// sections and (via ``workspaceCommands``) to drift-guard against ``defaultBindings``.
    private static let groups: [(title: String, commands: [(WorkspaceCommand, String)])] = [
        ("Panes", [
            (.newPaneDefault, "New pane"),
            (.newPane(.terminal), "New terminal"),
            (.newPane(.remoteGUI), "New remote window"),
            (.duplicatePane, "Duplicate pane"),
            (.closePane, "Close pane"),
            (.reopenClosedPane, "Reopen closed pane"),
            (.renamePane, "Rename pane"),
            (.reconnectPane, "Reconnect pane"),
        ]),
        ("Groups & selection", [
            (.newGroup, "New group / group selection"),
            (.groupSelection, "Group selected panes"),
            (.selectAllPanes, "Select all panes"),
        ]),
        ("Focus", [
            (.focus(.left), "Focus left"),
            (.focus(.right), "Focus right"),
            (.focus(.up), "Focus up"),
            (.focus(.down), "Focus down"),
            (.cycleFocus(forward: true), "Focus next pane"),
            (.cycleFocus(forward: false), "Focus previous pane"),
            (.switchRecentPane(forward: false), "Go to previous pane (recent)"),
            (.switchRecentPane(forward: true), "Forward through recent panes"),
            (.cycleFocusInGroup(forward: true), "Cycle next in group"),
            (.cycleFocusInGroup(forward: false), "Cycle previous in group"),
        ]),
        ("Arrange & view", [
            (.tidy, "Tidy layout"),
            (.centerFocusedPane, "Center on pane"),
            (.centerAll, "Center on all"),
            (.toggleZoom, "Maximize pane"),
            (.toggleOverview, "Overview"),
            (.toggleBroadcast, "Broadcast input"),
            (.saveLayout, "Save current layout"),
            (.manageSnippets, "Manage snippets"),
            (.runLastSnippet, "Run last snippet"),
        ]),
    ]

    /// Flat list of every workspace command the sheet covers — the drift guard's reference set.
    static var workspaceCommands: [WorkspaceCommand] { groups.flatMap { $0.commands.map(\.0) } }

    /// The rendered sections for the overlay. A workspace row is dropped if its command has no default
    /// chord (so the sheet never shows a blank glyph); bookmark slots are collapsed to two representative
    /// rows; the curated terminal/palette extras are appended.
    static func sections() -> [Section] {
        var out: [Section] = groups.compactMap { group in
            let items = group.commands.compactMap { cmd, label -> Item? in
                guard let glyph = CommandPaletteView.shortcutHint(for: cmd) else { return nil }
                return Item(glyph: glyph, label: label)
            }
            return items.isEmpty ? nil : Section(title: group.title, items: items)
        }
        // Viewport bookmarks: ⌘1–9 recall / ⇧⌘1–9 save — collapsed (the 18 per-slot bindings would
        // bury the sheet). Shown only if slot 1 is actually bound (it always is in the defaults).
        if CommandPaletteView.shortcutHint(for: .recallBookmark(1)) != nil {
            out.append(Section(title: "Viewport bookmarks", items: [
                Item(glyph: "⌘1–9", label: "Recall bookmark"),
                Item(glyph: "⇧⌘1–9", label: "Save bookmark"),
            ]))
        }
        // Chords handled OUTSIDE the workspace table: the palette (scene-level), and the ones the focused
        // terminal surface claims itself (the §5 conflict rule). Curated, not generated.
        out.append(Section(title: "Search & terminal", items: [
            Item(glyph: "⌘K", label: "Command palette"),
            Item(glyph: "⌘/", label: "This shortcut list"),
            Item(glyph: "⌘C / ⌘V", label: "Copy / paste (focused terminal)"),
            Item(glyph: "⌘A", label: "Select all text (focused terminal)"),
            Item(glyph: "⌘= / ⌘− / ⌘0", label: "Font size (focused terminal)"),
        ]))
        return out
    }

    // MARK: - Tree shell sections (W6 — generated from the SINGLE WorkspaceBindingRegistry source)

    /// The cheat-sheet sections for the LIVE IDE shell (``WorkspaceStore/LiveModel/tree``), generated
    /// entirely from ``WorkspaceBindingRegistry`` — the SAME single source of truth the menu bar and the ⌘K
    /// palette consume — so a rebinding can never drift the sheet. Grouped by the registry's display
    /// categories (Panes / Tabs / Sessions / Focus / View); the nine ⌘-digit select-tab chords are
    /// collapsed into one representative "⌘1…⌘9" row, and the terminal extras are appended (the §5 chords
    /// the focused libghostty surface claims itself, outside the workspace table).
    static func treeSections() -> [Section] {
        var out: [Section] = WorkspaceBindingRegistry.groupedForDisplay.compactMap { group -> Section? in
            var items = group.bindings.compactMap { binding -> Item? in
                guard let chord = binding.chord else { return nil }
                return Item(glyph: WorkspaceBindingRegistry.glyph(chord), label: binding.title)
            }
            // Append the collapsed "select tab N" row to the Tabs group (the nine ⌘-digit chords).
            if group.category == .tabs {
                items.append(Item(glyph: "⌘1…⌘9", label: "Select Tab 1–9"))
            }
            guard !items.isEmpty else { return nil }
            return Section(title: group.category.rawValue, items: items)
        }
        // The terminal chords the focused surface handles itself (curated, not generated — they live
        // outside the workspace table, exactly as the canvas sheet documents).
        out.append(Section(title: "Terminal", items: [
            Item(glyph: "⌘C / ⌘V", label: "Copy / paste (focused terminal)"),
            Item(glyph: "⌘A", label: "Select all text (focused terminal)"),
            Item(glyph: "⌘= / ⌘− / ⌘0", label: "Font size (focused terminal)"),
        ]))
        return out
    }
}

// MARK: - KeyboardCheatSheetView (the ⌘/ overlay)

/// A Spotlight-style floating card listing every shortcut, grouped, dismissed by ⎋ / backdrop tap / ⌘/.
/// Mirrors ``CommandPaletteView``'s overlay shape (dim backdrop, top-third card) but is read-only.
struct KeyboardCheatSheetView: View {
    @Binding var isPresented: Bool
    /// Which command model the live store drives (W6): ``WorkspaceStore/LiveModel/tree`` renders the
    /// registry-generated tree shortcuts; ``WorkspaceStore/LiveModel/canvas`` the retained canvas sheet.
    /// Defaults `.tree` (the live app) so a caller that omits it gets the IDE-shell sheet.
    var liveModel: WorkspaceStore.LiveModel = .tree

    /// The sections to render, picked by the live model — both come from the one drift-guarded source for
    /// their model (the registry for `.tree`, `defaultBindings` for `.canvas`).
    private var sections: [KeyboardCheatSheet.Section] {
        switch liveModel {
        case .tree: KeyboardCheatSheet.treeSections()
        case .canvas: KeyboardCheatSheet.sections()
        }
    }

    var body: some View {
        if isPresented {
            ZStack {
                Rectangle()
                    .fill(DSColor.scrim)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                card
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(DSSpace.s5)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpace.s6) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: DSSpace.s3) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DSColor.textTertiary)
                            ForEach(section.items) { item in
                                HStack(spacing: DSSpace.s5) {
                                    Text(item.label)
                                        .font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.glyph)
                                        .font(.system(.callout, design: .rounded).monospacedDigit())
                                        .foregroundStyle(DSColor.textTertiary)
                                        .padding(.horizontal, DSSpace.s3).padding(.vertical, DSSpace.s1)
                                        .background(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                            .fill(DSColor.chrome))
                                }
                            }
                        }
                    }
                }
                .padding(DSSpace.s6)
            }
        }
        .frame(maxWidth: 520, maxHeight: 540)
        // L4 overlay: glass (the helper supplies the hairline border, so the manual strokeBorder is gone)
        // + inner top-edge highlight + the ONE tokenized overlay shadow — unified with the palette / peek
        // / floating layer. A transient overlay (NOT a hard modal), so shadowOverlay, not shadowModal.
        .glassedSurface(corner: DSRadius.overlay)
        .overlay(alignment: .top) { DSElevation.innerTopHighlight() }
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.overlay, style: .continuous))
        .dsShadow(DSElevation.shadowOverlay)
        .padding(.horizontal, DSSpace.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DSScale.scaled(70))
        .onEscapeKey { isPresented = false }
    }
}
#endif
