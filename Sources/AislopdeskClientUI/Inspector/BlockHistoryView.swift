// BlockHistoryView — the Commands inspector panel (REBUILD-V2, L3): a first-class, Warp-style command
// navigator bound to the ACTIVE terminal pane's `TerminalBlockModel`.
//
// Header ("Commands") + a "Failed only" toggle, a native `List(selection:)` of the model's newest-first
// `navigatorBlocks` (filtered) rendered via `BlockRowView`, and a detail area below the list that expands
// the selected block's output (`BlockOutputView`). Selecting a block REQUESTS its captured output via the
// injected `requestOutput` closure (the pane's `TerminalViewModel.copyBlockOutput`, which fires wire type
// 15 and resolves with VT-stripped plain text). Per-row `.contextMenu`: copy command / copy output /
// star-unstar (the model's bookmarks API). ⌘↑/⌘↓ move the selection. Empty state via
// `ContentUnavailableView`.
//
// SYSTEM colours, SF Symbols, system + monospaced fonts only — NO design-system. The block model +
// sanitizer are pure; this view holds only selection + a per-index fetched-output cache as `@State`.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BlockHistoryView: View {
    /// The active pane's pure block store (newest-first `navigatorBlocks`, bookmarks API).
    let model: TerminalBlockModel
    /// Fires the output-request flow for a block index, calling back with the VT-stripped plain text
    /// (`nil` when evicted / unavailable / disconnected). Injected from the active pane's
    /// `TerminalViewModel.copyBlockOutput(index:onResult:)` so this view stays free of the client actor.
    let requestOutput: (UInt32, @escaping (String?) -> Void) -> Void

    @State private var selection: UInt32?
    @State private var failedOnly = false
    /// Whether the Commands list owns keyboard focus. Gates the ⌘↑/⌘↓ stepper so the shortcut is LIVE only
    /// while the inspector list is focused — otherwise the window-global `.keyboardShortcut` would swallow
    /// ⌘↑/⌘↓ even when a terminal pane is focused (a disabled control does not fire its shortcut).
    @FocusState private var listFocused: Bool
    /// The fetched plain-text output per block index. A present key = fetch resolved (value may be `nil`
    /// for unavailable); an absent key + `fetching` membership = a request is in flight.
    @State private var outputCache: [UInt32: String?] = [:]
    @State private var fetching: Set<UInt32> = []

    /// The currently-displayed blocks: newest-first, optionally filtered to failures.
    private var blocks: [CommandBlock] {
        model.blocks(filter: failedOnly ? .failed : .all)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if blocks.isEmpty {
                emptyState
            } else {
                list
                if let selected = selectedBlock {
                    Divider()
                    detail(for: selected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Commands").font(.headline)
            Spacer(minLength: 0)
            Toggle(isOn: $failedOnly) {
                Label("Failed only", systemImage: "xmark.octagon")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Show failed commands only")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(blocks) { block in
                BlockRowView(block: block, isBookmarked: model.isBookmarked(block.index))
                    .tag(block.index)
                    .contextMenu { rowMenu(for: block) }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .onChange(of: selection) { _, newValue in
            if let index = newValue { fetchIfNeeded(index) }
        }
        // ⌘↑ / ⌘↓ step the selection through the (filtered) newest-first list.
        .overlay(keyboardStepper)
    }

    /// Invisible buttons carrying ⌘↑ / ⌘↓ so selection-stepping works without stealing other keys. DISABLED
    /// unless the list is focused: a window-global `.keyboardShortcut` fires regardless of focus, so an
    /// always-enabled stepper would capture ⌘↑/⌘↓ away from a focused terminal pane. A disabled control does
    /// not respond to its keyboard shortcut, so gating on `listFocused` scopes the binding to the inspector.
    private var keyboardStepper: some View {
        ZStack {
            Button("") { step(by: -1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { step(by: 1) }.keyboardShortcut(.downArrow, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .disabled(!listFocused)
    }

    // MARK: Detail

    private func detail(for block: CommandBlock) -> some View {
        BlockOutputView(
            text: cachedText(for: block.index),
            isFetching: fetching.contains(block.index),
            outputLen: block.outputLen,
        )
        .padding(12)
        .frame(maxHeight: 260)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            failedOnly ? "No Failed Commands" : "No Commands",
            systemImage: "terminal",
            description: Text(failedOnly ? "No command has failed yet" : "Run a command to see it here"),
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row context menu

    @ViewBuilder
    private func rowMenu(for block: CommandBlock) -> some View {
        Button {
            copyToPasteboard(block.commandText)
        } label: {
            Label("Copy Command", systemImage: "doc.on.doc")
        }
        .disabled(block.commandText.isEmpty)

        Button {
            copyOutput(for: block.index)
        } label: {
            Label("Copy Output", systemImage: "text.alignleft")
        }
        .disabled(block.outputLen == 0)

        Divider()

        Button {
            model.toggleBookmark(index: block.index)
        } label: {
            Label(
                model.isBookmarked(block.index) ? "Unstar" : "Star",
                systemImage: model.isBookmarked(block.index) ? "star.slash" : "star",
            )
        }
    }

    // MARK: Selection + fetch

    private var selectedBlock: CommandBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.index == selection }
    }

    /// The resolved output text for a cached index. The cache value is itself optional (`nil` = fetched
    /// but unavailable), so a `case let` unwraps the OUTER optional (present = resolved) and yields the
    /// inner value; an absent key (not yet fetched) is `nil`.
    private func cachedText(for index: UInt32) -> String? {
        if case let .some(value) = outputCache[index] { return value }
        return nil
    }

    /// Moves the selection by `delta` positions within the current (filtered, newest-first) list, clamped.
    private func step(by delta: Int) {
        guard !blocks.isEmpty else { return }
        let current = selection.flatMap { sel in blocks.firstIndex { $0.index == sel } }
        let next: Int =
            if let current {
                min(max(current + delta, 0), blocks.count - 1)
            } else {
                delta >= 0 ? 0 : blocks.count - 1
            }
        let index = blocks[next].index
        selection = index
        fetchIfNeeded(index)
    }

    /// Requests `index`'s output once; caches the result (incl. `nil` for unavailable) so a re-select
    /// does not re-fire the wire request.
    private func fetchIfNeeded(_ index: UInt32) {
        guard outputCache.index(forKey: index) == nil, !fetching.contains(index) else { return }
        fetching.insert(index)
        requestOutput(index) { result in
            fetching.remove(index)
            outputCache[index] = result
        }
    }

    /// Copies a block's output to the pasteboard, fetching it first if not cached.
    private func copyOutput(for index: UInt32) {
        if let cached = outputCache[index] {
            if let text = cached { copyToPasteboard(text) }
            return
        }
        requestOutput(index) { result in
            outputCache[index] = result
            if let text = result { copyToPasteboard(text) }
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
#endif
