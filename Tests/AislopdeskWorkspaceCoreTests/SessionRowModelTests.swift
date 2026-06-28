import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// The pure multi-session-switcher row derivation (E19 WI-5 / A32): ``SessionRowModel/rows(for:)`` projects
/// each ``Session`` to a flat `(id, name, active, tabCount)` row in sidebar order, marking exactly the
/// resolved active session. No store, no SwiftUI — the headless contract the switcher view renders.
final class SessionRowModelTests: XCTestCase {
    /// A session with `tabCount` single-leaf tabs and the matching spec side table (so the specs == leafIDs
    /// invariant holds at birth — built independently of the model under test).
    private func makeSession(name: String, tabCount: Int) -> Session {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for _ in 0..<tabCount {
            let pane = PaneID()
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "Terminal")
        }
        return Session(name: name, tabs: tabs, specs: specs)
    }

    // MARK: Active marking

    func testRowsMarkExactlyTheActiveSession() {
        let a = makeSession(name: "Alpha", tabCount: 1)
        let b = makeSession(name: "Beta", tabCount: 1)
        let c = makeSession(name: "Gamma", tabCount: 1)
        let tree = TreeWorkspace(sessions: [a, b, c], activeSessionID: b.id)

        let rows = SessionRowModel.rows(for: tree)

        XCTAssertEqual(rows.filter(\.active).count, 1, "exactly one row is active")
        XCTAssertEqual(rows.first(where: \.active)?.id, b.id, "the active row is the selected session")
        XCTAssertFalse(rows[0].active)
        XCTAssertTrue(rows[1].active)
        XCTAssertFalse(rows[2].active)
    }

    /// A `nil` (or stale) `activeSessionID` resolves through ``TreeWorkspace/activeSession`` to the first
    /// session, so the highlight matches where `selectSession` actually lands — never an all-inactive list.
    func testNilActiveSessionFallsBackToFirst() {
        let a = makeSession(name: "Alpha", tabCount: 1)
        let b = makeSession(name: "Beta", tabCount: 1)
        let tree = TreeWorkspace(sessions: [a, b], activeSessionID: nil)

        let rows = SessionRowModel.rows(for: tree)

        XCTAssertEqual(rows.filter(\.active).count, 1)
        XCTAssertEqual(rows.first(where: \.active)?.id, a.id)
    }

    // MARK: Order + names

    func testRowsPreserveSessionOrderAndNames() {
        let a = makeSession(name: "Alpha", tabCount: 1)
        let b = makeSession(name: "Beta", tabCount: 1)
        let c = makeSession(name: "Gamma", tabCount: 1)
        let tree = TreeWorkspace(sessions: [a, b, c], activeSessionID: a.id)

        let rows = SessionRowModel.rows(for: tree)

        XCTAssertEqual(rows.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(rows.map(\.name), ["Alpha", "Beta", "Gamma"])
    }

    // MARK: Per-session tab count

    func testRowsReportPerSessionTabCount() {
        let a = makeSession(name: "Alpha", tabCount: 1)
        let b = makeSession(name: "Beta", tabCount: 3)
        let c = makeSession(name: "Gamma", tabCount: 2)
        let tree = TreeWorkspace(sessions: [a, b, c], activeSessionID: a.id)

        let rows = SessionRowModel.rows(for: tree)

        XCTAssertEqual(rows.map(\.tabCount), [1, 3, 2])
    }

    // MARK: Empty workspace

    func testEmptyWorkspaceYieldsEmptyRows() {
        let tree = TreeWorkspace(sessions: [], activeSessionID: nil)
        XCTAssertTrue(SessionRowModel.rows(for: tree).isEmpty)
    }
}
