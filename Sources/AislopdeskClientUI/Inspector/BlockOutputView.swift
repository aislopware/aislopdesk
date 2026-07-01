// BlockOutputView — the expanded output of a selected command block (REBUILD-V2, L3).
//
// Renders the VT-stripped PLAIN TEXT (the model's `BlockOutputSanitizer.plainText`, already applied by
// `TerminalViewModel.copyBlockOutput`) as a scrollable, SELECTABLE monospaced `Text` with a copy button.
// While the host reply is in flight it shows a `ProgressView`; a block the host captured no bytes for
// (`outputLen == 0`) shows a neutral note; an unavailable/evicted block (`text == nil` after fetch) says so.
//
// Plain VT-stripped text is the reliable DEFAULT (per the L3 brief). An opt-in "rich" toggle re-renders
// the same text as Markdown via `MarkdownText` (Textual) — useful for `gh pr view`, READMEs catted to the
// terminal, or a Claude reply — without changing the default (so no output is ever misformatted unasked).
// SYSTEM colours + monospaced/system fonts only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BlockOutputView: View {
    /// The fetched, RAW captured VT output bytes. `nil` while still being fetched OR when the host reported
    /// the block unavailable — disambiguated by `isFetching`. The SGR colour runs are rendered by
    /// `ANSIOutputStyler`; the copy / Markdown paths strip them through `BlockOutputSanitizer`.
    let bytes: Data?
    /// Whether a `blockOutput` request is currently in flight (drives the spinner vs. the unavailable note).
    let isFetching: Bool
    /// The host's byte-count hint for the block — `0` means "command produced no output" (a distinct empty
    /// state from "output unavailable / evicted").
    let outputLen: UInt32

    /// Opt-in Markdown rendering of the output (default OFF — terminal output is plain by default so it is
    /// never misinterpreted as Markdown; the user flips this per-block when the output IS Markdown).
    @State private var renderRich = false

    /// The VT-stripped plain text (for the Markdown toggle, the copy button, and the empty checks) — derived
    /// from the raw `bytes` on demand.
    private var plainText: String? { bytes.map { BlockOutputSanitizer.plainText(from: $0) } }

    /// The COLOURED render of the raw bytes, mapped to the active terminal theme's ANSI palette.
    private var coloured: AttributedString? {
        guard let bytes else { return nil }
        let theme = Slate.theme
        return ANSIOutputStyler.attributed(
            from: bytes,
            palette: theme.ansiPalette.map { UInt32(hex6: $0) },
            defaultFg: UInt32(hex6: theme.terminalForegroundHex),
            defaultBg: UInt32(hex6: theme.terminalBackgroundHex),
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if isFetching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching output…").font(.callout).foregroundStyle(Slate.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let text = plainText, !text.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if renderRich {
                        MarkdownText(markdown: text)
                    } else {
                        // Render the COLOURED bytes (SGR → theme ANSI palette) — falls back to the plain
                        // text if the styler produced nothing. The base monospaced font applies to any run
                        // the styler did not override (bold/italic runs carry their own font).
                        Text(coloured ?? AttributedString(text))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .slateCard()
        } else if outputLen == 0 {
            note("No output", "The command produced no captured output.")
        } else {
            note("Output unavailable", "The host no longer holds this block's output.")
        }
    }

    /// The header row: a small label + a copy button (disabled until there is text to copy).
    private var header: some View {
        HStack {
            Text("Output")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Slate.State.header)
            Spacer(minLength: 0)
            Button {
                renderRich.toggle()
            } label: {
                Label("Render Markdown", systemSymbol: renderRich ? .docPlaintext : .docRichtext)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(renderRich ? "Show raw text" : "Render as Markdown")
            .disabled((plainText ?? "").isEmpty)
            Button {
                copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy output")
            .disabled((plainText ?? "").isEmpty)
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(Slate.Text.secondary)
            Text(detail).font(.caption).foregroundStyle(Slate.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func copy() {
        guard let text = plainText, !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
