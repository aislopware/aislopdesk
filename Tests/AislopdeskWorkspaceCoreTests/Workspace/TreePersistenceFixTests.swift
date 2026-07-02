import XCTest
@testable import AislopdeskWorkspaceCore

/// Pins the persistence-cluster fixes for the SHIPPED tree app (`liveModel: .tree`): snippets CRUD/read
/// persist + reload on the tree (not the dead canvas), `runSnippet` reaches the tree's focused leaf, and
/// workspace export/import round-trips the REAL tree. Before the fix all three targeted the retained-but-
/// dead canvas `Workspace.defaultWorkspace()`, so snippets vanished on relaunch, snippets ran into a
/// non-registry pane id, and export wrote an empty default while import silently no-oped.
@MainActor
final class TreePersistenceFixTests: XCTestCase {
    // MARK: - Fixtures

    private func singlePaneTree(spec: PaneSpec = PaneSpec(kind: .terminal, title: "Terminal")) -> TreeWorkspace {
        .singlePane(spec: spec)
    }

    private func treeStore(
        _ restoringTree: TreeWorkspace? = nil,
        persistence: WorkspacePersistence? = nil,
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
            persistence: persistence,
        )
    }

    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    private func bytes(_ store: WorkspaceStore, _ id: PaneID) -> [[UInt8]] {
        (store.handle(for: id) as? FakePaneSession)?.sentBytes ?? []
    }

    // MARK: - Bug 1: snippets CRUD persists on the tree + reloads

    func testSnippetCRUDMutatesTheTreeAndReadsBack() {
        let st = treeStore()
        let s = st.addSnippet(name: "deploy", body: "make deploy<Enter>", alias: "dp")
        XCTAssertEqual(st.snippets.map(\.name), ["deploy"], "the accessor reads the live TREE snippets")
        XCTAssertEqual(st.tree.snippets.map(\.name), ["deploy"], "the CRUD wrote the TREE (what save persists)")

        st.updateSnippet(s.id, name: "deploy-prod", body: "make deploy ENV=prod<Enter>")
        XCTAssertEqual(st.snippets.first?.name, "deploy-prod")
        XCTAssertEqual(st.tree.snippets.first?.body, "make deploy ENV=prod<Enter>")

        st.deleteSnippet(s.id)
        XCTAssertTrue(st.snippets.isEmpty)
        XCTAssertTrue(st.tree.snippets.isEmpty)
    }

    func testSnippetsSurviveAPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("workspace.json"))

        let st = treeStore(persistence: persistence)
        st.addSnippet(name: "deploy", body: "make deploy<Enter>", alias: "dp")
        st.saveImmediately()

        // A relaunch: a fresh store seeded from the reloaded tree must still carry the snippet.
        let reloaded = persistence.loadTree()
        let st2 = treeStore(reloaded, persistence: persistence)
        XCTAssertEqual(st2.snippets.map(\.name), ["deploy"], "the saved snippet reloads on the next launch")
        XCTAssertEqual(st2.snippets.first?.alias, "dp", "its alias reloads too")
    }

    // MARK: - Bug 3: runSnippet reaches the tree's focused leaf

    func testRunSnippetSendsToTheTreeFocusedPane() {
        let st = treeStore()
        guard let focused = activePane(st) else { XCTFail("no active pane")
            return
        }
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        let n = st.runSnippet(s.id)
        XCTAssertEqual(n, 1, "reached the tree's focused, materialized leaf")
        XCTAssertEqual(bytes(st, focused), [Array("uptime".utf8) + [0x0D]], "the macro was typed into the focused pane")
    }

    func testBeginRunSnippetRunsImmediatelyOnTheTree() {
        let st = treeStore()
        guard let focused = activePane(st) else { XCTFail("no active pane")
            return
        }
        let s = st.addSnippet(name: "u", body: "uptime<Enter>")
        XCTAssertEqual(st.beginRunSnippet(s.id), .ran(1))
        XCTAssertEqual(bytes(st, focused), [Array("uptime".utf8) + [0x0D]])
    }

    // MARK: - Bug 2: export serializes the REAL tree; import applies it

    func testExportImportRoundTripPreservesTheTree() {
        let src = treeStore()
        // Build a real workspace: rename the session, add a tab, add a snippet.
        src.renameSession(src.tree.activeSessionID ?? SessionID(), to: "Project")
        src.newTab(kind: .terminal)
        src.addSnippet(name: "deploy", body: "make deploy<Enter>")
        let tabCount = src.tree.activeSession?.tabs.count ?? 0
        XCTAssertGreaterThanOrEqual(tabCount, 2, "precondition: a real multi-tab session")

        let data = src.exportWorkspaceData()

        // A fresh tree store imports the document, REPLACING its default single-pane tree.
        let dst = treeStore()
        XCTAssertTrue(dst.importWorkspace(data), "the tree document imports")
        XCTAssertEqual(dst.tree.activeSession?.name, "Project", "the session name survived the round trip")
        XCTAssertEqual(dst.tree.activeSession?.tabs.count, tabCount, "the tabs survived")
        XCTAssertEqual(dst.snippets.map(\.name), ["deploy"], "the snippets survived")
        // Every imported leaf materialized a live session (registry == tree invariant).
        for id in dst.tree.allPaneIDs() {
            XCTAssertNotNil(dst.handle(for: id), "every imported leaf materialized a session")
        }
    }

    func testImportRejectsHostileBytesLeavingTreeUntouched() {
        let st = treeStore()
        let before = st.tree.allPaneIDs()
        XCTAssertFalse(st.importWorkspace(Data("not a workspace".utf8)), "garbage is rejected")
        XCTAssertFalse(st.importWorkspace(Data()), "empty data is rejected")
        // A canvas document must NOT import into the tree app (distinct magic).
        let canvasDoc = WorkspaceTransfer.export(Workspace.defaultWorkspace())
        XCTAssertFalse(st.importWorkspace(canvasDoc), "a foreign (canvas) document is rejected")
        XCTAssertEqual(st.tree.allPaneIDs(), before, "a rejected import leaves the live tree intact")
    }

    func testExportStripsPerSessionConnection() throws {
        var tree = singlePaneTree()
        tree.sessions[0].connection = ConnectionTarget(host: "secret", port: 7420, mediaPort: 9000, cursorPort: 9001)
        let st = treeStore(tree)
        let decoded = try XCTUnwrap(WorkspaceTransfer.decodeTree(st.exportWorkspaceData()))
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.connection == nil }, "host:port is never exported")
    }

    func testImportReMintsIDsSoASameSessionReImportDoesNotCollide() {
        let st = treeStore()
        let originalPanes = Set(st.tree.allPaneIDs())
        let data = st.exportWorkspaceData()
        XCTAssertTrue(st.importWorkspace(data), "re-import into the SAME store")
        XCTAssertTrue(
            Set(st.tree.allPaneIDs()).isDisjoint(with: originalPanes),
            "every imported pane id is re-minted (no collision with the live registry)",
        )
    }

    func testTreeDocumentRoundTripThroughDecodeTree() throws {
        var tree = singlePaneTree()
        tree.snippets = [Snippet(name: "g", body: "git status<Enter>")]
        let data = WorkspaceTransfer.exportTree(tree)
        let decoded = try XCTUnwrap(WorkspaceTransfer.decodeTree(data), "a current-version tree document round-trips")
        XCTAssertEqual(decoded.snippets.first?.name, "g")
        XCTAssertEqual(decoded.schemaVersion, TreeWorkspace.currentSchemaVersion)
    }
}
