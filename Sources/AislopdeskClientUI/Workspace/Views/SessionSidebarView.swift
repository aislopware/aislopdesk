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
        .background(AislopdeskTheme.bg)
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
    let onSelect: () -> Void
    let onRename: () -> Void

    @State private var hovered = false

    private var displayName: String {
        session.name.isEmpty ? "Session" : session.name
    }

    /// Muxy's `headerBackground`: `accentHover` (accent·0.25) when active so the active row reads clearly
    /// against the `accentSoft` (accent·0.10) icon ring; `hover` (fg·0.06) on hover, else clear.
    private var headerBackground: AnyShapeStyle {
        if isActive { return AnyShapeStyle(AislopdeskTheme.accentHover) }
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
            }

            Spacer(minLength: UIMetrics.spacing2)

            AgentStatusDot(status: agentStatus, size: UIMetrics.scaled(8))
        }
        .padding(.horizontal, UIMetrics.spacing3)
        .padding(.vertical, UIMetrics.spacing2)
        .background(headerBackground, in: RoundedRectangle(cornerRadius: UIMetrics.radiusLG, style: .continuous))
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
/// framed by a 1.5pt `accent` ring when active (Muxy's project-icon active indicator), with the rolled-up
/// completion badge overlaid top-trailing.
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
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD + UIMetrics.scaled(3), style: .continuous)
                .strokeBorder(isActive ? AislopdeskTheme.accent : .clear, lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.15), value: isActive)
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
        .background(AislopdeskTheme.bg)
    }
}
#endif
