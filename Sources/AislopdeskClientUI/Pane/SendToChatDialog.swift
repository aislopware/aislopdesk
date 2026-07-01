// SendToChatDialog — the E13 WI-5 / ES-E13-5 "Send to Chat" modal sheet (bound to ⌘⌃↩). A centered card over a
// dimmed workspace (mounted by the app inside the shared `Scrim` + centered ZStack, exactly like
// `CloseConfirmationPanel`) that matches `send-to-chat-frame-03/04.png`: a title row (the source location),
// a read-only quoted preview box, a "Send to:" Claude-only session picker, a focused "Comment:" field, and
// the Copy Message / Cancel / Send buttons.
//
// PURE plumbing over the headless ``SendToChatModel``: it composes the delivered message via
// `SendToChatModel.compose(...)` and hands the chosen target + the composed STRING back through `onSend`
// (the owner resolves that pane's `ComposerModel.send` with `SendToChatModel.payload(for:)` — the single
// ordered-OUT VERBATIM sink — and auto-focuses the pane); Copy Message → `onCopy` (the owner writes the
// pasteboard); Cancel → `onCancel`. Claude-only (BINDING directive 1) — the picker never surfaces codex.
//
// `Slate.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`). Shared
// `AislopdeskClientUI` view — compiles for iOS (only the AppKit Esc handler is `#if os(macOS)`-gated, with
// an `onKeyPress(.escape)` iOS fallback); no dead iOS affordance.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct SendToChatDialog: View {
    /// The captured source — the dialog title (source location), the verbatim quoted preview, and an
    /// optional file-reference line (`nil` for a terminal pane).
    let context: SendToChatContext
    /// The live Claude-only agent sessions the context can be routed to (`composerAgentActive` panes). Empty
    /// ⇒ the picker offers only "New session".
    let sessions: [SendToChatSession]
    /// Send: the chosen target pane (`nil` ⇒ "New session") + the composed VERBATIM message. The owner
    /// resolves the target's `ComposerModel.send` with `SendToChatModel.payload(for:)` and focuses the pane.
    var onSend: (_ target: PaneID?, _ message: String) -> Void
    /// Copy Message: the composed message, copied to the pasteboard WITHOUT sending (the owner writes it —
    /// keeps this view AppKit-free so it compiles on iOS).
    var onCopy: (_ message: String) -> Void
    /// Cancel: dismiss without sending.
    var onCancel: () -> Void
    /// Persist the chosen target as the last-used default (the owner writes the preferences key). `nil` ⇒
    /// not persisted (a preview / test).
    var onSelectionChange: ((PaneID?) -> Void)?

    /// The selected target pane id, or `nil` for "New session". Seeded from the last-used default.
    @State private var selectedSessionID: PaneID?
    /// The user's comment accompanying the context (the spec's "Comment:" field). Starts empty.
    @State private var comment: String = ""
    /// Focus the Comment field on appear (the spec: "this field is focused and active when the dialog opens").
    @FocusState private var commentFocused: Bool

    private let panelWidth: CGFloat = 520
    private let previewMaxHeight: CGFloat = 72
    private let commentMinHeight: CGFloat = 96

    init(
        context: SendToChatContext,
        sessions: [SendToChatSession],
        initialSelection: PaneID?,
        onSend: @escaping (_ target: PaneID?, _ message: String) -> Void,
        onCopy: @escaping (_ message: String) -> Void,
        onCancel: @escaping () -> Void,
        onSelectionChange: ((PaneID?) -> Void)? = nil,
    ) {
        self.context = context
        self.sessions = sessions
        self.onSend = onSend
        self.onCopy = onCopy
        self.onCancel = onCancel
        self.onSelectionChange = onSelectionChange
        _selectedSessionID = State(initialValue: initialSelection)
    }

    /// The composed VERBATIM message — recomputed as the comment changes (the quoted block + the comment).
    private var composedMessage: String {
        SendToChatModel.compose(context: context, comment: comment)
    }

    var body: some View {
        OverlayPanel(width: panelWidth) {
            VStack(alignment: .leading, spacing: Slate.Metric.space3) {
                titleRow
                quotedPreview
                sendToRow
                commentSection
                buttonRow
            }
            .padding(Slate.Metric.space4)
        }
        .onAppear { DispatchQueue.main.async { commentFocused = true } }
        #if os(macOS)
            .onExitCommand { onCancel() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                onCancel()
                return .handled
            }
        #endif
    }

    // MARK: - Title (the source location, e.g. "composer.md L3")

    private var titleRow: some View {
        Text(context.title)
            .font(.system(size: Slate.Typeface.body, weight: .semibold))
            .foregroundStyle(Slate.Text.primary)
            .lineLimit(1)
    }

    // MARK: - Quoted context preview (read-only, scrollable, monospaced)

    private var quotedPreview: some View {
        ScrollView {
            Text(context.quoted)
                .font(.system(size: Slate.Typeface.footnote).monospaced())
                .foregroundStyle(Slate.Text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Slate.Metric.space2)
        }
        .frame(maxHeight: previewMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(Slate.Surface.element),
        )
    }

    // MARK: - "Send to:" Claude-only session picker

    private var sendToRow: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text("Send to:")
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
            Picker("Send to", selection: $selectedSessionID) {
                ForEach(sessions) { session in
                    sessionRow(session).tag(Optional(session.id))
                }
                // "New session" — always offered (the only option when no agent pane is open).
                Text("New session").tag(PaneID?.none)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Slate.Text.primary)
            .onChange(of: selectedSessionID) { _, new in onSelectionChange?(new) }
            Spacer(minLength: 0)
        }
    }

    private func sessionRow(_ session: SendToChatSession) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(session.name)
                .foregroundStyle(Slate.Text.primary)
            Text(session.agentLabel) // Claude-only badge — never "codex"
                .foregroundStyle(Slate.Text.tertiary)
        }
    }

    // MARK: - "Comment:" field (focused, multi-line)

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text("Comment:")
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
            TextField("", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent)
                .focused($commentFocused)
                .lineLimit(3...8)
                .padding(Slate.Metric.space2)
                .frame(minHeight: commentMinHeight, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .stroke(Slate.Line.card, lineWidth: Slate.Metric.hairline),
                )
        }
    }

    // MARK: - Buttons (Copy Message · Cancel · Send)

    private var buttonRow: some View {
        HStack(spacing: Slate.Metric.space2) {
            Button("Copy Message") { onCopy(composedMessage) }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
            Spacer(minLength: Slate.Metric.space2)
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
            Button { onSend(selectedSessionID, composedMessage) } label: {
                Text("Send")
                    .font(.system(size: Slate.Typeface.body, weight: .semibold))
                    .foregroundStyle(Slate.Surface.card)
                    .padding(.horizontal, Slate.Metric.space3)
                    .padding(.vertical, Slate.Metric.space1)
                    .background(
                        RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                            .fill(Slate.State.accent),
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
#endif
