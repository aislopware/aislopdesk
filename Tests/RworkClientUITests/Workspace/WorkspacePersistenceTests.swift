import XCTest
@testable import RworkClientUI

/// Persistence is the contract that the workspace *is* its on-disk JSON (docs/22 §6): a
/// `Workspace` value encodes to a stable, reviewable shape and decodes back to an EQUAL value with
/// no live object in sight. These tests pin three things the design leans on:
///
/// 1. **Exact-inverse round-trip** — `Workspace → JSON → Workspace` is `==`, even for a deep tree
///    with deliberately non-even fractions (a divider drag must survive a relaunch byte-for-byte).
/// 2. **The discriminated wire shape** — the hand-written `PaneNode` Codable (see
///    `PaneNode+Codable.swift`) emits `"type":"leaf"|"split"` and nested `{"raw":"<uuid>"}` ids,
///    and decodes hand-built JSON of that shape. The shape is asserted directly, not just inferred
///    from round-tripping, because it is the human-reviewable, version-stable surface.
/// 3. **Decode-fail-loud → store fallback** — a corrupt tree (split arity mismatch, unknown
///    discriminator) THROWS, and an unrecognized `schemaVersion` is treated as un-restorable. The
///    pure layer's job is to fail cleanly; the store's fallback to ``Workspace/defaultWorkspace()``
///    is exercised here at the seam (decode throws → caller substitutes the default), which is the
///    behaviour docs/22 §6 specifies.
///
/// All pure & synchronous — no client, no store, no async.
final class WorkspacePersistenceTests: XCTestCase {

    // MARK: - Shared codecs

    /// A plain encoder/decoder pair — no key strategy, no formatting. The wire shape under test is
    /// the *default* JSON shape the store will actually persist; sorted keys only make the
    /// byte-stability assertion deterministic.
    private func makeEncoder(sortedKeys: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        if sortedKeys { enc.outputFormatting = [.sortedKeys] }
        return enc
    }
    private let decoder = JSONDecoder()

    // MARK: - Fixtures

    /// A leaf with a fully-populated terminal spec (so the optional `endpoint` is exercised by the
    /// round-trip, not just the `nil` default).
    private func terminalLeaf(_ id: PaneID, title: String, host: String = "10.0.0.2", port: UInt16 = 9000) -> PaneNode {
        .leaf(id, PaneSpec(kind: .terminal, title: title, endpoint: Endpoint(host: host, port: port)))
    }

    /// A leaf with a fully-populated remote-GUI spec (so the `video` optional + its `UInt32`
    /// window id round-trip).
    private func videoLeaf(_ id: PaneID, title: String) -> PaneNode {
        .leaf(id, PaneSpec(
            kind: .remoteGUI,
            title: title,
            video: VideoEndpoint(host: "10.0.0.3", mediaPort: 5000, cursorPort: 5001, windowID: 42, title: title)
        ))
    }

    // MARK: - 1. Round-trip equality

