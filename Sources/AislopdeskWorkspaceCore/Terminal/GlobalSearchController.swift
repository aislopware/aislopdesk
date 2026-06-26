import Foundation

// MARK: - GlobalSearch (pure cross-pane find engine behind ⇧⌘F)

/// One searchable pane fed into ``GlobalSearchController/run(sources:query:caseSensitive:isRegex:)``: the
/// pane's tree identity (so a result row can jump back to the exact session → tab → pane) plus the flat
/// scrollback text mirror to scan. The store builds one per *live terminal* pane off
/// ``TerminalViewModel/searchScrollbackLines()``; a pane that never received bytes contributes `lines: []`
/// and is simply absent from the results (see the E5 plan, divergence #5).
public struct GlobalSearchSource: Equatable, Sendable {
    /// The join key back to the live-session registry (the pane to focus when a hit is clicked).
    public let paneID: PaneID
    /// The owning session (selected first on jump).
    public let sessionID: SessionID
    /// The owning tab within the session (selected second on jump).
    public let tabID: TabID
    /// The header shown above this source's hits — the owning tab/pane title (`find.png` group header).
    public let groupTitle: String
    /// One entry per scrollback line (no trailing newline) — the exact shape ``TerminalSearchController`` eats.
    public let lines: [String]

    public init(paneID: PaneID, sessionID: SessionID, tabID: TabID, groupTitle: String, lines: [String]) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.groupTitle = groupTitle
        self.lines = lines
    }
}

/// One found occurrence within a source, carried with everything a result row needs to render and to jump:
/// the source identity, the in-buffer location (`line`/`column`/`length`, UTF-16 code units, matching
/// ``TerminalSearchController/Match``), a ready-to-render `excerpt` (the full matched line), and the
/// `highlight` UTF-16 column range within that excerpt to tint amber (mirrors `find.png` / `global-search.png`).
public struct GlobalSearchHit: Equatable, Sendable {
    public let paneID: PaneID
    public let sessionID: SessionID
    public let tabID: TabID
    /// 0-based line index within the source's buffer.
    public let line: Int
    /// UTF-16 column offset of the match start within the line.
    public let column: Int
    /// UTF-16 length of the match.
    public let length: Int
    /// The full text of the matched line (the legible context shown in the result row).
    public let excerpt: String
    /// The UTF-16 sub-range of `excerpt` to highlight — clamped into the excerpt's bounds so it never
    /// constructs an invalid range (`column..<column+length`, bounded by the excerpt's UTF-16 count).
    public let highlight: Range<Int>

    public init(
        paneID: PaneID,
        sessionID: SessionID,
        tabID: TabID,
        line: Int,
        column: Int,
        length: Int,
        excerpt: String,
        highlight: Range<Int>,
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.line = line
        self.column = column
        self.length = length
        self.excerpt = excerpt
        self.highlight = highlight
    }
}

/// All hits from a single source, headed by its `groupTitle` (the otty "grouped by tab" header) and carrying
/// the source identity so the group header itself can jump. Only sources with ≥1 hit become a group.
public struct GlobalSearchGroup: Equatable, Sendable {
    public let groupTitle: String
    public let paneID: PaneID
    public let sessionID: SessionID
    public let tabID: TabID
    public let hits: [GlobalSearchHit]

    public init(groupTitle: String, paneID: PaneID, sessionID: SessionID, tabID: TabID, hits: [GlobalSearchHit]) {
        self.groupTitle = groupTitle
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.hits = hits
    }
}

/// The assembled global-search result set: the per-source `groups` (source order preserved, zero-hit sources
/// dropped), the flat `totalMatches` count, and the `tabCount` (number of groups). ``summary`` renders the
/// otty `N results — M tabs` line verbatim (em-dash separator — matches `global-search.png`).
public struct GlobalSearchResults: Equatable, Sendable {
    public let groups: [GlobalSearchGroup]
    public let totalMatches: Int
    public let tabCount: Int

    public init(groups: [GlobalSearchGroup], totalMatches: Int, tabCount: Int) {
        self.groups = groups
        self.totalMatches = totalMatches
        self.tabCount = tabCount
    }

    /// An empty result set (empty query / nothing matched) — the `nil`-equivalent the overlay renders blank.
    public static let empty = Self(groups: [], totalMatches: 0, tabCount: 0)

    /// The summary line shown beneath the query field: `"4 results — 3 tabs"` (em-dash, verbatim otty wording).
    public var summary: String { "\(totalMatches) results — \(tabCount) tabs" }
}

