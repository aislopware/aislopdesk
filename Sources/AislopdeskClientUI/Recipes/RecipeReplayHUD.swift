// RecipeReplayHUD — the in-pane command-replay banner (E16 WI-9, spec `customization__custom-commands.md`
// §Command Replay). When a recipe opens in **Ask Once** (the DEFAULT for opened `.aislopdeskrecipe` files) or
// **Manually**, the store parks the captured commands in a per-pane `RecipeReplayMachine` that waits for the
// user — it injects NOTHING until a confirm. Without a control driving that confirm those two modes silently
// never replay (the OSC-133;D prompt-return edge only resumes a shell-handoff pause, never an
// `awaitingConfirmation`). This banner IS that control: it renders `WorkspaceStore.recipeReplayPrompt(for:)`
// and wires its single button to `continueRecipeReplay(for:)` keyed by THIS banner's own `paneID` — a banner
// is mounted over EVERY pane with a pending replay prompt (a multi-pane Include-Commands recipe shows several
// at once), so the button must advance the pane the banner sits over, NOT whatever pane is active. It also
// surfaces a "Continue" past a shell handoff (`ssh`/…) so the user can step the queue even when the inner
// session never returns a local prompt.
//
// The replay affordance is a banner that shows the queued commands + a run control. `Slate.*`
// tokens only (raw font / radius / colour literals fail `scripts/check-ds-leaks.sh`). No libghostty / Metal /
// VideoToolbox is touched: it is a plain SwiftUI banner driven by the store's OBSERVABLE replay state.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The in-pane command-replay banner. Self-hides (renders nothing) whenever
/// ``WorkspaceStore/recipeReplayPrompt(for:)`` is `nil` — i.e. no replay is in flight, or the in-flight
/// replay needs no user action (Auto mid-drain / Skip / finished). Mounted by ``TerminalLeafView`` over EVERY
/// terminal pane with a pending replay prompt; its button advances THIS banner's own pane (``paneID``), so a
/// multi-pane recipe with several banners up at once advances the correct machine per banner, never the
/// active pane's.
struct RecipeReplayHUD: View {
    /// The live workspace owner — read for the replay prompt and the continue action.
    let store: WorkspaceStore
    /// The pane this banner is over (the active pane). Reading the store's prompt for it tracks the
    /// `@Observable` replay state, so the banner reveals / advances / hides reactively.
    let paneID: PaneID

    var body: some View {
        if let prompt = store.recipeReplayPrompt(for: paneID) {
            banner(prompt)
        }
    }

    private func banner(_ prompt: RecipeReplayPrompt) -> some View {
        HStack(alignment: .center, spacing: Slate.Metric.space2) {
            Image(systemName: "play.circle")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.State.accent)
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                Text(prompt.message)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = prompt.commands.first {
                    Text(next)
                        .font(.system(size: Slate.Typeface.small).monospaced())
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Slate.Metric.space2)
            runButton(prompt.actionLabel)
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.vertical, Slate.Metric.space2)
        .background(Slate.Surface.card, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
        .shadow(color: Slate.State.shadow, radius: 4, x: 0, y: 1)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command replay")
        .accessibilityHint(prompt.message)
    }

    /// The single live "advance replay" control — a solid accent button. Drives THIS
    /// banner's own pane (``paneID``), so clicking a non-active pane's banner advances that pane's machine, not
    /// the active pane's.
    private func runButton(_ title: String) -> some View {
        Button { store.continueRecipeReplay(for: paneID) } label: {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Slate.Surface.card)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.State.accent),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
#endif
