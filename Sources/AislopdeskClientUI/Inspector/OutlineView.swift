// OutlineView — the Details Panel's Outline tab (E9, WI-5).
//
// The Outline tab (spec/user-interface__outline.md §"Outline in Details Panel"): a FLAT,
// CHRONOLOGICAL (oldest→newest) list of the active pane's shell command marks — one row per `CommandBlock`,
// built from the per-pane OSC-133 index (`TerminalBlockModel`). Each row carries a left exit-status gutter
// (green ✓ on success / red ✗ on failure / grey · while running, via `OutlinePresentation.gutter`), the
// truncated command text, and a right-aligned relative timestamp (`OutlinePresentation.relativeTime` over the
// model's CLIENT-RECEIVE first-seen time — there is no host clock on the wire). Tapping a row jumps the
// scrollback to that command (`onJump` → `WorkspaceStore.jumpToNavigatorBlockInActivePane`); a right-click
// menu offers "Jump to" + "Copy" (the row's command text → pasteboard).
//
// AGENT-PROMPT ROWS — DOCUMENTED PARTIAL (DECISIONS.md). An agent session's history PROMPTS are not listed
// here: Aislopdesk carries no prompt-mark signal on the wire (the block index is shell command marks
// only). Under the Claude-first scope reduction, E9 renders the command-mark Outline FAITHFULLY for both
// terminal and agent panes (the agent's shell marks ARE captured) and DEFERS prompt-row decoration — no
// prompt row is invented.
//
// Slate tokens / fonts only. The only theme-coupled part is the `Gutter → colour` map; the classification +
// the relative-time string are the PURE, headlessly-tested `OutlinePresentation` (WI-4). `TimelineView`
// re-renders the rows periodically so an idle pane's "4m" relative stamps still tick.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct OutlineView: View {
    /// The active pane's pure block store — the Outline's data source (chronological `blocks`, oldest first).
    let model: TerminalBlockModel
    /// The clock the relative-timestamp column reads — injectable (default real wall clock). Re-evaluated on
    /// each `TimelineView` tick so the stamps stay live without a model change.
    var now: () -> Date = { Date() }
    /// Jumps the scrollback to a block index (the active pane's `jumpToNavigatorBlockInActivePane`). Passed in
    /// so this view stays free of the store/client actor, like the other inspector views.
    let onJump: (UInt32) -> Void

    var body: some View {
        Group {
            if model.blocks.isEmpty {
                emptyState
            } else {
                // The periodic tick only forces a re-render; `now()` supplies the actual instant (so an
                // injected fixed clock is still honoured). 30s cadence matches the coarse relative buckets.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    list(now: now())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: List

    private func list(now: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.blocks) { block in
                    row(for: block, now: now)
                }
            }
            .padding(.vertical, Slate.Metric.space1)
        }
    }

    private func row(for block: CommandBlock, now: Date) -> some View {
        let firstSeen = model.firstSeen(index: block.index) ?? now
        return Button {
            onJump(block.index)
        } label: {
            HStack(spacing: Slate.Metric.space2) {
                gutter(for: block)
                    .frame(width: 14, alignment: .center)
                Text(displayText(block))
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Slate.Metric.space2)
                Text(OutlinePresentation.relativeTime(from: firstSeen, now: now))
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(for: block) }
    }

    /// The status gutter glyph — green ✓ (succeeded) / red ✗ (failed) / grey · (running). The colour is the
    /// ONLY theme-coupled part; the bucket itself is the pure `OutlinePresentation.gutter` classification.
    @ViewBuilder
    private func gutter(for block: CommandBlock) -> some View {
        switch OutlinePresentation.gutter(for: block) {
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.ok)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: Slate.Typeface.small, weight: .bold))
                .foregroundStyle(Slate.Status.err)
        case .running:
            Circle()
                .fill(Slate.Text.tertiary)
                .frame(width: 5, height: 5)
        }
    }

    @ViewBuilder
    private func rowMenu(for block: CommandBlock) -> some View {
        Button {
            onJump(block.index)
        } label: {
            Label("Jump to", systemImage: "arrow.right.to.line")
        }
        Button {
            copyToPasteboard(block.commandText)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(block.commandText.isEmpty)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Commands",
            systemImage: "list.bullet",
            description: Text("Run a command to see it here"),
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    /// The row's display string — the command text, or an em-dash for a block still forming (no text yet).
    private func displayText(_ block: CommandBlock) -> String {
        block.commandText.isEmpty ? "—" : block.commandText
    }

    /// Copies a row's command text to the platform pasteboard (the Outline row's right-click "Copy" action),
    /// using the same `AppKit`/`UIKit` idiom as `RemoteFileTreeView.copyPath`. A no-op for an empty command.
    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
#endif
