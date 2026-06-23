// InputBar — the command input row (warp-panes-blocks.md §4). A prompt glyph + an editable text field +
// a bar cursor in `theme.cursor()`, with a 1px top border separating it from the scrollback/blocks above.
// Bound to ``InputBarModel`` (which wraps the proven `InputBoxModel`): the affordance adapts the prompt
// (shell `>` vs CLI-agent compose), and submit/edit route through the model's single OUT funnel.
//
// The real key routing lives in WorkspaceCore (`InputBarModel.submit()`/`sendText`/`sendRaw`); this view
// only binds the compose text + a Return action. For ImageRenderer SNAPSHOT tests use `staticMirror:
// true` — it renders a non-interactive Text mirror of the compose buffer (headless ImageRenderer does not
// materialize a live TextField), per the L3 snapshot rule.

import AislopdeskClaudeCode
import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct InputBar: View {
    @Environment(\.theme) private var theme

    let model: InputBarModel
    /// EAGER/STATIC render path for headless ImageRenderer snapshots (no interactive TextField).
    var staticMirror: Bool = false

    @FocusState private var fieldFocused: Bool

    /// Prompt glyph per affordance: a shell `>` for `.shellCommand`, an agentic compose glyph otherwise.
    private var promptGlyph: String {
        switch model.affordance {
        case .shellCommand: "chevron.right"
        case .tuiCompose: "sparkle"
        }
    }

    private var placeholder: String {
        switch model.affordance {
        case .shellCommand: "Run a command"
        case .tuiCompose: "Message the agent"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: WarpSpace.m) {
            Image(systemName: promptGlyph)
                .font(.system(size: WarpType.monospaceSize, weight: .semibold))
                .foregroundStyle(model.affordance == .tuiCompose ? theme.agentFooterBrand : theme.accent)
            field
            // The bar cursor (theme.cursor()) — a thin 2pt vertical bar, the Warp `Bar` shape default.
            Capsule()
                .fill(theme.cursor)
                .frame(width: 2, height: WarpType.monospaceSize + 2)
                .opacity(staticMirror ? 1 : (fieldFocused ? 1 : 0.4))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarpSpace.xl)
        .padding(.vertical, WarpSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        // 1px top border = the divider between scrollback (blocks) and the input area (spec §4.1).
        .overlay(alignment: .top) {
            Rectangle().fill(theme.splitPaneBorder).frame(height: WarpBorder.width)
        }
    }

    @ViewBuilder private var field: some View {
        if staticMirror {
            // Static mirror for ImageRenderer: a plain Text of the compose buffer (or placeholder).
            Text(model.compose.isEmpty ? placeholder : model.compose)
                .font(WarpType.mono(WarpType.monospaceSize))
                .foregroundStyle(model.compose.isEmpty ? theme.textDisabled : theme.textMain)
                .lineLimit(1)
        } else {
            TextField(
                placeholder,
                text: Binding(get: { model.compose }, set: { model.compose = $0 }),
            )
            .textFieldStyle(.plain)
            .font(WarpType.mono(WarpType.monospaceSize))
            .foregroundStyle(theme.textMain)
            .focused($fieldFocused)
            .onSubmit { model.submit() }
        }
    }
}
