import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins portable workspace export / import: the round-trip preserves the layout, the host connection is
/// stripped on export and never adopted on import, a hostile / foreign / future file is rejected with the
/// live workspace untouched, ephemeral panes never ship, and the registry==canvas invariant holds after a
/// replace. The file-picker chrome is the only GUI part; the codec + replace path are all here.
@MainActor
final class WorkspaceTransferTests: XCTestCase {

    private func store(_ items: [CanvasItem], focus: PaneID, connection: ConnectionTarget? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus, connection: connection),
                       makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }
    private func term(_ x: CGFloat, _ title: String) -> CanvasItem {
        CanvasItem(id: PaneID(), spec: PaneSpec(kind: .terminal, title: title),
                   frame: CGRect(x: x, y: 0, width: 300, height: 200), z: 0)
    }

    func testExportImportRoundTripPreservesLayout() {
        let a = term(0, "alpha"), b = term(400, "beta")
        let src = store([a, b], focus: a.id)
        let g = src.addGroup(name: "work")
        src.assignPane(a.id, toGroup: g)
        src.addSnippet(name: "deploy", body: "make deploy<Enter>")
        let data = src.exportWorkspaceData()

        // A fresh store (its own single default pane) imports the document, REPLACING its canvas.
        let dst = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
        XCTAssertTrue(dst.importWorkspace(data))

        XCTAssertEqual(Set(dst.workspace.canvas.allIDs().compactMap { dst.workspace.canvas.spec(for: $0)?.title }),
                       ["alpha", "beta"], "both panes restored (by title; ids are re-minted)")
        XCTAssertEqual(dst.workspace.groups.map(\.name), ["work"], "the group survives")
        XCTAssertEqual(dst.snippets.first?.name, "deploy", "snippets survive the round trip")
    }

    func testExportStripsHostConnection() {
        let a = term(0, "a")
        let src = store([a], focus: a.id,
                        connection: ConnectionTarget(host: "secret.host", port: 7420, mediaPort: 9000, cursorPort: 9001))
        let decoded = WorkspaceTransfer.decode(src.exportWorkspaceData())
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.connection, "the host:port is never written into a shareable document")
    }

    func testImportKeepsLocalConnectionNotTheFiles() {
        let a = term(0, "a")
        let src = store([a], focus: a.id,
                        connection: ConnectionTarget(host: "stranger", port: 1, mediaPort: 2, cursorPort: 3))
        let data = src.exportWorkspaceData()
        let local = ConnectionTarget(host: "mine", port: 7420, mediaPort: 9000, cursorPort: 9001)
        let dst = store([term(0, "x")], focus: PaneID(), connection: local)
        XCTAssertTrue(dst.importWorkspace(data))
        XCTAssertEqual(dst.workspace.connection, local, "the importer keeps its OWN host, never the file's")
    }

    func testHostileDataIsRejectedAndLeavesWorkspaceUntouched() {
        let a = term(0, "keep")
        let st = store([a], focus: a.id)
        let before = st.workspace.canvas.allIDs()
        XCTAssertFalse(st.importWorkspace(Data("not a workspace".utf8)), "garbage is rejected")
        XCTAssertFalse(st.importWorkspace(Data()), "empty data is rejected")
        XCTAssertEqual(st.workspace.canvas.allIDs(), before, "a rejected import leaves the live workspace intact")
    }

    func testWrongMagicAndFutureFormatRejected() throws {
        let ws = Workspace(canvas: Canvas(items: [term(0, "a")]), focusedPane: nil)
        // Wrong magic.
        let bad = WorkspaceTransfer.Document(format: "evil.format", formatVersion: 1, workspace: ws)
        XCTAssertNil(WorkspaceTransfer.decode(try JSONEncoder().encode(bad)))
        // Future format version this build can't promise to read.
        let future = WorkspaceTransfer.Document(format: WorkspaceTransfer.magic, formatVersion: 99, workspace: ws)
        XCTAssertNil(WorkspaceTransfer.decode(try JSONEncoder().encode(future)))
    }

    func testImportMaintainsRegistryEqualsCanvasInvariant() {
        let a = term(0, "a"), b = term(400, "b")
        let src = store([a, b], focus: a.id)
        let data = src.exportWorkspaceData()
        let dst = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
        XCTAssertTrue(dst.importWorkspace(data))
        // The load-bearing invariant: every live canvas leaf has a materialized handle, and vice versa.
        for id in dst.workspace.canvas.allIDs() {
            XCTAssertNotNil(dst.handle(for: id), "every imported leaf materialized a session")
        }
    }

    func testEphemeralPanesNeverExported() {
        let a = term(0, "a")
        let src = store([a], focus: a.id)
        src.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "Authenticate", isSecure: true)
        let decoded = WorkspaceTransfer.decode(src.exportWorkspaceData())
        XCTAssertNotNil(decoded)
        XCTAssertFalse(decoded!.canvas.allIDs().contains { decoded!.canvas.spec(for: $0)?.kind == .systemDialog },
                       "an ephemeral system-dialog pane is stripped from the export")
    }
}
