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

/// Pure layout mapping for the input field — kept free of SwiftUI so the rich-mode rendering effect (the
/// W3 fix: the field actually goes multi-line when `richMode` is on) is unit-testable without a view.
enum InputBarLayout {
    /// The field's line-limit range: a single line in plain mode, 3…8 lines in rich (multi-line) mode.
    static func lineLimit(richMode: Bool) -> ClosedRange<Int> { richMode ? 3...8 : 1...1 }
}

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

    /// Rich mode → a multi-line editor (3…8 lines); plain mode → a single line. Reading `model.richMode`
    /// (an `@Observable`) here makes the Rich-Input pill toggle actually re-render the field (W3). The pure
    /// mapping is in ``InputBarLayout`` so the rich-mode rendering effect is unit-gated.
    private var lineLimitRange: ClosedRange<Int> { InputBarLayout.lineLimit(richMode: model.richMode) }

    @ViewBuilder private var field: some View {
        if staticMirror {
            // Static mirror for ImageRenderer: a plain Text of the compose buffer (or placeholder). Mirror
            // the live multi-line layout so the snapshot reflects rich mode.
            Text(model.compose.isEmpty ? placeholder : model.compose)
                .font(WarpType.mono(WarpType.monospaceSize))
                .foregroundStyle(model.compose.isEmpty ? theme.textDisabled : theme.textMain)
                .lineLimit(lineLimitRange)
        } else {
            TextField(
                placeholder,
                text: Binding(get: { model.compose }, set: { model.compose = $0 }),
                axis: model.richMode ? .vertical : .horizontal,
            )
            .textFieldStyle(.plain)
            .font(WarpType.mono(WarpType.monospaceSize))
            .foregroundStyle(theme.textMain)
            .focused($fieldFocused)
            .lineLimit(lineLimitRange)
            .onSubmit { model.submit() }
            // In rich (`.vertical`) mode a bare Return inserts a newline; ⌘Return submits. (In plain mode
            // `.onSubmit` already handles Return; this handler is harmless there.)
            .onKeyPress(.return, phases: .down) { press in
                guard model.richMode else { return .ignored }
                if press.modifiers.contains(.command) {
                    model.submit()
                    return .handled
                }
                return .ignored // bare Return → let the editor insert a newline
            }
        }
    }
}