    /// The default workspace — the single most important value (it is both the fresh-launch state
    /// and the decode-failure fallback) — survives `encode → decode` `==`.
    func testDefaultWorkspaceRoundTripsEqual() throws {
        let original = Workspace.defaultWorkspace()
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(restored, original, "defaultWorkspace must be an exact round-trip")
        // And the fallback identity is what the design promises: one active terminal tab.
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.name, "Terminal")
        XCTAssertEqual(restored.activeTabID, restored.tabs.first?.id)
        XCTAssertEqual(restored.tabs.first?.root.leafCount, 1)
    }

    /// A multi-tab workspace with mixed pane kinds, populated endpoints, a zoomed pane, and a
    /// chosen active tab round-trips to an equal value — every field of every nested struct.
    func testMultiTabWorkspaceRoundTripsEqual() throws {
        let tab1ID = TabID()
        let pA = PaneID(), pB = PaneID()
        let tab1 = Tab(
            id: tab1ID,
            name: "Servers",
            root: .split(.horizontal, children: [
                terminalLeaf(pA, title: "build"),
                videoLeaf(pB, title: "desktop")
            ], fractions: [0.5, 0.5]),
            focusedPane: pB,
            zoomedPane: pB // exercise the non-nil zoom path
        )

        let tab2ID = TabID()
        let pC = PaneID()
        let tab2 = Tab(
            id: tab2ID,
            name: "Claude",
            root: .leaf(pC, PaneSpec(kind: .claudeCode, title: "agent", endpoint: Endpoint(host: "host", port: 22))),
            focusedPane: pC
        )

        let original = Workspace(tabs: [tab1, tab2], activeTabID: tab2ID)
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(restored, original)
        // Spot-check load-bearing identities survived (UUIDs, zoom, active selection).
        XCTAssertEqual(restored.activeTabID, tab2ID)
        XCTAssertEqual(restored.tabs[0].zoomedPane, pB)
        XCTAssertEqual(restored.tabs[0].focusedPane, pB)
        XCTAssertEqual(restored.schemaVersion, Workspace.currentSchemaVersion)
    }

    // MARK: - 2. Deep nesting + non-even fractions, byte-stable

    /// A deeply nested tree with deliberately NON-even, non-normalized-looking fractions (what a
    /// real divider drag produces) survives the round-trip exactly, AND the encoding is
    /// byte-stable: encoding the original and re-encoding the decoded value produce identical
    /// bytes. This is the guarantee a relaunch relies on — a saved layout reloads pixel-identical.
    func testDeepNestedNonEvenFractionsAreByteStable() throws {
        let p0 = PaneID(), p1 = PaneID(), p2 = PaneID(), p3 = PaneID(), p4 = PaneID()

        // horizontal[ leaf, vertical[ leaf, horizontal[ leaf, leaf ] ], leaf ]
        // with intentionally ugly fractions that do NOT come from `even(_:)`.
        let inner = PaneNode.split(.horizontal, children: [
            terminalLeaf(p2, title: "p2"),
            terminalLeaf(p3, title: "p3")
        ], fractions: [0.37, 0.63])

        let middle = PaneNode.split(.vertical, children: [
            terminalLeaf(p1, title: "p1"),
            inner
        ], fractions: [0.2222, 0.7778])

        let root = PaneNode.split(.horizontal, children: [
            terminalLeaf(p0, title: "p0"),
            middle,
            terminalLeaf(p4, title: "p4")
        ], fractions: [0.15, 0.55, 0.30])

        let tab = Tab(name: "Deep", root: root, focusedPane: p3)
        let original = Workspace(tabs: [tab], activeTabID: tab.id)

        // Round-trip equality first.
        let encoder = makeEncoder(sortedKeys: true)
        let data1 = try encoder.encode(original)
        let restored = try decoder.decode(Workspace.self, from: data1)
        XCTAssertEqual(restored, original, "deep non-even tree must round-trip exactly")

        // Byte-stability: re-encoding the decoded value yields identical bytes (sorted keys make
        // this a true byte compare, not just a value compare).
        let data2 = try encoder.encode(restored)
        XCTAssertEqual(data1, data2, "encode is an exact inverse of decode — byte-stable")

        // The exact fraction values survived (defensive: assert the leaf-level fraction did not
        // get re-evened or rounded by the codec).
        if case let .split(_, children, fractions) = restored.tabs[0].root {
            XCTAssertEqual(fractions, [0.15, 0.55, 0.30], accuracy: 1e-12)
            if case let .split(_, _, mid) = children[1] {
                XCTAssertEqual(mid, [0.2222, 0.7778], accuracy: 1e-12)
            } else {
                XCTFail("expected the middle child to remain a split")
            }
        } else {
            XCTFail("expected the root to remain a split after round-trip")
        }
    }

    // MARK: - 3. The discriminated wire shape (decode hand-built JSON)

    /// Decode a hand-authored JSON tree of the documented shape — `"type"` discriminator, nested
    /// `{"raw":"<uuid>"}` ids — and assert it reconstructs the exact tree. This pins the wire
    /// contract independently of the encoder (a reviewer / external tool can author this shape).
    func testDecodeHandBuiltDiscriminatedJSON() throws {
        let leafUUID = UUID()
        let siblingUUID = UUID()
        let json = """
        {
          "type": "split",
          "axis": "horizontal",
          "children": [
            { "type": "leaf",
              "id": { "raw": "\(leafUUID.uuidString)" },
              "spec": { "kind": "terminal", "title": "left" } },
            { "type": "leaf",
              "id": { "raw": "\(siblingUUID.uuidString)" },
              "spec": { "kind": "claudeCode", "title": "right" } }
          ],
          "fractions": [0.4, 0.6]
        }
        """
        let node = try decoder.decode(PaneNode.self, from: Data(json.utf8))

        let expected = PaneNode.split(.horizontal, children: [
            .leaf(PaneID(raw: leafUUID), PaneSpec(kind: .terminal, title: "left")),
            .leaf(PaneID(raw: siblingUUID), PaneSpec(kind: .claudeCode, title: "right"))
        ], fractions: [0.4, 0.6])

        XCTAssertEqual(node, expected, "hand-built discriminated JSON decodes to the documented tree")
    }

    /// Assert the *encoded* shape directly: a leaf encodes with `"type":"leaf"` and a nested
    /// `{"raw":...}` id; the recursive enum never leaks a synthesized, position-keyed shape.
    func testEncodedShapeUsesDiscriminatorAndNestedRawID() throws {
        let id = PaneID()
        let leaf = PaneNode.leaf(id, PaneSpec(kind: .terminal, title: "t"))
        let data = try makeEncoder().encode(leaf)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["type"] as? String, "leaf", "leaf carries the discriminator")
        let idObject = object?["id"] as? [String: Any]
        XCTAssertEqual(idObject?["raw"] as? String, id.raw.uuidString, "PaneID encodes as nested {raw:<uuid>}")
        XCTAssertNotNil(object?["spec"], "leaf carries its spec")
        XCTAssertNil(object?["children"], "a leaf has no children key")

        // And the split discriminator + parallel arrays.
        let split = PaneNode.split(.vertical, children: [leaf, leaf], fractions: [0.5, 0.5])
        let splitData = try makeEncoder().encode(split)
        let splitObject = try JSONSerialization.jsonObject(with: splitData) as? [String: Any]
        XCTAssertEqual(splitObject?["type"] as? String, "split")
        XCTAssertEqual(splitObject?["axis"] as? String, "vertical")
        XCTAssertEqual((splitObject?["children"] as? [Any])?.count, 2)
        XCTAssertEqual((splitObject?["fractions"] as? [Any])?.count, 2)
    }

    // MARK: - 4. Corruption guards (decode THROWS)

    /// A split whose `children.count != fractions.count` is corruption — the hand-written decoder
    /// throws `dataCorrupted` rather than letting an inconsistent tree reach the layout solver.
    func testSplitArityMismatchThrowsDataCorrupted() {
        let json = """
        {
          "type": "split",
          "axis": "horizontal",
          "children": [
            { "type": "leaf", "id": { "raw": "\(UUID().uuidString)" },
              "spec": { "kind": "terminal", "title": "only" } }
          ],
          "fractions": [0.5, 0.5]
        }
        """
        XCTAssertThrowsError(try decoder.decode(PaneNode.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    /// R8 #6: a split with ONE child has MATCHING arity (1 == 1) but violates the ≥2-children invariant
    /// every in-operation tree op maintains — left unchecked it would later trip `collapsing()`'s
    /// `precondition(!children.isEmpty)` and CRASH on the next close. The decoder must reject it so the
    /// store's decode-failure fallback (default workspace) fires.
    func testSingletonSplitThrowsDataCorrupted() {
        let json = """
        {
          "type": "split",
          "axis": "horizontal",
          "children": [
            { "type": "leaf", "id": { "raw": "\(UUID().uuidString)" },
              "spec": { "kind": "terminal", "title": "lonely" } }
          ],
          "fractions": [1.0]
        }
        """
        XCTAssertThrowsError(try decoder.decode(PaneNode.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    /// An unknown `"type"` discriminator value throws (the enum is closed; an unrecognized tag is
    /// corruption, decode-fail loudly).
    func testUnknownNodeTypeThrows() {
        let json = """
        { "type": "wormhole",
          "id": { "raw": "\(UUID().uuidString)" },
          "spec": { "kind": "terminal", "title": "x" } }
        """
        XCTAssertThrowsError(try decoder.decode(PaneNode.self, from: Data(json.utf8)))
    }

    // MARK: - 5. Schema-mismatch / corrupt JSON → default-workspace fallback

    /// The store-level contract (docs/22 §6): when persisted data cannot be restored — a corrupt
    /// payload that fails to decode, OR a `schemaVersion` this build does not recognize — the
    /// caller falls back to ``Workspace/defaultWorkspace()`` rather than crashing or surfacing an
    /// empty workspace. The pure layer's contribution is "decode throws / is detectably stale";
    /// the fallback substitution is exercised here at the exact seam.

    /// Decoding garbage throws; the fallback substitutes the single default terminal tab.
    /// (Compared by SHAPE, not `==`: `defaultWorkspace()` mints fresh UUIDs each call, so two
    /// instances are intentionally never `Equatable`-equal — the contract is the *structure*.)
    func testCorruptJSONFallsBackToDefaultWorkspace() {
        let corrupt = Data("{ this is not valid workspace json ".utf8)
        let restored = decodeOrDefault(corrupt)
        assertIsDefaultWorkspaceShape(restored, "undecodable payload → default workspace")
    }

    /// A future / unknown `schemaVersion` decodes structurally (the field is just an Int) but is
    /// un-restorable by this build: the version-aware loader rejects it and falls back to default.
    /// This pins the §6 forward-migration policy ("unknown version → default, never crash").
    func testUnknownSchemaVersionFallsBackToDefaultWorkspace() throws {
        // Build a structurally-valid workspace, then bump its schemaVersion past what we ship.
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        let data = try makeEncoder().encode(future)

        // It still decodes as a Workspace value (schemaVersion is a plain field)…
        let raw = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(raw.schemaVersion, Workspace.currentSchemaVersion + 99)

        // …but a version-aware load treats the unknown version as un-restorable → default.
        let restored = decodeOrDefault(data)
        assertIsDefaultWorkspaceShape(restored, "unknown schemaVersion → default workspace")
    }

    /// A current-version, well-formed payload is restored as-is by the same version-aware loader
    /// (the fallback only fires on failure / unknown version, never on a good load).
    func testCurrentVersionWellFormedPayloadIsRestoredNotReplaced() throws {
        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        let data = try makeEncoder().encode(original)
        let restored = decodeOrDefault(data)
        XCTAssertEqual(restored, original, "a good current-version payload is restored verbatim, not replaced")
        XCTAssertEqual(restored.tabs.count, 2)
    }

    // MARK: - 6. Schema migration seam (forward-migrate, never discard)

    /// `migrate(from:to:)` with `from == to` is the identity — a current-version value is returned
    /// unchanged (the v1-today fast path), not re-minted or normalized away. This is the property
    /// `load()` relies on to keep every existing payload byte-stable across the new seam.
    func testMigrationIdentityForCurrentVersion() {
        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        let migrated = WorkspaceSchemaMigration.migrate(original, from: Workspace.currentSchemaVersion)
        XCTAssertEqual(migrated, original, "from == to is the identity migration")
    }

    /// A payload written by a *newer* build (schemaVersion above what we ship) cannot be interpreted
    /// here: `migrate` returns `nil` so the caller can fall back to the default rather than guess.
    func testMigrationRejectsNewerThanCurrent() {
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 1
        let migrated = WorkspaceSchemaMigration.migrate(future, from: future.schemaVersion)
        XCTAssertNil(migrated, "a future schemaVersion is un-migratable → nil")
    }

    /// An older version with **no step** in the upgrade chain to bridge the gap is un-migratable:
    /// `migrate` returns `nil`. Probed below the seeded v0 step (a negative source version has no
    /// `n → n+1` entry), so the gap branch is exercised without depending on a future bump.
    func testMigrationRejectsUnknownGap() {
        // currentSchemaVersion is 1 and only the v0→v1 step is seeded. A source version of -1 has no
        // `-1 → 0` step, so the chain -1 → 0 → 1 hits a gap immediately.
        var ancient = Workspace.defaultWorkspace()
        ancient.schemaVersion = -1
        let migrated = WorkspaceSchemaMigration.migrate(ancient, from: ancient.schemaVersion)
        XCTAssertNil(migrated, "a gap in the upgrade chain is un-migratable → nil")
    }

    /// A v0 payload is **upgraded, not discarded**: `migrate(from: 0)` runs the seeded v0→v1 step and
    /// returns a current-version value. The step normalizes a missing/dangling `activeTabID` to the
    /// first tab, and the result is stamped to `currentSchemaVersion`.
    func testSimulatedV0UpgradesToV1() {
        // A v0-shaped value: real tabs, but activeTabID nil (the invariant v1 enforces) and the old
        // version stamp.
        let tab = Tab.make(kind: .terminal, title: "Terminal")
        var v0 = Workspace(schemaVersion: 0, tabs: [tab], activeTabID: nil)
        v0.schemaVersion = 0 // explicit: this is a v0 payload

        guard let migrated = WorkspaceSchemaMigration.migrate(v0, from: 0) else {
            return XCTFail("v0 must upgrade to v1, not be discarded")
        }
        XCTAssertEqual(migrated.schemaVersion, Workspace.currentSchemaVersion, "result is stamped to current")
        XCTAssertEqual(migrated.activeTabID, tab.id, "v0→v1 normalizes a missing activeTabID to the first tab")
        XCTAssertEqual(migrated.tabs, v0.tabs, "the tabs themselves are carried through unchanged")
    }

    // MARK: - 7. Real load() through the migration seam (end-to-end on disk)

    /// A current-version payload written to a temp file is restored **verbatim** by the real
    /// `WorkspacePersistence.load()` — the v1 → identity passthrough preserves all existing behaviour
    /// across the new migration seam (no re-mint, no normalization of a value that is already valid).
    func testLoadCurrentVersionPayloadIsRestoredVerbatimViaRealLoad() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        let original = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        try persistence.save(original)

        let loaded = persistence.load()
        XCTAssertEqual(loaded, original, "a current-version payload loads verbatim through the migrate seam")
        XCTAssertEqual(loaded.tabs.count, 2)
    }

    /// A future-version payload on disk falls back to the default via the real `load()`: the value
    /// decodes (schemaVersion is a plain Int) but `migrate` returns `nil`, and `load()` substitutes
    /// ``Workspace/defaultWorkspace()``. Asserted by SHAPE (defaults mint fresh UUIDs).
    func testLoadFutureVersionPayloadFallsBackViaRealLoad() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)

        let loaded = persistence.load()
        assertIsDefaultWorkspaceShape(loaded, "future schemaVersion on disk → default via real load()")
    }

    /// R13 #9 → UI/UX pass-3 #5: a corrupt persisted tree with a DUPLICATE leaf PaneID across tabs would
    /// collapse two panes onto one shared session (the registry is keyed 1:1 by PaneID). `load()` now
    /// RE-MINTS the duplicates in place — preserving the user's tabs/splits/endpoints — instead of nuking
    /// the whole workspace to a default (the original R13 behavior, which lost the layout).
    func testLoadDedupesDuplicateLeafPaneIDsPreservingLayout() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        let shared = PaneID()   // the SAME leaf id in two different tabs
        let t1 = Tab(name: "A", root: .leaf(shared, PaneSpec(kind: .terminal, title: "A")), focusedPane: shared)
        let t2 = Tab(name: "B", root: .leaf(shared, PaneSpec(kind: .terminal, title: "B")), focusedPane: shared)
        try persistence.save(Workspace(tabs: [t1, t2], activeTabID: t1.id))

        let loaded = persistence.load()
        XCTAssertEqual(loaded.tabs.count, 2, "the user's tabs are PRESERVED, not reset (R13 nuke → pass-3 re-mint)")
        let ids = loaded.tabs.flatMap { $0.root.allLeafIDs() }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate leaf ids are re-minted to be globally unique")
        for tab in loaded.tabs {
            XCTAssertTrue(tab.root.contains(tab.focusedPane), "each tab's focus points at a real (re-minted) leaf")
        }
    }

    /// UI/UX pass-3 #2: an unrestorable file (decode / migrate failure) is COPIED ASIDE to a `.corrupt`
    /// sidecar before `load()` returns the default — so the user's bytes survive the next `save()`'s atomic
    /// overwrite (worst case: a downgrade that would otherwise nuke a newer, perfectly-good layout).
    func testLoadCopiesUnrestorableFileAsideBeforeReset() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)

        assertIsDefaultWorkspaceShape(persistence.load(), "a future-version file → default")
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "the unrestorable file is copied aside, not silently destroyed")
    }

    /// A normal (restorable) load writes NO `.corrupt` sidecar.
    func testLoadDoesNotBackUpAGoodFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)
        try persistence.save(Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "x"))

        _ = persistence.load()
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a good load writes no backup")
    }

    /// R13 #13: a current-schema (v1) payload whose `activeTabID` dangles (points at a tab that does not
    /// exist) is repaired on load so the detail pane is never blank — repointed at the first tab.
    func testLoadRepairsDanglingActiveTabID() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        var corrupt = Workspace.defaultWorkspace().adding(kind: .claudeCode, title: "agent")
        corrupt.activeTabID = TabID()   // dangling — not any tab's id
        try persistence.save(corrupt)

        let loaded = persistence.load()
        XCTAssertNotNil(loaded.activeTab, "a dangling activeTabID is repaired so the detail pane isn't blank")
        XCTAssertEqual(loaded.activeTabID, loaded.tabs.first?.id, "repointed at the first tab")
        XCTAssertEqual(loaded.tabs.count, corrupt.tabs.count, "the tabs themselves are preserved")
    }

    /// R13: a restored tab whose `focusedPane` dangles (points at a leaf not in its tree) is repaired on
    /// load to the tab's first leaf, so keyboard focus is never pinned to a ghost pane (completes the
    /// dangling-activeTabID repair for the focus dimension).
    func testLoadRepairsDanglingFocusedPane() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)

        let realLeaf = PaneID()
        let ghost = PaneID()   // a pane id not present in the tree
        let tab = Tab(name: "A", root: .leaf(realLeaf, PaneSpec(kind: .terminal, title: "A")), focusedPane: ghost)
        try persistence.save(Workspace(tabs: [tab], activeTabID: tab.id))

        let loaded = persistence.load()
        XCTAssertEqual(loaded.tabs.first?.focusedPane, realLeaf,
                       "a dangling focusedPane is repaired to the tab's first leaf")
    }

    /// Creates a unique temp directory for an on-disk round-trip, registering a teardown that removes
    /// it. Keeps the real-`load()` tests hermetic (a fresh dir per test, no shared default location).
    private func makeTempDir(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Local store-fallback seam (mirrors the WorkspaceStore loader, later WF)

    /// The decode-with-fallback the store will own, reproduced here so WF2 can assert the policy
    /// without the store existing yet: decode → forward-migrate to this build's schema → default on
    /// any failure (un-migratable / future version, or a decode throw). Routed through the SAME
    /// ``WorkspaceSchemaMigration`` seam production uses, so this mirror stays faithful to `load()`
    /// (an older payload now upgrades instead of being discarded). Pure & synchronous.
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

    /// Asserts a workspace has the documented default *shape* — one active, current-version tab
    /// named "Terminal" holding a single focused `.terminal` leaf. Used instead of `==` against a
    /// fresh `defaultWorkspace()` because that factory mints new UUIDs on every call (its identity
    /// is deliberately non-deterministic; the contract is the structure, not the ids).
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
        XCTAssertEqual(tab.root.leafCount, 1, "default has exactly one leaf. \(message)", file: file, line: line)
        XCTAssertEqual(tab.zoomedPane, nil, "default is not zoomed. \(message)", file: file, line: line)
        guard case let .leaf(leafID, spec) = tab.root else {
            return XCTFail("default root must be a single leaf. \(message)", file: file, line: line)
        }
        XCTAssertEqual(spec.kind, .terminal, "default leaf is a terminal. \(message)", file: file, line: line)
        XCTAssertEqual(tab.focusedPane, leafID, "the single leaf is focused. \(message)", file: file, line: line)
    }
}

// MARK: - Float-array assertion helper

/// XCTAssertEqual for `[Double]` with a tolerance — fractions are floating point, so an exact `==`
/// over an array would be brittle even though the codec is byte-stable. A deliberate epsilon keeps
/// the geometry/fraction compares precise without false negatives.
private func XCTAssertEqual(
    _ lhs: [Double],
    _ rhs: [Double],
    accuracy: Double,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard lhs.count == rhs.count else {
        return XCTFail("count mismatch: \(lhs.count) != \(rhs.count). \(message())", file: file, line: line)
    }
    for (a, b) in zip(lhs, rhs) {
        XCTAssertEqual(a, b, accuracy: accuracy, message(), file: file, line: line)
    }
}
