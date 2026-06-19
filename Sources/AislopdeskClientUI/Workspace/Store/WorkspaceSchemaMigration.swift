import Foundation

// MARK: - Workspace schema migration (single-user: NO backward-compat path)

/// The version-aware seam between a decoded ``Workspace`` value and the shape this build understands
/// (docs/22 §6). `WorkspacePersistence.load()` decodes the raw JSON into a `Workspace` and asks this
/// enum to bring it up to ``Workspace/currentSchemaVersion``.
///
/// ### Single-user → no migration path (docs/31)
/// Aislopdesk has exactly one user and no released persisted format, so there is deliberately NO
/// backward-compatibility migration: an older on-disk shape simply fails to decode (or migrates to
/// `nil` here) and `load()` resets to ``Workspace/defaultWorkspace()`` (preserving the old file aside
/// as a `.corrupt` sidecar). The function is kept as a thin, total seam so the load path stays
/// uniform and a *future* version is detected (not crashed on).
///
/// ### Contract
/// `migrate(_:from:to:)` is a TOTAL, pure function — no IO, no force-unwrap, no throw:
/// - `from == to` → identity (the current-version fast path).
/// - `from != to` → `nil` (there are no upgrade steps; the caller resets to default). This covers both
///   an older shape (no step to climb) and a future version this build cannot interpret.
enum WorkspaceSchemaMigration {
    /// Brings `workspace` from schema version `from` up to `to`, or returns `nil` when it cannot be
    /// understood. Pure and total — see the type doc.
    static func migrate(
        _ workspace: Workspace,
        from: Int,
        to: Int = Workspace.currentSchemaVersion,
    ) -> Workspace? {
        // Same version: identity (preserves every field bit-for-bit). Any other version has no upgrade
        // step (single-user, no backward-compat) → nil so the caller falls back to the default.
        from == to ? workspace : nil
    }

    // MARK: - Tree-rooted (v10) migration registration (W3 — additive, off the live load path)

    /// The registered upgrade step into the tree-rooted ``TreeWorkspace`` shape (docs/42 §Migration). A
    /// `from == 9` raw-decodable v9 file migrates through the frozen ``WorkspaceV9`` mirror; a `from == 10`
    /// file is already the tree shape (the caller typed-decodes it directly, so this returns `nil` — there
    /// is nothing to upgrade); any other version returns `nil` → the caller resets to default.
    ///
    /// **Additive (W3): the live `WorkspacePersistence.load()` still returns the v9 ``Workspace`` and does
    /// NOT call this.** It is the registered seam W4 wires in behind the version peek when the store cuts
    /// over to ``TreeWorkspace``. Forward-tolerant on `5...9` (those older shapes all decode through the v9
    /// mirror — the v9 fields are a superset).
    static func migrateToTree(_ data: Data, from: Int) -> TreeWorkspace? {
        switch from {
        case 5...9:
            WorkspacePersistence.migrateV9toV10(from: data)
        default:
            // 10 = already the tree shape (caller decodes directly); anything else is uninterpretable.
            nil
        }
    }
}
