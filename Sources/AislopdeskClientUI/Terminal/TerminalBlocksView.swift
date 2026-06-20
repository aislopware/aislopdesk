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
    /// WB3: the status / bookmark filter segment (all / failed / bookmarked).
    @State private var filter: BlockNavigatorFilter = .all
    /// The index of a block whose copy-output request is in flight (shows the row spinner).
    @State private var copyingIndex: UInt32?
    /// A transient per-row status note ("Copied", "Output unavailable", "Re-run") keyed by block index.
    @State private var note: (index: UInt32, text: String)?

    /// The blocks matching the FILTER segment AND the text query (newest first). The filter (all / failed /
    /// bookmarked) is the model query; the text query narrows it further.
    private var filtered: [CommandBlock] {
        let base = model.blocks.blocks(filter: filter)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.commandText.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar
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

    /// WB3: the All / Failed / Bookmarked filter segment.
    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            ForEach(BlockNavigatorFilter.allCases, id: \.self) { f in
                Label(f.title, systemImage: f.symbol).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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

            // WB3: star / unstar this block (the "Bookmarked" filter shows only starred blocks). Filled
            // star when bookmarked. Persists via the model's onBookmarksChanged (wired on attach).
            Button { model.blocks.toggleBookmark(index: block.index) } label: {
                Image(systemName: model.blocks.isBookmarked(block.index) ? "star.fill" : "star")
                    .foregroundStyle(model.blocks.isBookmarked(block.index) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.blocks.isBookmarked(block.index) ? "Remove bookmark" : "Bookmark this command")
            .accessibilityLabel(model.blocks.isBookmarked(block.index) ? "Remove bookmark" : "Bookmark command")

            // WB3: re-run this block's command into THIS pane (verbatim text + newline). NOT gated on
            // completion — re-running a still-running command's text is allowed.
            Button { reRun(block) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-run this command")
                .accessibilityLabel("Re-run command")

            // Jump to this block (libghostty jump_to_prompt by its relative position from newest).
            Button { jump(to: block) } label: { Image(systemName: "arrow.right.to.line") }
                .buttonStyle(.borderless)
                .help("Jump to this command")
                .accessibilityLabel("Jump to command")

            // Copy this block's output (request type 15 → strip VT → clipboard). DISABLED until the block
            // COMPLETES: the host only retains output on completion (a running block's bytes are still
            // growing and not in the ring), so a copy of a running block would always reply "unavailable".
            Group {
                if copyingIndex == block.index {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { copyOutput(of: block) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .disabled(!block.complete)
                        .help(block.complete ? "Copy command output" : "Output available once the command finishes")
                        .accessibilityLabel("Copy command output")
                }
            }
            .frame(width: 20)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Jumps the viewport to `block` via libghostty's prompt navigation.
    ///
    /// libghostty's `jump_to_prompt:<delta>` is viewport-RELATIVE (`PageList.scrollPrompt` steps `delta`
    /// prompts from the CURRENT viewport, and `delta == 0` is a no-op), so a bare `jump_to_prompt:-pos`
    /// (pos = the block's position in the newest-first list) is only correct when the viewport already sits
    /// at the newest prompt — after any prior scroll/jump it is off by the current viewport offset, and the
    /// newest block (pos 0) never moves at all. We therefore RE-ANCHOR first: `scroll_to_bottom` parks the
    /// viewport at the newest prompt (a real libghostty binding action — `Surface.zig` → `scrollViewport
    /// (.bottom)`), and only THEN do we step `pos` prompts up from that known anchor. From the bottom anchor
    /// the delta is deterministic (independent of where the viewport happened to be), and the newest block
    /// is a no-op step that correctly leaves us at the bottom.
    ///
    /// (The ⌃⌘[/] ±1 chord path stays a pure RELATIVE step — see ``WorkspaceStore/jumpToBlockInActivePane
    /// (delta:)`` — because there "previous/next from here" IS the intent.)
    private func jump(to block: CommandBlock) {
        guard let actions = model.surface as? TerminalSurfaceActions else { return }
        // navigatorBlocks is newest-first; pos 0 = the newest (current) prompt.
        let newest = model.blocks.navigatorBlocks
        guard let pos = newest.firstIndex(where: { $0.index == block.index }) else { return }
        // Re-anchor to the newest prompt, then step `pos` prompts up — the ONE shared absolute jump impl
        // (so the navigator + the store's jump-to-failed can't drift on the delta math).
        BlockJump.toNavigatorPosition(pos, using: actions)
        isPresented = false
    }

    /// The libghostty `jump_to_prompt` delta to reach the navigator block at `toTargetPos` (0 = newest)
    /// AFTER the viewport has been re-anchored to the newest prompt (`scroll_to_bottom`).
    ///
    /// From the bottom anchor the newest prompt is "0 prompts up", so target N (the Nth-newest block) is
    /// exactly N prompts UP → a delta of `-N`. This is robust to a prior scroll/jump precisely BECAUSE the
    /// caller re-anchors first: the delta no longer depends on where the viewport happened to be.
    ///
    /// NOTE on eviction divergence: `toTargetPos` is the block's position in the CLIENT's bounded
    /// navigator list, which can diverge from libghostty's prompt count if the client evicted blocks the
    /// terminal still has in scrollback (or vice-versa). The two rings share the same 64-cap, so they track
    /// closely in practice; an off-by-a-few landing is self-correcting (the user re-jumps) and never traps.
    ///
    /// Forwards to ``BlockJump/jumpDelta(toTargetPos:)`` — the ONE source of the delta math the store's
    /// jump-to-failed shares — so the two call sites can't drift. `nonisolated`: a pure integer mapping with
    /// no view state, so the unit test (`CommandNavigatorJumpTests`) reaches it without an actor hop.
    nonisolated static func jumpDelta(toTargetPos pos: Int) -> Int {
        BlockJump.jumpDelta(toTargetPos: pos)
    }

    /// WB3: re-runs `block`'s captured command into THIS navigator's own pane by re-injecting the verbatim
    /// text (+1 newline) through the normal input path (``TerminalViewModel/sendInput(_:)`` → wire type 3).
    /// A no-op for an empty command (``BlockReRunEncoder`` returns `nil`); closes the navigator so the user
    /// sees the command land. NOT gated on completion (re-running a running command's text is fine).
    private func reRun(_ block: CommandBlock) {
        guard let bytes = BlockReRunEncoder.bytes(for: block.commandText) else { return }
        model.sendInput(bytes)
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
