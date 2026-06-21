// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - SessionSidebarView (the sessions sidebar — Muxy-styled)

/// The coding-IDE sessions sidebar, ported from Muxy's `Sidebar` (not a stock `List`/`.sidebar`): a solid
/// `bg` column of custom rows grouped by host. Each row is the wide "project" look — a rounded session icon
/// (the session's initial in a `surface` square, a 1.5pt `accent` ring when active) carrying a top-trailing
/// rolled-up completion badge, the session name, and a trailing rolled-up agent-status dot — laid on a soft
/// `accentSoft` (active) / `hover` (hovered) row plate. The footer is an `IconButton` "New Session".
/// Drives the store's tree ops (`selectSession` / `newSession` / `closeSession` / `renameSession`).
struct SessionSidebarView: View {
    @Bindable var store: WorkspaceStore

    /// The session whose inline rename field is open, or `nil`.
    @State private var renamingSession: SessionID?
    @State private var renameText: String = ""

    private var activeSessionID: SessionID? {
        store.tree.activeSessionID ?? store.tree.sessions.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionList

            Rectangle().fill(AislopdeskTheme.border).frame(height: 1)
            SidebarFooter(onNewSession: newSession)
        }
        // Elevation: the sidebar is the RAISED level so it reads a step above the `bg` pane cards.
        .background(AislopdeskTheme.bgRaised)
    }

    // MARK: List (Muxy's `scrollableProjects`: a `ScrollView` of a `LazyVStack` grouped by host)

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                ForEach(groupedByHost, id: \.host) { group in
                    sectionHeader(group.host)
                    ForEach(group.sessions, id: \.id) { session in
                        sessionSlot(session)
                    }
                }
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.top, UIMetrics.spacing2)
            .padding(.bottom, UIMetrics.spacing2)
        }
        .onChange(of: activeSessionID) { _, _ in renamingSession = nil }
    }

    // MARK: Section header (a small uppercase host label — not a `List` `Section`)

    private func sectionHeader(_ host: String) -> some View {
        Text(host.uppercased())
            .font(.system(size: UIMetrics.fontCaption, weight: .semibold))
            // Structural ALL-CAPS section labels recede further than body text — use fgFaint (fg·0.20)
            // so they read as silent dividers rather than competing with session names.
            .foregroundStyle(AislopdeskTheme.fgFaint)
            .lineLimit(1)
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.top, UIMetrics.spacing3)
            .padding(.bottom, UIMetrics.spacing1)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Row (or its inline rename field)

    @ViewBuilder
    private func sessionSlot(_ session: Session) -> some View {
        if renamingSession == session.id {
            HStack(spacing: UIMetrics.spacing4) {
                SessionIcon(
                    session: session,
                    isActive: session.id == activeSessionID,
                    completion: store.rollupPendingCompletion(forSession: session.id),
                )
                TextField("Session", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIMetrics.fontEmphasis))
                    .foregroundStyle(AislopdeskTheme.fg)
                    .onSubmit { commitRename(session.id) }
                    .onEscapeKey { renamingSession = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)
            .background(
                AislopdeskTheme.surface,
                in: RoundedRectangle(cornerRadius: UIMetrics.radiusLG, style: .continuous),
            )
        } else {
            SessionRow(
                session: session,
                isActive: session.id == activeSessionID,
                agentStatus: store.rollupStatus(forSession: session.id),
                completion: store.rollupPendingCompletion(forSession: session.id),
                summary: store.activitySummary(forSession: session.id),
                liveness: store.sessionLiveness(forSession: session.id),
                onSelect: { store.selectSession(session.id) },
                onRename: { beginRename(session) },
            )
            .contextMenu {
                Button("Rename…") { beginRename(session) }
                Button("Close Session", role: .destructive) { store.closeSession(session.id) }
            }
        }
    }

    // MARK: New session (the single source both the keyboard path and the footer use)

    private func newSession() {
        store.newSession(name: store.defaultSessionName, kind: SettingsKey.defaultPaneKind)
    }

    // MARK: Grouping (by host, first-appearance order within host)

    private struct HostGroup { let host: String
        let sessions: [Session]
    }

    /// Sessions grouped by their connection host (no-connection → "Local"), in first-appearance order.
    private var groupedByHost: [HostGroup] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]
        for session in store.tree.sessions {
            let host = session.connection?.host ?? "Local"
            if buckets[host] == nil { order.append(host) }
            buckets[host, default: []].append(session)
        }
        return order.map { HostGroup(host: $0, sessions: buckets[$0] ?? []) }
    }

    // MARK: Rename

    private func beginRename(_ session: Session) {
        renameText = session.name
        renamingSession = session.id
    }

    private func commitRename(_ id: SessionID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameSession(id, to: trimmed.isEmpty ? "Session" : trimmed)
        renamingSession = nil
    }
}

// MARK: - SessionRow (Muxy's `ExpandedProjectRow` projectHeader, mapped to a session)

