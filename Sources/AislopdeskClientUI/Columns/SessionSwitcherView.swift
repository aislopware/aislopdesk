// SessionSwitcherView — the multi-session switcher mounted atop the sidebar navigator (E19 WI-5 / A32).
//
// aislopdesk adds a Session layer above otty's single-window Window→Tab→Pane model, so the faithful otty
// affordance is a compact session selector at the TOP of the TABS sidebar (above the "TABS" header). It lists
// ``WorkspaceStore/tree``'s sessions (derived by the pure ``SessionRowModel/rows(for:)`` so the row set is
// headless-tested), marks the active one with the same otty WHITE-CARD highlight as ``OttyTabRow``, and
// routes every action straight through the EXISTING store ops — `selectSession` (tap), `renameSession`
// (inline `TextField`), `closeSession` (close / context menu), and `newSessionDefault` (the "+ New Session"
// add affordance, which names via ``WorkspaceStore/defaultSessionName``). It invents NO new ops and does NOT
// touch the active-session tab list below it (``NavigatorColumn`` still renders the active session's tabs).
//
// The ENTIRE switcher shows only when there is more than one session (`rows.count > 1`) — with a single
// session it renders NOTHING (no "SESSIONS" header, no lone row, no add affordance, no divider) so the
// default workspace matches otty's `workspace-tabs.png` (just the warm panel → "TABS" header → tab rows).
// "New Session" stays reachable via the ⌃⌘N command / palette; the switcher reveals itself once a 2nd
// session exists. macOS renders flat otty rows; iOS renders a leading `Section` so it composes into the
// navigator's system `List` (iPad navigation intact).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct SessionSwitcherView: View {
    let store: WorkspaceStore

    /// The session currently being renamed inline (its row swaps the name label for a `TextField`), or `nil`.
    @State private var renamingID: SessionID?
    /// The in-flight rename draft text — bound by the renaming row's `TextField`, committed on submit / blur.
    @State private var draft = ""

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - Rename lifecycle (shared)

    /// Enter inline-rename for `row` — seed the draft with the current name, then swap its label for a field.
    private func beginRename(_ row: SessionRowModel) {
        draft = row.name
        renamingID = row.id
    }

    /// Commit the inline rename through the EXISTING ``WorkspaceStore/renameSession(_:to:)`` op (an empty /
    /// whitespace-only draft is treated as a cancel — never rename to blank), then leave edit mode.
    private func commitRename(_ id: SessionID) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.renameSession(id, to: trimmed) }
        renamingID = nil
        draft = ""
    }

    /// Abandon the inline rename (Escape / blank) — leave the name untouched.
    private func cancelRename() {
        renamingID = nil
        draft = ""
    }

    #if os(macOS)
    /// macOS: a flat session list — otty white-card active rows + a "+ New Session" add row — painted on the
    /// warm sidebar above the "TABS" header (the host split item is a plain item, so no native vibrancy).
    private var macBody: some View {
        let rows = SessionRowModel.rows(for: store.tree)
        // The DEFAULT single-session workspace shows ZERO session chrome — no "SESSIONS" header, no session
        // rows, no "+ New Session" add row, no divider — so the sidebar matches otty's `workspace-tabs.png`
        // (warm panel → "TABS" header → tab rows). The whole switcher block is gated on `rows.count > 1`; it
        // reveals itself once a 2nd session exists. "New Session" stays reachable via ⌃⌘N / the palette while
        // hidden. (Just gating the header — as before — left ~3 spurious elements in the most common state.)
        return VStack(alignment: .leading, spacing: 0) {
            if rows.count > 1 {
                Text("SESSIONS")
                    .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Otty.State.header)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        SessionRow(
                            model: row,
                            isRenaming: renamingID == row.id,
                            draft: $draft,
                            onSelect: { store.selectSession(row.id) },
                            onBeginRename: { beginRename(row) },
                            onCommit: { commitRename(row.id) },
                            onCancel: cancelRename,
                            onClose: { store.closeSession(row.id) },
                        )
                    }
                }
                .padding(.horizontal, 8)
                SessionAddRow { store.newSessionDefault() }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                Rectangle()
                    .fill(Otty.Line.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, 2)
    }
    #else
    /// iOS: a leading `Section` so the switcher composes into ``NavigatorColumn``'s system `List` (the column
    /// root must stay a `List` for NavigationSplitView's push). Tap selects; swipe → Rename / Close; the
    /// trailing "New Session" button adds. Renders the inline rename `TextField` in place when active.
    private var iosBody: some View {
        let rows = SessionRowModel.rows(for: store.tree)
        // Gate the ENTIRE leading Section on `rows.count > 1` (matching macOS): a single-session iPad workspace
        // shows zero session chrome (no header, no row, no "New Session"). "New Session" stays reachable via the
        // palette while hidden; the section reveals itself once a 2nd session exists.
        return Group {
            if rows.count > 1 {
                Section {
                    ForEach(rows) { row in
                        iosRow(row)
                    }
                    Button { store.newSessionDefault() } label: {
                        Label("New Session", systemSymbol: .plus)
                            .foregroundStyle(Otty.State.accent)
                    }
                } header: {
                    Text("Sessions")
                }
            }
        }
    }

    @ViewBuilder
    private func iosRow(_ row: SessionRowModel) -> some View {
        if renamingID == row.id {
            TextField("Session name", text: $draft)
                .submitLabel(.done)
                .onSubmit { commitRename(row.id) }
        } else {
            Button { store.selectSession(row.id) } label: {
                HStack(spacing: 8) {
                    Label {
                        Text(row.name)
                            .foregroundStyle(Otty.Text.primary)
                            .lineLimit(1)
                    } icon: {
                        Image(systemSymbol: .rectangleStack)
                    }
                    Spacer(minLength: 6)
                    if row.active {
                        Image(systemSymbol: .checkmark)
                            .font(.system(size: Otty.Typeface.small, weight: .semibold))
                            .foregroundStyle(Otty.State.accent)
                            .accessibilityLabel("Active session")
                    }
                    if row.tabCount > 0 {
                        Text("\(row.tabCount)")
                            .font(.system(size: Otty.Typeface.small, design: .monospaced))
                            .foregroundStyle(Otty.Text.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { store.closeSession(row.id) } label: {
                    Label("Close", systemSymbol: .xmark)
                }
                Button { beginRename(row) } label: {
                    Label("Rename", systemSymbol: .pencil)
                }
                .tint(Otty.State.accent)
            }
        }
    }
    #endif
}

#if os(macOS)
/// One macOS session row — otty's silhouette: the name on the warm sidebar, ACTIVE = the white card (radius-7
/// fill + 1px border + faint shadow) exactly like ``OttyTabRow``, hover = a flat plate with a reveal close
/// `×`, trailing tab-count, and a right-click context menu (Rename / Close). While renaming the name swaps for
/// a focused `TextField` that commits on submit / blur through the parent's existing-op closures.
private struct SessionRow: View {
    let model: SessionRowModel
    let isRenaming: Bool
    @Binding var draft: String
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("Session name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(Otty.Text.primary)
                    .tint(Otty.State.accent)
                    .focused($focused)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, nowFocused in if !nowFocused { onCommit() } }
            } else {
                Text(model.name)
                    .font(.system(size: Otty.Typeface.body, weight: model.active ? .medium : .regular))
                    .foregroundStyle(Otty.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.tabCount > 0 {
                    Text("\(model.tabCount)")
                        .font(.system(size: Otty.Typeface.small, design: .monospaced))
                        .foregroundStyle(Otty.Text.secondary)
                        .opacity(hovering ? 0 : 1)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !isRenaming {
                closeButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(rowBackground, in: .rect(cornerRadius: Otty.Metric.radiusTab))
        .overlay {
            if model.active {
                RoundedRectangle(cornerRadius: Otty.Metric.radiusTab)
                    .strokeBorder(Otty.Line.card, lineWidth: 1)
            }
        }
        .shadow(color: model.active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        .onTapGesture { if !isRenaming { onSelect() } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { onBeginRename() }
            Button("Close", role: .destructive) { onClose() }
        }
        .animation(Otty.Anim.smallFade, value: hovering)
        .animation(Otty.Anim.smallFade, value: model.active)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.icon)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close session")
        .padding(.trailing, 2)
    }

    private var rowBackground: Color {
        if model.active { Otty.Surface.selectedCard }
        else if hovering { Otty.State.hover }
        else { .clear }
    }
}

/// The flat "+ New Session" add affordance — an otty hover-plate row with a leading plus glyph. Routes to
/// ``WorkspaceStore/newSessionDefault()`` (which names the session via ``WorkspaceStore/defaultSessionName``).
private struct SessionAddRow: View {
    let action: () -> Void
    @State private var hovering = false

    init(_ action: @escaping () -> Void) { self.action = action }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemSymbol: .plus)
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.icon)
                Text("New Session")
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(hovering ? Otty.State.hover : .clear, in: .rect(cornerRadius: Otty.Metric.radiusTab))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
    }
}
#endif
#endif
