// MarkdownText — the app's ONE Markdown rendering seam, backed by gonzalezreal/Textual's `StructuredText`
// (the pure-Swift `AttributedString`-based successor to swift-markdown-ui/MarkdownUI). Every Markdown
// surface (the Claude transcript / assistant messages once that inspector layer is rebuilt, and the
// opt-in "rich" block-output view today) renders through here, so the renderer choice + the safety guard
// live in one place.
//
// SAFETY GUARD (Textual issue #23 — crash on very large documents): above a conservative size we fall
// back to a selectable monospaced plain `Text`. A Claude transcript or a long catted file can blow past
// Textual's safe range, and a renderer crash in an inspector pane is far worse than unstyled text. The
// `shouldRenderRich(_:)` decision is pure + unit-tested (`MarkdownTextTests`) so the threshold is pinned.
//
// Selection is enabled (an inspector pane must be copyable) and wide code blocks scroll rather than force
// the pane wide (`.overflowMode(.scroll)`). SwiftUI-only — Textual links to ClientUI alone.

#if canImport(SwiftUI)
import SwiftUI
import Textual

struct MarkdownText: View {
    /// The Markdown source to render.
    let markdown: String

    /// Above these bounds we render plain text instead of rich Markdown to dodge Textual's large-document
    /// crash (issue #23). Sized well above a normal assistant message / block output but below the danger
    /// zone (~200+ blocks); a transcript that large is better shown as scrollable plain text than not at all.
    static let maxRichBytes = 40000
    static let maxRichLines = 600

    var body: some View {
        if Self.shouldRenderRich(markdown) {
            StructuredText(markdown: markdown)
                .textual.textSelection(.enabled)
                .textual.overflowMode(.scroll)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Guard / fallback path: selectable monospaced plain text (also what an empty string yields).
            Text(markdown)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Slate.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whether `source` is small enough to render as rich Markdown (vs the plain-text guard). Pure +
    /// allocation-free so it is cheap on every render and unit-testable without a view.
    static func shouldRenderRich(_ source: String) -> Bool {
        guard !source.isEmpty else { return false }
        if source.utf8.count > maxRichBytes { return false }
        var lines = 1
        for byte in source.utf8 where byte == 0x0A {
            lines += 1
            if lines > maxRichLines { return false }
        }
        return true
    }
}
#endif
