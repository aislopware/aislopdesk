import XCTest
import CoreGraphics
@testable import RworkClientUI

/// Persistence is the contract that the workspace *is* its on-disk JSON (docs/30 §4): a `Workspace`
/// value (now holding a flat ``Canvas`` per tab) encodes to a stable, reviewable shape and decodes back
/// to an EQUAL value with no live object in sight. Pins:
///
/// 1. **Exact-inverse round-trip** — `Workspace → JSON → Workspace` is `==`, for a multi-tab workspace
///    with mixed kinds, populated endpoints, a maximized pane, a panned camera, and explicit z/frames.
/// 2. **Byte-stability** — re-encoding a decoded value yields identical bytes (a saved canvas reloads
///    pixel-identical: positions, sizes, camera, z all survive).
/// 3. **Canvas decode invariants** — a zero-item canvas THROWS (corruption → store fallback), and a
///    sub-minimum / degenerate frame is sanitized to ``Canvas/minItemSize`` on decode.
/// 4. **Schema fallback + the migration seam** — corrupt JSON / an unknown `schemaVersion` fall back to
///    ``Workspace/defaultWorkspace()``; a current (v2) payload is restored verbatim.
/// 5. **Real `load()`** — end-to-end on disk: verbatim restore, future-version → default + `.corrupt`
///    sidecar, duplicate-id re-mint, dangling activeTabID / focusedPane repair.
///
/// (The app has no released persisted format, so there is no backward-compat migration to test — an
/// older, incompatible on-disk shape simply fails to decode and falls back to the default.)
final class WorkspacePersistenceTests: XCTestCase {

    // MARK: - Shared codecs

    private func makeEncoder(sortedKeys: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        if sortedKeys { enc.outputFormatting = [.sortedKeys] }
        return enc
    }
    private let decoder = JSONDecoder()

    // MARK: - Fixtures