/// The PURE engine behind ⇧⌘F Global Search: it runs the proven ``TerminalSearchController/computeMatches``
/// over every live terminal pane's scrollback mirror and assembles the grouped, summarised results the
/// global-search surface renders. NO view, NO store, NO libghostty — the surface-collection glue (snapshotting
/// each pane's scrollback, the jump) lives in `WorkspaceStore`; THIS is the single, fully unit-testable core,
/// reusing the SAME match math as the in-pane find bar so the two never drift.
///
/// Behaviour (E5 WI-1):
/// - Reuses ``TerminalSearchController/computeMatches(lines:query:caseSensitive:isRegex:)`` per source —
///   no second matcher to keep in sync.
/// - Drops sources with zero hits; `tabCount` is therefore the number of surviving `groups`.
/// - Preserves source order (the store feeds sources in session → tab → pane order).
/// - Empty query ⇒ `.empty`. Invalid regex ⇒ `.empty` (inherits the controller's validate-then-drop; never traps).
public enum GlobalSearchController {
    /// Runs `query` across all `sources`, returning the grouped/summarised results. See the type docs above.
    public static func run(
        sources: [GlobalSearchSource],
        query: String,
        caseSensitive: Bool,
        isRegex: Bool,
    ) -> GlobalSearchResults {
        guard !query.isEmpty else { return .empty }

        var groups: [GlobalSearchGroup] = []
        var totalMatches = 0

        for source in sources {
            let matches = TerminalSearchController.computeMatches(
                lines: source.lines,
                query: query,
                caseSensitive: caseSensitive,
                isRegex: isRegex,
            )
            guard !matches.isEmpty else { continue } // zero-hit source ⇒ no group

            var hits: [GlobalSearchHit] = []
            hits.reserveCapacity(matches.count)
            for match in matches {
                // The excerpt is the FULL matched line (legible row context). `computeMatches` only ever
                // returns in-range line indices, but guard anyway — never index out of bounds on a hostile buffer.
                let excerpt = source.lines.indices.contains(match.line) ? source.lines[match.line] : ""
                // The highlight is `match`'s UTF-16 column range, clamped into the excerpt so a malformed
                // (start > end) range can never be constructed (which would trap).
                let utf16Len = excerpt.utf16.count
                let start = Swift.min(Swift.max(0, match.column), utf16Len)
                let end = Swift.min(Swift.max(start, match.column + match.length), utf16Len)
                hits.append(GlobalSearchHit(
                    paneID: source.paneID,
                    sessionID: source.sessionID,
                    tabID: source.tabID,
                    line: match.line,
                    column: match.column,
                    length: match.length,
                    excerpt: excerpt,
                    highlight: start..<end,
                ))
            }

            groups.append(GlobalSearchGroup(
                groupTitle: source.groupTitle,
                paneID: source.paneID,
                sessionID: source.sessionID,
                tabID: source.tabID,
                hits: hits,
            ))
            totalMatches += matches.count
        }

        return GlobalSearchResults(groups: groups, totalMatches: totalMatches, tabCount: groups.count)
    }

    /// E5 ES-E5-5 (click-to-line): the ORDERED libghostty surface-action sequence that lands the in-pane
    /// viewport on the CLICKED `hit` — arm the search (`search:<query>`) then advance to the hit's ORDINAL
    /// within ITS pane group so DISTINCT rows land DISTINCTLY: clicking the 10th hit in a pane issues 10
    /// `navigate_search:next`, not 1 (the half-delivered behaviour that made every row in a tab jump to the
    /// nearest match). The ordinal is the hit's 0-based index among its group's `hits` (which `run` builds in
    /// buffer order), so `index + 1` forward steps — the FIRST hit keeps the old single-step behaviour.
    ///
    /// Validate-then-drop: an empty `query` yields `[]` (nothing to arm). A `hit` absent from `results`
    /// (stale results vs. the clicked row) degrades to ordinal 0 (a single step) rather than trapping.
    public static func navigationActions(
        for hit: GlobalSearchHit,
        in results: GlobalSearchResults,
        query: String,
    ) -> [String] {
        guard !query.isEmpty else { return [] }
        let ordinal = results.groups
            .first { $0.paneID == hit.paneID && $0.sessionID == hit.sessionID && $0.tabID == hit.tabID }?
            .hits.firstIndex(of: hit) ?? 0
        var actions = ["search:\(query)"]
        actions.append(contentsOf: Array(repeating: "navigate_search:next", count: ordinal + 1))
        return actions
    }
}
