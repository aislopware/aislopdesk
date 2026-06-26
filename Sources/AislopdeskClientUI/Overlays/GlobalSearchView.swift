// GlobalSearchView — the cross-tab Global Search results surface (E5 / WI-4), opened by ⇧⌘F. A LARGE,
// content-area-filling, NON-scrimmed card (E5 divergence #1: the closest faithful equivalent to otty's
// dedicated results *tab*, which we do not add to avoid blast-radius across every `switch PaneKind` site).
// Mounted by ``OverlayHostView`` over the workspace WITHOUT a ``Scrim`` so it does not dim the panes.
//
// Anatomy matches `screenshots/global-search.png` (`Otty.*` tokens ONLY — raw font / colour / radius literals
// fail `scripts/check-ds-leaks.sh`):
//   ┌ query field [ Aa ][ .* ][ × ] ──────────────────────────────────┐
//   │ N results — M tabs                                               │
//   │ ▸ <group title (tab)>                                  ⌘1        │
//   │     <excerpt with the matched run highlighted amber>      ↗      │
//   │ ▸ <group title> …                                                │
//   └──────────────────────────────────────────────────────────────────┘
//
// SEAM discipline: this view owns ONLY its transient field/toggle `@State` (mirroring the store's retained
// `globalSearchQuery`/flags so a re-open restores them); ALL match math runs in the store via the PURE
// ``GlobalSearchController`` (``WorkspaceStore/runGlobalSearch``) — never a second matcher. A row tap jumps via
// ``WorkspaceStore/jumpToGlobalSearchResult(_:)`` then closes through the coordinator. The amber highlight is
// the in-buffer `GlobalSearchHit.highlight` UTF-16 range tinted on the excerpt (divergence #2: the counter /
// excerpt come from the scrollback mirror; the live in-pane highlight is libghostty's on jump).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct GlobalSearchView: View {
    /// The live store — owns the results (``WorkspaceStore/globalSearch``) + the run/jump ops. Read in `body`
    /// (`store.globalSearch`), so the `@Observable` store re-renders this view as results land.
    let store: WorkspaceStore
    /// The single overlay reducer — closes this surface on Esc / row tap / × via ``OverlayCoordinator/closeGlobalSearch()``.
    /// Only its methods are called here (no two-way binding), so a plain `let` reference suffices.
    let coordinator: OverlayCoordinator

    /// The transient query field — mirrors ``WorkspaceStore/globalSearchQuery`` (restored on appear) and writes
    /// back through ``WorkspaceStore/runGlobalSearch`` on every keystroke (live re-run, ES-E5-5).
    @State private var query = ""
    /// `Aa` / `.*` mirrors of the store's retained flags (restored on appear; a toggle re-runs).
    @State private var caseSensitive = false
    @State private var isRegex = false

    /// Pre-focuses the query field on appear so typing reaches it immediately (otty parity).
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            queryBar
            Rectangle()
                .fill(Otty.Line.divider)
                .frame(height: Otty.Metric.hairline)
            summaryLine
            resultsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Otty.Surface.window)
        .onAppear { restoreFromStore() }
        #if os(macOS)
            .onExitCommand { coordinator.closeGlobalSearch() }
        #else
            .onKeyPress(.escape, phases: .down) { _ in
                coordinator.closeGlobalSearch()
                return .handled
            }
        #endif
    }

    // MARK: - Query bar

    private var queryBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.secondary)
            TextField("Search across all tabs…", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: Otty.Typeface.body))
                .foregroundStyle(Otty.Text.primary)
                .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
                .focused($queryFocused)
            FindTogglePill(label: "Aa", isOn: caseSensitive, help: "Case sensitive") {
                caseSensitive.toggle()
                rerun()
            }
            FindTogglePill(label: ".*", isOn: isRegex, help: "Regex (ICU)") {
                isRegex.toggle()
                rerun()
            }
            OttyPlateButton(symbol: .xmark, help: "Close (Esc)") {
                coordinator.closeGlobalSearch()
            }
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 48)
    }

    // MARK: - Summary line (`N results — M tabs`)

    @ViewBuilder private var summaryLine: some View {
        if let results = store.globalSearch, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(results.summary)
                .font(.system(size: Otty.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(Otty.Text.secondary)
                .padding(.horizontal, Otty.Metric.space4)
                .padding(.vertical, Otty.Metric.space2)
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let groups = store.globalSearch?.groups ?? []
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                        groupHeader(group, ordinal: groupIndex + 1)
                        ForEach(Array(group.hits.enumerated()), id: \.offset) { _, hit in
                            hitRow(hit)
                        }
                    }
                }
            }
            .padding(.vertical, Otty.Metric.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The blank / no-match state: a hint when the query is empty, a "no results" line when it matched nothing.
    private var emptyState: some View {
        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Search every tab’s scrollback."
            : "No results.")
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Otty.Metric.space4)
    }

    // MARK: - Group header (one per tab/pane)

    private func groupHeader(_ group: GlobalSearchGroup, ordinal: Int) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Image(systemName: "macwindow")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
            Text(group.groupTitle)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            Spacer(minLength: Otty.Metric.space2)
            // The first nine groups carry the ⌘1…⌘9 select-tab hint (cosmetic — groups are in session → tab →
            // pane order, so the ordinal tracks the tab number for the leading tabs; matches global-search.png).
            if ordinal <= 9 {
                Text("⌘\(ordinal)")
                    .font(.system(size: Otty.Typeface.small, weight: .medium))
                    .foregroundStyle(Otty.Text.secondary)
                    .padding(.horizontal, Otty.Metric.space1)
                    .frame(minHeight: 18)
                    .background(
                        RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                            .fill(Otty.Surface.element),
                    )
            }
        }
        .padding(.horizontal, Otty.Metric.space4)
        .padding(.top, Otty.Metric.space3)
        .padding(.bottom, Otty.Metric.space1)
    }

    // MARK: - Hit row

    private func hitRow(_ hit: GlobalSearchHit) -> some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(highlightedExcerpt(hit))
                .font(.system(size: Otty.Typeface.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Otty.Metric.space2)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.tertiary)
        }
        .padding(.horizontal, Otty.Metric.space4)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { jump(to: hit) }
    }

    /// The excerpt (the full matched line) as an `AttributedString` with the matched run tinted amber + primary
    /// (the otty find highlight) and the rest muted. The hit's `highlight` is a UTF-16 column range pre-clamped
    /// into the excerpt by ``GlobalSearchController``; map it back onto the string and SLICE the excerpt into
    /// before / match / after so a surrogate-straddling range degrades to a flat excerpt rather than indexing
    /// out of bounds. Built by substring concatenation (no AttributedString index conversion) so it can't trap.
    private func highlightedExcerpt(_ hit: GlobalSearchHit) -> AttributedString {
        let excerpt = hit.excerpt
        let utf16 = excerpt.utf16
        guard let lowUTF16 = utf16
            .index(utf16.startIndex, offsetBy: hit.highlight.lowerBound, limitedBy: utf16.endIndex),
            let highUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: hit.highlight.upperBound,
                limitedBy: utf16.endIndex,
            ),
            let low = lowUTF16.samePosition(in: excerpt),
            let high = highUTF16.samePosition(in: excerpt),
            low <= high
        else {
            var flat = AttributedString(excerpt)
            flat.foregroundColor = Otty.Text.secondary
            return flat
        }
        var before = AttributedString(String(excerpt[excerpt.startIndex..<low]))
        before.foregroundColor = Otty.Text.secondary
        var match = AttributedString(String(excerpt[low..<high]))
        match.foregroundColor = Otty.Text.primary
        match.backgroundColor = Otty.Status.warn.opacity(0.35)
        var after = AttributedString(String(excerpt[high...]))
        after.foregroundColor = Otty.Text.secondary
        return before + match + after
    }

    // MARK: - Actions

    /// Two-way binding into the query field — read the live `@State`, write it through `runGlobalSearch` so each
    /// keystroke re-runs the cross-tab search (live results, ES-E5-5).
    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { query = $0
            rerun()
        })
    }

    private func rerun() {
        store.runGlobalSearch(query: query, caseSensitive: caseSensitive, isRegex: isRegex)
    }

    /// Restore the field + pills from the store's retained query/flags so a ⇧⌘F re-open shows the last search
    /// (E5 divergence #1). Does NOT re-run on its own — the store already holds the last results to display.
    private func restoreFromStore() {
        query = store.globalSearchQuery
        caseSensitive = store.globalSearchCaseSensitive
        isRegex = store.globalSearchRegex
        // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
        // dropped — defer one runloop hop (the palette / find-bar idiom).
        DispatchQueue.main.async { queryFocused = true }
    }

    private func jump(to hit: GlobalSearchHit) {
        store.jumpToGlobalSearchResult(hit)
        coordinator.closeGlobalSearch()
    }
}
#endif