    private func terminalItem(_ id: PaneID, title: String, frame: CGRect, z: Int) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: .terminal, title: title, endpoint: Endpoint(host: "10.0.0.2", port: 9000)), frame: frame, z: z)
    }
    private func videoItem(_ id: PaneID, title: String, frame: CGRect, z: Int) -> CanvasItem {
        CanvasItem(
            id: id,
            spec: PaneSpec(kind: .remoteGUI, title: title,
                           video: VideoEndpoint(host: "10.0.0.3", mediaPort: 5000, cursorPort: 5001, windowID: 42, title: title)),
            frame: frame, z: z
        )
    }

    // MARK: - 1. Round-trip equality

    func testDefaultWorkspaceRoundTripsEqual() throws {
        let original = Workspace.defaultWorkspace()
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(restored, original, "defaultWorkspace must be an exact round-trip")
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.name, "Terminal")
        XCTAssertEqual(restored.activeTabID, restored.tabs.first?.id)
        XCTAssertEqual(restored.tabs.first?.canvas.itemCount, 1)
    }

    func testMultiTabCanvasWorkspaceRoundTripsEqual() throws {
        let tab1ID = TabID()
        let pA = PaneID(), pB = PaneID()
        let tab1 = Tab(
            id: tab1ID,
            name: "Servers",
            canvas: Canvas(
                items: [
                    terminalItem(pA, title: "build", frame: CGRect(x: -120, y: 40, width: 700, height: 460), z: 0),
                    videoItem(pB, title: "desktop", frame: CGRect(x: 800, y: 300, width: 900, height: 600), z: 1),
                ],
                camera: CanvasCamera(origin: CGPoint(x: -50, y: 120))
            ),
            focusedPane: pB,
            maximizedPane: pB   // exercise the non-nil maximize path
        )

        let tab2ID = TabID()
        let pC = PaneID()
        let tab2 = Tab(
            id: tab2ID,
            name: "Claude",
            canvas: Canvas(items: [
                CanvasItem(id: pC, spec: PaneSpec(kind: .claudeCode, title: "agent", endpoint: Endpoint(host: "host", port: 22)),
                           frame: CGRect(x: 0, y: 0, width: 640, height: 420), z: 0),
            ]),
            focusedPane: pC
        )

        let original = Workspace(tabs: [tab1, tab2], activeTabID: tab2ID)
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.activeTabID, tab2ID)
        XCTAssertEqual(restored.tabs[0].maximizedPane, pB)
        XCTAssertEqual(restored.tabs[0].focusedPane, pB)
        XCTAssertEqual(restored.tabs[0].canvas.camera.origin, CGPoint(x: -50, y: 120), "camera pan survives")
        XCTAssertEqual(restored.tabs[0].canvas.frame(of: pA), CGRect(x: -120, y: 40, width: 700, height: 460), "item frame survives")
        XCTAssertEqual(restored.schemaVersion, Workspace.currentSchemaVersion)
        XCTAssertEqual(restored.schemaVersion, 2)
    }

    // MARK: - 2. Byte-stability

    func testCanvasIsByteStable() throws {
        let p0 = PaneID(), p1 = PaneID()
        let tab = Tab(
            name: "Deep",
            canvas: Canvas(
                items: [
                    terminalItem(p0, title: "p0", frame: CGRect(x: 12.5, y: -33.25, width: 643, height: 421), z: 5),
                    terminalItem(p1, title: "p1", frame: CGRect(x: 700.75, y: 100, width: 800, height: 500), z: 9),
                ],
                camera: CanvasCamera(origin: CGPoint(x: 17.5, y: -8.25))
            ),
            focusedPane: p0
        )
        let original = Workspace(tabs: [tab], activeTabID: tab.id)

        let encoder = makeEncoder(sortedKeys: true)
        let data1 = try encoder.encode(original)
        let restored = try decoder.decode(Workspace.self, from: data1)
        XCTAssertEqual(restored, original, "canvas must round-trip exactly")

        let data2 = try encoder.encode(restored)
        XCTAssertEqual(data1, data2, "encode is an exact inverse of decode — byte-stable")

        // The exact z + frame survived (no re-mint / reorder / round).
        XCTAssertEqual(restored.tabs[0].canvas.item(p0)?.z, 5)
        XCTAssertEqual(restored.tabs[0].canvas.item(p1)?.z, 9)
        XCTAssertEqual(restored.tabs[0].canvas.frame(of: p1)?.origin.x ?? 0, 700.75, accuracy: 1e-9)
    }

    // MARK: - 3. Canvas decode invariants

    /// A zero-item canvas is corruption — the defensive `Canvas.init(from:)` throws so the store's
    /// decode-failure fallback fires (mirrors the legacy split's `children.count >= 2` guard).
    func testZeroItemCanvasThrows() {
        let json = """
        { "camera": { "origin": { "x": 0, "y": 0 } }, "items": [] }
        """
        XCTAssertThrowsError(try decoder.decode(Canvas.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    /// A sub-minimum frame is sanitized to ``Canvas/minItemSize`` on decode (a degenerate frame must
    /// never reach the layout).
    func testSubMinimumFrameIsSanitizedOnDecode() throws {
        let id = PaneID()
        let json = """
        {
          "camera": { "origin": { "x": 0, "y": 0 } },
          "items": [
            { "id": { "raw": "\(id.raw.uuidString)" }, "z": 0,
              "frame": { "origin": {"x": 1, "y": 2}, "size": {"width": 5, "height": 5} },
              "spec": { "kind": "terminal", "title": "tiny" } }
          ]
        }
        """
        let canvas = try decoder.decode(Canvas.self, from: Data(json.utf8))
        XCTAssertEqual(canvas.frame(of: id)?.size, Canvas.minItemSize, "sub-minimum size floored to minItemSize")
        XCTAssertEqual(canvas.frame(of: id)?.origin, CGPoint(x: 1, y: 2), "origin preserved")
    }

    /// A canvas without a `camera` key decodes to the zero camera (forward-compatible).
    func testMissingCameraDecodesToZero() throws {
        let id = PaneID()
        let json = """
        { "items": [ { "id": { "raw": "\(id.raw.uuidString)" }, "z": 0,
          "frame": { "origin": {"x":0,"y":0}, "size": {"width":640,"height":420} },
          "spec": { "kind": "terminal", "title": "t" } } ] }
        """
        let canvas = try decoder.decode(Canvas.self, from: Data(json.utf8))
        XCTAssertEqual(canvas.camera, .zero)
    }

    // MARK: - 4. Schema-mismatch / corrupt JSON → default-workspace fallback

    func testCorruptJSONFallsBackToDefaultWorkspace() {
        let corrupt = Data("{ this is not valid workspace json ".utf8)
        let restored = decodeOrDefault(corrupt)
        assertIsDefaultWorkspaceShape(restored, "undecodable payload → default workspace")
    }

    func testUnknownSchemaVersionFallsBackToDefaultWorkspace() throws {
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        let data = try makeEncoder().encode(future)
        let raw = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(raw.schemaVersion, Workspace.currentSchemaVersion + 99)
        let restored = decodeOrDefault(data)
        assertIsDefaultWorkspaceShape(restored, "unknown schemaVersion → default workspace")
    }

    func testCurrentVersionWellFormedPayloadIsRestoredNotReplaced() throws {
        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        let data = try makeEncoder().encode(original)
        let restored = decodeOrDefault(data)
        XCTAssertEqual(restored, original, "a good current-version payload is restored verbatim, not replaced")
        XCTAssertEqual(restored.tabs.count, 2)
    }

    // MARK: - 5. Schema migration seam (the value-level seam; v1/v0 are handled pre-decode)

    func testMigrationIdentityForCurrentVersion() {
        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        let migrated = WorkspaceSchemaMigration.migrate(original, from: Workspace.currentSchemaVersion)
        XCTAssertEqual(migrated, original, "from == to is the identity migration")
    }

    func testMigrationRejectsNewerThanCurrent() {
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 1
        let migrated = WorkspaceSchemaMigration.migrate(future, from: future.schemaVersion)
        XCTAssertNil(migrated, "a future schemaVersion is un-migratable → nil")
    }

    func testMigrationRejectsUnknownGap() {
        var ancient = Workspace.defaultWorkspace()
        ancient.schemaVersion = -1
        let migrated = WorkspaceSchemaMigration.migrate(ancient, from: ancient.schemaVersion)
        XCTAssertNil(migrated, "a gap in the upgrade chain is un-migratable → nil")
    }

    /// The seeded v0→v1 value-step still bridges 0→1 in isolation (legacy v0/v1 files now take the
    /// pre-decode `WorkspaceV1Migration` branch, but the step is retained + harmless).
    func testV0ToV1StepStillBridgesInIsolation() {
        let tab = Tab.make(kind: .terminal, title: "Terminal")
        let v0 = Workspace(schemaVersion: 0, tabs: [tab], activeTabID: nil)
        guard let migrated = WorkspaceSchemaMigration.migrate(v0, from: 0, to: 1) else {
            return XCTFail("the v0→v1 step must still bridge in isolation")
        }
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertEqual(migrated.activeTabID, tab.id, "v0→v1 normalizes a missing activeTabID to the first tab")
    }

    // MARK: - 6. Real load() through the persistence + migration seam (end-to-end on disk)

    func testLoadCurrentVersionPayloadIsRestoredVerbatimViaRealLoad() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        try persistence.save(original)
        XCTAssertEqual(persistence.load(), original, "a current-version payload loads verbatim")
    }

    func testLoadFutureVersionPayloadFallsBackViaRealLoad() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)
        assertIsDefaultWorkspaceShape(persistence.load(), "future schemaVersion on disk → default via real load()")
    }

    /// A corrupt persisted canvas with a DUPLICATE pane id across tabs is RE-MINTED in place (the
    /// registry is keyed 1:1 by PaneID) — the user's tabs are preserved, not nuked.
    func testLoadDedupesDuplicatePaneIDsPreservingLayout() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let shared = PaneID()
        let t1 = Tab.canvasTab(name: "A", panes: [(shared, PaneSpec(kind: .terminal, title: "A"))])
        let t2 = Tab.canvasTab(name: "B", panes: [(shared, PaneSpec(kind: .terminal, title: "B"))])
        try persistence.save(Workspace(tabs: [t1, t2], activeTabID: t1.id))

        let loaded = persistence.load()
        XCTAssertEqual(loaded.tabs.count, 2, "the user's tabs are PRESERVED, not reset")
        let ids = loaded.tabs.flatMap { $0.canvas.allIDs() }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids re-minted to be globally unique")
        for tab in loaded.tabs {
            XCTAssertTrue(tab.canvas.contains(tab.focusedPane), "each tab's focus points at a real (re-minted) pane")
        }
    }

    func testLoadCopiesUnrestorableFileAsideBeforeReset() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)
        assertIsDefaultWorkspaceShape(persistence.load(), "a future-version file → default")
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unrestorable file is copied aside")
    }

    func testLoadDoesNotBackUpAGoodFile() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        try persistence.save(Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "x"))
        _ = persistence.load()
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a good load writes no backup")
    }

    func testLoadRepairsDanglingActiveTabID() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var corrupt = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        corrupt.activeTabID = TabID()   // dangling
        try persistence.save(corrupt)
        let loaded = persistence.load()
        XCTAssertNotNil(loaded.activeTab, "a dangling activeTabID is repaired")
        XCTAssertEqual(loaded.activeTabID, loaded.tabs.first?.id, "repointed at the first tab")
    }

    func testLoadRepairsDanglingFocusedPane() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let realPane = PaneID()
        let ghost = PaneID()
        let tab = Tab(name: "A",
                      canvas: Canvas(items: [CanvasItem(id: realPane, spec: PaneSpec(kind: .terminal, title: "A"),
                                                        frame: CGRect(x: 0, y: 0, width: 640, height: 420), z: 0)]),
                      focusedPane: ghost)
        try persistence.save(Workspace(tabs: [tab], activeTabID: tab.id))
        let loaded = persistence.load()
        XCTAssertEqual(loaded.tabs.first?.focusedPane, realPane, "a dangling focusedPane is repaired to the first pane")
    }

    // MARK: - Helpers

    private func tempURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("workspace.json")
    }

    /// The decode-with-fallback mirror for the value-level schema-seam tests (the real `load()` adds the
    /// pre-decode v1 reshape — covered by `WorkspaceV1MigrationTests`). Decodes a v2 `Workspace`,
    /// forward-migrates, defaults on any failure.
    private func decodeOrDefault(_ data: Data) -> Workspace {
        do {
            let candidate = try decoder.decode(Workspace.self, from: data)
            guard let migrated = WorkspaceSchemaMigration.migrate(candidate, from: candidate.schemaVersion) else {
                return .defaultWorkspace()
            }
            return migrated
        } catch {
            return .defaultWorkspace()
        }
    }

    private func assertIsDefaultWorkspaceShape(
        _ ws: Workspace,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(ws.schemaVersion, Workspace.currentSchemaVersion, message, file: file, line: line)
        XCTAssertEqual(ws.tabs.count, 1, message, file: file, line: line)
        guard let tab = ws.tabs.first else {
            return XCTFail("default workspace must have one tab. \(message)", file: file, line: line)
        }
        XCTAssertEqual(tab.name, "Terminal", message, file: file, line: line)
        XCTAssertEqual(ws.activeTabID, tab.id, "the single tab is active. \(message)", file: file, line: line)
        XCTAssertEqual(tab.canvas.itemCount, 1, "default has exactly one pane. \(message)", file: file, line: line)
        XCTAssertEqual(tab.maximizedPane, nil, "default is not maximized. \(message)", file: file, line: line)
        guard let item = tab.canvas.items.first else {
            return XCTFail("default canvas must have one item. \(message)", file: file, line: line)
        }
        XCTAssertEqual(item.spec.kind, .terminal, "default pane is a terminal. \(message)", file: file, line: line)
        XCTAssertEqual(tab.focusedPane, item.id, "the single pane is focused. \(message)", file: file, line: line)
    }
}
