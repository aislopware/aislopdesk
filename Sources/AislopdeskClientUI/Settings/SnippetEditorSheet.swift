// SnippetEditorSheet — the "Edit Text Snippet" modal (E16 WI-7, `docs/ui-shell/screenshots/textsnippet-
// setting.png`). A self-contained SwiftUI sheet that edits a snippet's Name / Alias / Text and hands the
// three strings back to its presenter (Settings → Recipes) via `onSave`; it never touches the store directly,
// so it is pure-view + cross-platform (macOS Settings window + the iOS settings sheet host the same struct).
//
// FIDELITY (textsnippet-setting.png): a card-surface sheet with a bold title + `×` close, then three labeled
// fields each with the exact helper line — **Name** ("Shown in the command palette and this list."),
// **Alias** ("Trigger word typed at the shell prompt to expand this snippet.", monospaced), **Text** (a
// multiline monospaced editor) — a placeholder reference line (`{{cursor}} · {{clipboard}} · {{date}} ·
// {{time}}`), and a footer with a plain **Cancel** and a solid-accent **Save Changes**. The literal white of
// the reference screenshot is a light Paper-style theme; here every surface reads the live `Slate` theme
// tokens (so it adapts to the Monokai-Pro default) — match the design SYSTEM, not the captured pixels.
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The modal snippet editor. Presented with the snippet's current values (empty for a new snippet); on
/// **Save Changes** it calls `onSave(name, alias, body)` and dismisses. Alias whitespace is normalized by the
/// store's CRUD (`Snippet.normalizeAlias`), so this view stores the raw text and lets the store clean it.
struct SnippetEditorSheet: View {
    /// Whether this is a fresh snippet (titles the sheet "New Text Snippet") or an existing one ("Edit Text
    /// Snippet", the screenshot case).
    let isNew: Bool
    /// Called with the edited (name, alias, body) when the user taps Save Changes. The presenter routes it to
    /// `WorkspaceStore.addSnippet` / `updateSnippet`.
    let onSave: (_ name: String, _ alias: String, _ body: String) -> Void

    @State private var name: String
    @State private var alias: String
    /// The snippet body text. Named `snippetText` (NOT `body`) so it does not collide with the SwiftUI
    /// `var body: some View` requirement.
    @State private var snippetText: String
    /// The live height of the multiline Text editor — driven by the bottom-trailing drag grip (the resize
    /// handle in `textsnippet-setting.png`; SwiftUI's `TextEditor` exposes no native grip, so the grip is a
    /// manual `DragGesture`). Clamped to ``Self/textAreaMinHeight`` so it can never collapse.
    @State private var textAreaHeight: CGFloat = 120
    /// The editor height captured at the START of a resize drag, so the cumulative `DragGesture` translation
    /// applies from a stable base (never compounds frame-to-frame). `nil` between drags.
    @State private var resizeStartHeight: CGFloat?

    @Environment(\.dismiss) private var dismiss

    /// The floor the drag-resize clamps the Text editor to (its initial height).
    private static let textAreaMinHeight: CGFloat = 120

    init(
        isNew: Bool,
        name: String = "",
        alias: String = "",
        body: String = "",
        onSave: @escaping (_ name: String, _ alias: String, _ body: String) -> Void,
    ) {
        self.isNew = isNew
        self.onSave = onSave
        _name = State(initialValue: name)
        _alias = State(initialValue: alias)
        _snippetText = State(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space4) {
            header
            field(
                label: "Name",
                helper: "Shown in the command palette and this list.",
                text: $name,
                mono: false,
            )
            field(
                label: "Alias",
                helper: "Trigger word typed at the shell prompt to expand this snippet.",
                text: $alias,
                mono: true,
            )
            textArea
            footer
        }
        .padding(Slate.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Slate.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
    }

    // MARK: Header (title + close)

    private var header: some View {
        HStack {
            Text(isNew ? "New Text Snippet" : "Edit Text Snippet")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemSymbol: .xmark)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Single-line field (Name / Alias)

    private func field(label: String, helper: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text(label)
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(mono
                    ? .system(size: Slate.Typeface.body).monospaced()
                    : .system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent)
                .padding(Slate.Metric.space2)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                )
            Text(helper)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
        }
    }

    // MARK: Multiline text area (Text + the placeholder reference line)

    private var textArea: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            Text("Text")
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
            TextEditor(text: $snippetText)
                .font(.system(size: Slate.Typeface.body).monospaced())
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent)
                .scrollContentBackground(.hidden)
                .frame(height: textAreaHeight)
                .padding(Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                )
                .overlay(alignment: .bottomTrailing) { resizeGrip }
            // The reserved template vars (resolved by `ReservedSnippetVars`, never user-prompted) — the
            // helper line, verbatim, so the user knows the four built-in placeholders exist.
            Text("Placeholders: {{cursor}} · {{clipboard}} · {{date}} · {{time}}")
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.tertiary)
        }
    }

    /// The bottom-right resize grip for the Text editor (`textsnippet-setting.png`). `TextEditor` has no native
    /// grip, so this is a manual diagonal-hatch handle driven by a `DragGesture`: each drag grows/shrinks the
    /// editor height from the height captured at drag-start (clamped to ``Self/textAreaMinHeight`` via the
    /// ordered, NaN-faithful `CGFloat.maximum` — the house float idiom, never a bare clamp).
    private var resizeGrip: some View {
        SnippetResizeGrip()
            .fill(Slate.Text.tertiary)
            .frame(width: 11, height: 11)
            .padding(Slate.Metric.space1 + 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = resizeStartHeight ?? textAreaHeight
                        if resizeStartHeight == nil { resizeStartHeight = base }
                        textAreaHeight = CGFloat.maximum(Self.textAreaMinHeight, base + value.translation.height)
                    }
                    .onEnded { _ in resizeStartHeight = nil },
            )
        #if os(macOS)
            .pointerStyle(.frameResize(position: .bottomTrailing))
        #endif
            .accessibilityHidden(true)
    }

    // MARK: Footer (Cancel + Save Changes)

    private var footer: some View {
        HStack(spacing: Slate.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)

            Button {
                onSave(name, alias, snippetText)
                dismiss()
            } label: {
                Text("Save Changes")
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
        }
    }
}

/// A small bottom-right corner grip — three diagonal hatches, the conventional "drag to resize" affordance
/// (mirrors the floating-pane card's corner grip). Pure `Shape`, no theme read.
private struct SnippetResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Three parallel diagonals fanning out from the bottom-right corner (closest = longest).
        let insets: [CGFloat] = [rect.width, rect.width * 0.62, rect.width * 0.28]
        for inset in insets {
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}
#endif
