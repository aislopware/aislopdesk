#if canImport(SwiftUI)
import AislopdeskTerminal
import SwiftUI

// MARK: - Block status presentation (shared SwiftUI helpers)

/// Shared SwiftUI presentation for a ``CommandBlock``'s status — the icon (a spinner while running, a
/// filled symbol otherwise) + its tint. Used by the navigator row, the sticky header, and the chrome chip
/// so the three never drift. Pure view helpers over the PURE ``CommandBlock/Status`` (unit-tested).
enum BlockStatusUI {
    /// The tint colour for a block's status (amber running, green succeeded, red failed).
    static func tint(_ block: CommandBlock) -> Color {
        switch block.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    /// The status icon: a small `ProgressView` spinner while running, else the filled status symbol.
    @ViewBuilder
    static func icon(_ block: CommandBlock) -> some View {
        switch block.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .succeeded,
             .failed:
            Image(systemName: block.statusSymbol)
                .foregroundStyle(tint(block))
        }
    }
}

// MARK: - StickyCommandHeader (the slim top-of-pane overlay for the CURRENT block)

/// The sticky command header (WB2): a slim bar pinned at the TOP of the terminal pane showing the
/// CURRENT / last command's text + a running spinner / exit badge. NO row alignment needed — it is just
/// the latest block (libghostty exposes no OSC 133 row positions, so we cannot align to command rows).
/// Shown only when there is at least one block.
struct StickyCommandHeader: View {
    let model: TerminalViewModel

    var body: some View {
        if let block = model.blocks.latest {
            HStack(spacing: 8) {
                BlockStatusUI.icon(block)
                    .frame(width: 14, height: 14)
                Text(block.commandText.isEmpty ? "(prompt)" : block.commandText)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                // Exit badge (or "running…") + duration, like a Warp block footer collapsed into the header.
                Text(block.statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BlockStatusUI.tint(block))
                if let duration = block.durationLabel {
                    Text(duration)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .allowsHitTesting(false) // purely informational — never swallow a scroll/click over the pane
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Current command \(block.commandText), \(block.statusLabel)"))
        }
    }
}

// MARK: - CommandNavigatorView (the searchable recent-blocks popover)

/// The Command Navigator (WB2): a searchable list/popover of the pane's recent blocks. Each row = status
/// icon + `commandText` + duration (+ exit code). Per-row actions: JUMP (libghostty `jump_to_prompt` by
/// the block's relative position — N blocks back from newest) and COPY OUTPUT (request type 15 → strip VT
/// → clipboard; empty reply → a brief "output unavailable", never a hang).
///
/// Compile-only (the surface jump touches libghostty via ``TerminalSurfaceActions``; the copy-output flow
/// touches the live client). The PURE pieces it drives — ``TerminalBlockModel`` (ordering / latest /
/// bound) + ``BlockOutputSanitizer`` (VT-strip) — carry the unit tests.
struct CommandNavigatorView: View {
    let model: TerminalViewModel
    @Binding var isPresented: Bool

    @State private var query = ""
    /// The index of a block whose copy-output request is in flight (shows the row spinner).
    @State private var copyingIndex: UInt32?
    /// A transient per-row status note ("Copied", "Output unavailable") keyed by block index.
    @State private var note: (index: UInt32, text: String)?

    /// The blocks matching the query (newest first). An empty query shows all recent blocks.
    private var filtered: [CommandBlock] {
        let all = model.blocks.navigatorBlocks
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.commandText.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { block in
                        row(block)
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #endif
            }
        }
        .frame(minWidth: 340, idealWidth: 420, minHeight: 220, idealHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            TextField("Filter commands", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close navigator")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No commands yet" : "No matching commands")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(_ block: CommandBlock) -> some View {
        HStack(spacing: 10) {
            BlockStatusUI.icon(block)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.commandText.isEmpty ? "(prompt)" : block.commandText)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(block.statusLabel)
                        .foregroundStyle(BlockStatusUI.tint(block))
                    if let duration = block.durationLabel {
                        Text("· \(duration)")
                    }
                    if let note, note.index == block.index {
                        Text("· \(note.text)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            // Jump to this block (libghostty jump_to_prompt by its relative position from newest).
            Button { jump(to: block) } label: { Image(systemName: "arrow.right.to.line") }
                .buttonStyle(.borderless)
                .help("Jump to this command")
                .accessibilityLabel("Jump to command")

            // Copy this block's output (request type 15 → strip VT → clipboard).
            Group {
                if copyingIndex == block.index {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { copyOutput(of: block) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy command output")
                        .accessibilityLabel("Copy command output")
                }
            }
            .frame(width: 20)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Jumps the viewport to `block` via libghostty `jump_to_prompt:<delta>`. The delta is the block's
    /// position relative to the NEWEST block (0 blocks back = the latest prompt, N back = N prompts up).
    /// libghostty owns the OSC 133 prompt marks, so we navigate by relative count — the only lever the
    /// C API gives us (it won't report absolute rows).
    private func jump(to block: CommandBlock) {
        guard let actions = model.surface as? TerminalSurfaceActions else { return }
        // navigatorBlocks is newest-first; the newest is "current". `jump_to_prompt:-N` steps N prompts up.
        let newest = model.blocks.navigatorBlocks
        guard let pos = newest.firstIndex(where: { $0.index == block.index }) else { return }
        // pos == 0 is the newest → the most recent prompt; step back `pos` prompts from there.
        actions.performBindingAction("jump_to_prompt:-\(pos)")
        isPresented = false
    }

    /// Requests `block`'s output, strips VT control sequences, and puts the plain text on the clipboard.
    /// An empty/unavailable reply (evicted block / no connection) shows a brief "Output unavailable" note —
    /// it NEVER hangs (the model resolves the request on the empty reply or via its timeout).
    private func copyOutput(of block: CommandBlock) {
        copyingIndex = block.index
        model.copyBlockOutput(index: block.index) { text in
            copyingIndex = nil
            if let text, !text.isEmpty {
                Self.setClipboard(text)
                note = (block.index, "Copied")
            } else {
                note = (block.index, "Output unavailable")
            }
        }
    }

    /// Puts `text` on the platform clipboard (macOS `NSPasteboard` / iOS `UIPasteboard`).
    private static func setClipboard(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}
#endif
