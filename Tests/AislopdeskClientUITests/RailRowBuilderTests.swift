// RailRowBuilderTests — pins the E6 WI-2 enrichment of `RailRow`: every rail row now carries the 1-based
// tab shortcut number (`#N`), the host-reported foreground-process label, and the single fused status badge
// from the pure `TabBadgeResolver`, in addition to the title/cwd-subtitle the filter narrows on.
//
// Headless: a tree-model `WorkspaceStore` over the tiny `MountTestPaneSession` fake (no socket, no video,
// no Metal/SCStream — per the hang-safety rule). The badge inputs are seeded through the store's PUBLIC
// mutators (`setAgentStatus` / `setCompletionBadge` / `setForegroundProcess`) so the test never touches a
// real `LivePaneSession`. Each assertion fails on the pre-WI-2 `RailRow` (which carried none of these
// fields), so none is tautological.

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class RailRowBuilderTests: XCTestCase {
    /// A headless tree-model store over the fake session (mirrors `OverlayCoordinatorMountTests`).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The pane id of the row at `index` in the freshly-built rail (the rows are rebuilt each call so a
    /// caller reads the LATEST derived value after seeding the store).
    private func paneID(_ store: WorkspaceStore, row index: Int) -> PaneID {
        RailRowsBuilder.rows(for: store)[index].id
    }

    // MARK: - `#N` (the tab shortcut number)

    /// Every row carries the 1-based index of its TAB within the session (the ⌘1…⌘9 target), in tab order.
    func testTabNumberIsOneBasedTabIndex() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // 2nd tab
        store.newTab(kind: .terminal, launchGrace: .zero) // 3rd tab
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 3, "one single-pane tab each → three rows")
        XCTAssertEqual(rows.map(\.tabNumber), [1, 2, 3], "tabNumber == tabIndex + 1 in tab order")
    }

    /// Both panes of a SPLIT tab share the SAME `#N` (it is a tab number, not a pane number — plan Design #1).
    func testSplitTabPanesShareTabNumber() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd tab so the split tab is `#1` and `#2` differ
        // Split the active tab into two panes.
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        // The split tab now contributes two rows; group rows by their tabID and assert each tab's rows share
        // one tabNumber.
        let byTab = Dictionary(grouping: rows, by: \.tabID)
        for (_, tabRows) in byTab {
            let numbers = Set(tabRows.map(\.tabNumber))
            XCTAssertEqual(numbers.count, 1, "all panes of a tab carry that tab's single #N")
        }
    }

    // MARK: - Badge fusion (the pure `TabBadgeResolver` reached through the row)

    /// A fresh pane (no agent status, no completion, no foreground process, idle shell) is all-clear → no badge.
    func testAllClearRowHasNoBadge() {
        let store = makeStore()
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].badge)
    }

    /// A blocked agent (`needsPermission`) surfaces the highest-urgency `.awaitingInput` badge.
    func testAwaitingInputBadgeFromBlockedAgent() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .awaitingInput)
    }

    /// A failed command (`.failure` completion) surfaces the `.error` badge.
    func testErrorBadgeFromFailureCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.failure, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .error)
    }

    /// A JUST-completed clean exit (`.success`) surfaces the brief `.completed` checkmark flash — the
    /// stamp is fresh (the rows build microseconds later, inside the flash window).
    func testCompletedBadgeFromFreshSuccessCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.success, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .completed)
    }

    /// A SETTLED clean exit (the `.success` landed longer ago than the flash window) surfaces the
    /// persistent `.finished` accent dot — proving otty's unread-output marker is reachable end-to-end
    /// through the rail (NOT a perpetual checkmark). The stamp is injected in the past so the row settles.
    func testFinishedAccentDotFromSettledSuccessCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        let stale = Date().addingTimeInterval(-(WorkspaceStore.completedFlashWindow + 5))
        store.setCompletionBadge(.success, for: pane, at: stale)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .finished)
    }

    /// Most-urgent wins: a blocked agent beats a failure completion on the same pane.
    func testAwaitingInputBeatsError() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.failure, for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .awaitingInput)
    }

    // MARK: - Foreground-process label + privilege badges

    /// The row mirrors the host-reported foreground process and classifies a `caffeinate` session (at rest)
    /// into the coffee badge.
    func testCaffeinateProcessLabelAndBadge() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("caffeinate", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "caffeinate")
        XCTAssertEqual(row.badge, .caffeinate)
    }

    /// A `sudo` foreground (by lowercased basename of a full path) classifies into the shield badge.
    func testSudoProcessBadgeByBasename() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("/usr/bin/sudo", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "/usr/bin/sudo", "the label is the verbatim host string")
        XCTAssertEqual(row.badge, .sudo)
    }

    /// A plain process (e.g. `zsh`) shows as the trailing label but is NOT a privilege badge.
    func testPlainProcessLabelNoBadge() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("/bin/zsh", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "/bin/zsh")
        XCTAssertNil(row.badge, "zsh is not in the privilege allow-set")
    }

    /// An empty / whitespace-only foreground name removes the mirror (treated as "no process").
    func testEmptyForegroundProcessClearsLabel() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("caffeinate", for: pane)
        store.setForegroundProcess("   ", for: pane)
        XCTAssertNil(store.paneForegroundProcess[pane])
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].processLabel)
    }

    /// A closed pane's foreground-process mirror is pruned on reconcile (no unbounded growth / stale label).
    func testForegroundProcessPrunedWhenTabCloses() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2)
        let pane = rows[1].id
        let tab = rows[1].tabID
        store.setForegroundProcess("caffeinate", for: pane)
        XCTAssertEqual(store.paneForegroundProcess[pane], "caffeinate")
        store.closeTab(tab)
        XCTAssertNil(
            store.paneForegroundProcess[pane],
            "a closed pane's foreground-process mirror must drop out on the reconcile prune",
        )
    }

    // MARK: - E17 WI-3: the read-only lock flag (sidebar indicator ⟂ pane pill, one source of truth)

    /// A row's `readOnly` mirrors the store's convergent ``WorkspaceStore/paneReadOnly`` set, so the sidebar
    /// lock glyph and the pane's `🔒 READ ONLY ×` pill read ONE truth. Locking the pane lights the flag;
    /// unlocking clears it. Fails on the pre-WI-3 `RailRow` (no `readOnly` field ⇒ won't compile) and on a
    /// build that derived the flag from anything but the store set (the assertion checks the row against the
    /// store's `isReadOnly(for:)`, not against its own input).
    func testReadOnlyFlagMirrorsTheStoreSet() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        XCTAssertFalse(RailRowsBuilder.rows(for: store)[0].readOnly, "a fresh pane is editable → no lock")

        store.setPaneReadOnly(pane, true)
        XCTAssertTrue(store.isReadOnly(for: pane), "the store recorded the lock in its convergent set")
        XCTAssertTrue(RailRowsBuilder.rows(for: store)[0].readOnly, "and the row surfaces it for the lock glyph")

        store.setPaneReadOnly(pane, false)
        XCTAssertFalse(RailRowsBuilder.rows(for: store)[0].readOnly, "unlocking clears the row flag")
    }

    /// The lock is strictly per-pane: locking one pane of a split tab leaves its sibling's row unlocked
    /// (faithful to otty's "splitting gives a fresh editable pane; the state does not propagate to siblings").
    func testReadOnlyFlagIsPerPane() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2, "the split tab contributes two pane rows")

        store.setPaneReadOnly(rows[0].id, true)
        let after = RailRowsBuilder.rows(for: store)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.readOnly ?? false, "the locked pane's row shows the lock")
        XCTAssertFalse(after.first { $0.id == rows[1].id }?.readOnly ?? true, "its sibling row stays unlocked")
    }

    // MARK: - cwd subtitle + the reused title+cwd filter

    /// The row's subtitle is the pane's last-known cwd, and `filtered` narrows by BOTH the title and the cwd.
    func testSubtitleCwdAndFilter() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].subtitle, "/Users/me/project-alpha")
        // Title match ("Terminal" contains "term").
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "term").count, rows.count)
        // cwd/subtitle match.
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "project-alpha").map(\.id), [pane])
        // No match anywhere.
        XCTAssertTrue(RailRowsBuilder.filtered(rows, query: "zzz-nope").isEmpty)
    }

    // MARK: - WI-5: `sectioned` (search filter × store-derived grouping → rendered sections)

    /// A three-tab store with two distinct project cwds. Tabs 1+2 share `…/alpha`, tab 3 is `…/beta`. Returns
    /// the store with its grouping left at the caller's choice (default `.none`).
    private func makeThreeProjectStore() -> WorkspaceStore {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 2
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 3
        let rows = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[0].id)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[1].id)
        store.setLastKnownCwd("/Users/me/beta", for: rows[2].id)
        return store
    }

    /// Ungrouped (`.none`) ⇒ exactly one header-less section carrying every row in tab order — byte-identical
    /// to the pre-E6 flat rail (a regression to a sectioned-when-ungrouped layout would fail this).
    func testSectionedFlatWhenUngrouped() {
        let store = makeThreeProjectStore()
        store.tabGrouping = .none
        let sections = RailRowsBuilder.sectioned(
            RailRowsBuilder.rows(for: store),
            groups: store.orderedTabGroups(),
            query: "",
        )
        XCTAssertEqual(sections.count, 1, ".none ⇒ one flat section")
        XCTAssertNil(sections[0].header, "the flat section carries no header chrome")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [1, 2, 3], "all rows, in tab order")
    }

    /// By-Project ⇒ the survivors bucket into the engine's project sections (basename headers); the two
    /// `…/alpha` tabs land together in section 1, the lone `…/beta` tab in section 2.
    func testSectionedByProjectBucketsRowsByEngineOrder() {
        let store = makeThreeProjectStore()
        store.tabGrouping = .byProject
        let sections = RailRowsBuilder.sectioned(
            RailRowsBuilder.rows(for: store),
            groups: store.orderedTabGroups(),
            query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "beta"], "section headers are the cwd basenames")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [1, 2], "both alpha tabs share section 1")
        XCTAssertEqual(sections[1].rows.map(\.tabNumber), [3], "the lone beta tab is section 2")
    }

    /// The search filter composes with grouping: a query that only matches the `beta` cwd drops the entire
    /// `alpha` section (no empty header survives). Fails on a naive map that kept zero-row sections.
    func testSectionedDropsEmptySectionAfterFilter() {
        let store = makeThreeProjectStore()
        store.tabGrouping = .byProject
        let sections = RailRowsBuilder.sectioned(
            RailRowsBuilder.rows(for: store),
            groups: store.orderedTabGroups(),
            query: "beta",
        )
        XCTAssertEqual(sections.map(\.header), ["beta"], "the alpha section filters out entirely → dropped")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [3])
    }
}