/// A single sidebar session row: the session icon + name + a trailing agent-status dot, on a soft
/// `accentSoft` plate when active and a `hover` plate on hover (Muxy's `headerBackground`). Its own
/// `hovered` state keeps the wash local.
private struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let agentStatus: ClaudeStatus
    let completion: PaneCompletionBadge?
    /// P3 piece 5: the cheap one-line activity summary (the host blocking line / state label), or `nil`.
    let summary: String?
    /// P3 piece 5: the session's liveness (alive vs exited-resumable) for the leading glyph.
    let liveness: WorkspaceStore.SessionLiveness
    let onSelect: () -> Void
    let onRename: () -> Void

    @State private var hovered = false

    private var displayName: String {
        session.name.isEmpty ? "Session" : session.name
    }

    /// The liveness glyph, immediately before the agent dot in the trailing cluster. Both cases share ONE
    /// font size (`fontXS`) so the baseline/width is stable as a session flips alive↔detached. Alive uses a
    /// `bolt.fill` (live link) rather than a second filled circle so it never reads as a redundant double
    /// green dot beside the adjacent ``AgentStatusDot``; detached uses a muted `moon.zzz`.
    @ViewBuilder
    private var livenessGlyph: some View {
        switch liveness {
        case .alive:
            Image(systemName: "bolt.fill")
                .font(.system(size: UIMetrics.fontXS))
                .foregroundStyle(AislopdeskTheme.statusGreen)
                .help("Connected")
                .accessibilityLabel("connected")
        case .exitedResumable:
            Image(systemName: "moon.zzz")
                .font(.system(size: UIMetrics.fontXS))
                .foregroundStyle(AislopdeskTheme.fgMuted)
                .help("Detached — reattach on select")
                .accessibilityLabel("detached, resumable")
        }
    }

    /// The active-row plate. With the 2pt leading accent BAR now carrying the primary "selected" signal,
    /// the fill softens from `accentHover` (accent·0.25) to `accentSoft` (accent·0.10) so the row reads
    /// as a quiet selection — bar + subtle wash — rather than a heavy accent tint. `hover` (fg·0.06) on
    /// hover, else clear.
    private var headerBackground: AnyShapeStyle {
        if isActive { return AnyShapeStyle(AislopdeskTheme.accentSoft) }
        if hovered { return AnyShapeStyle(AislopdeskTheme.hover) }
        return AnyShapeStyle(Color.clear)
    }

    var body: some View {
        HStack(spacing: UIMetrics.spacing4) {
            SessionIcon(session: session, isActive: isActive, completion: completion)

            VStack(alignment: .leading, spacing: UIMetrics.scaled(1)) {
                Text(displayName)
                    .font(.system(size: UIMetrics.fontEmphasis, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // P3 piece 5: a cheap one-line activity summary under the name — the host blocking line /
                // last assistant message, else the agent state label. Hidden when no agent is present.
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: UIMetrics.fontCaption))
                        .foregroundStyle(AislopdeskTheme.fgDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: UIMetrics.spacing2)

            livenessGlyph
            AgentStatusDot(status: agentStatus, size: UIMetrics.scaled(8))
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.spacing2)
        .background(headerBackground, in: RoundedRectangle(cornerRadius: UIMetrics.radiusLG, style: .continuous))
        // Selection = fill + accent EDGE: a 2pt leading accent bar carries the primary "this is selected"
        // signal alongside the soft plate, the Linear/Raycast idiom. Shown only on the active row.
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: UIMetrics.scaled(1), style: .continuous)
                    .fill(AislopdeskTheme.accent)
                    .frame(width: UIMetrics.scaled(2))
                    .padding(.vertical, UIMetrics.spacing2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: UIMetrics.radiusLG, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onRename() })
        .onTapGesture { onSelect() }
        #if os(macOS)
            .onHover { hovered = $0 }
        #endif
    }
}

// MARK: - SessionIcon (Muxy's `projectIcon`: the rounded badge + active ring + top-trailing completion)

/// The session's rounded icon: a continuous `surface`-filled rounded square holding the session's initial,
/// with the rolled-up completion badge overlaid top-trailing. The active row's selection signal is the 2pt
/// leading accent bar + soft plate on `SessionRow` (the single accent cue); to avoid stacking three accent
/// strokes on one row the icon keeps only a quiet neutral `border` frame (no accent ring), bumping just its
/// foreground/letter weight when active.
private struct SessionIcon: View {
    let session: Session
    let isActive: Bool
    let completion: PaneCompletionBadge?

    private var initial: String {
        let trimmed = session.name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first.map(Character.init) ?? "S").uppercased()
    }

    private var letterForeground: Color {
        isActive ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD, style: .continuous)
                .fill(AislopdeskTheme.surface)
            Text(initial)
                .font(.system(size: UIMetrics.fontEmphasis, weight: .bold))
                .foregroundStyle(letterForeground)
        }
        .frame(width: UIMetrics.iconXXL, height: UIMetrics.iconXXL)
        .overlay {
            // Neutral hairline only — the row's leading accent bar (SessionRow) is the single "selected"
            // accent cue, so the icon never adds a second accent stroke.
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD + UIMetrics.scaled(3), style: .continuous)
                .strokeBorder(AislopdeskTheme.border, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            CompletionBadge(badge: completion, size: UIMetrics.scaled(8))
                .offset(x: UIMetrics.spacing1, y: -UIMetrics.spacing1)
        }
    }
}

// MARK: - SidebarFooter (Muxy's `SidebarFooter`: an `IconButton` row pinned at the bottom)

/// The sidebar's bottom action bar — a row of `IconButton`s on the `bg` column. We keep just the
/// new-session action (Muxy's footer also carries notifications/extensions/theme, which we don't surface).
private struct SidebarFooter: View {
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: UIMetrics.spacing2) {
            IconButton(symbol: "plus", accessibilityLabel: "New Session") { onNewSession() }
                .help("New Session")
            Text("New Session")
                .font(.system(size: UIMetrics.fontEmphasis))
                .foregroundStyle(AislopdeskTheme.fgMuted)
            Spacer()
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.spacing2)
        // Match the sidebar's raised elevation so the footer doesn't read as a different surface.
        .background(AislopdeskTheme.bgRaised)
    }
}
#endif
