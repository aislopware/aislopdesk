import Foundation

// MARK: - Workspace schema migration (forward-migrate persisted intent, never discard)

/// The version-aware seam between a decoded ``Workspace`` value and the shape this build understands
/// (docs/22 §6). `WorkspacePersistence.load()` decodes the raw JSON into a `Workspace` and then asks
/// this enum to bring it up to ``Workspace/currentSchemaVersion``. Replaces the old strict
/// `== currentSchemaVersion` guard that *discarded* any non-current payload: an older store is now
/// upgraded in place instead of being thrown away on the first schema bump.
///
/// ### Contract
/// `migrate(_:from:to:)` is a TOTAL, pure function — no IO, no force-unwrap, no throw:
/// - `from == to` → identity (the value is returned unchanged; the v1-today fast path).
/// - `from > to` → `nil` (a *future* version this build cannot understand → the caller defaults).
/// - `from < to` → apply the ``steps`` table one version at a time (`from → from+1 → … → to`); a
///   missing step (a gap in the chain) yields `nil`, and on success `schemaVersion` is stamped to
///   `to` so the returned value is self-consistent.
///
/// ### Scope boundary — value migration only
/// This seam operates on an *already-decoded* `Workspace`. It can therefore only handle schema
/// changes that are still decodable by today's `Codable` (added/renamed-with-default fields,
/// normalizations, value reshapes). A future **v2 that changes the wire shape** so the v1 decoder
/// can no longer parse it (e.g. a renamed required key, a restructured `PaneNode` codec) cannot be
/// repaired here, because by the time we hold a `Workspace` the lossy decode already happened. That
/// case needs a *pre-decode* raw-JSON branch in `load()` (peek `schemaVersion` off the raw object,
/// run a JSON→JSON upgrade, then decode) — out of scope for this seam; documented as the next step.
enum WorkspaceSchemaMigration {

    /// Brings `workspace` from schema version `from` up to `to`, or returns `nil` when it cannot be
    /// understood (a future version, or a gap in the upgrade chain). Pure and total — see the type
    /// doc for the full contract.
    ///
    /// - Parameters:
    ///   - workspace: the decoded value, whose `schemaVersion` field is `from`.
    ///   - from: the schema version the payload was written at.
    ///   - to: the version to migrate to. Defaults to ``Workspace/currentSchemaVersion``.
    /// - Returns: the migrated workspace (with `schemaVersion == to`), or `nil` if un-migratable.
    static func migrate(
        _ workspace: Workspace,
        from: Int,
        to: Int = Workspace.currentSchemaVersion
    ) -> Workspace? {
        // Same version: identity. The v1-today fast path — preserves every existing field bit-for-bit.
        if from == to { return workspace }

        // Future version: this build predates it and cannot interpret it. Caller defaults.
        if from > to { return nil }

        // Older version: walk the step table one minor version at a time, from → from+1 → … → to.
        var current = workspace
        var version = from
        while version < to {
            guard let step = steps[version] else {
                // A gap in the chain (no `version → version+1` step) → un-migratable.
                return nil
            }
            current = step(current)
            version += 1
        }
        // Stamp the result to the target version so the returned value is self-consistent.
        current.schemaVersion = to
        return current
    }

    // MARK: Step table

    /// The ordered upgrade chain, keyed by *source* version: `steps[n]` upgrades a v`n` value to
    /// v`n+1`. Each step is a pure, total transform (no IO, no throw, no force-unwrap). `migrate`
    /// composes them; a missing key is a gap and aborts migration with `nil`. `@Sendable` so the
    /// table can cross the store's off-main-actor debounced-load boundary (docs/22 §6).
    private static let steps: [Int: @Sendable (Workspace) -> Workspace] = [
        0: upgradeV0toV1
    ]

    // MARK: Steps

    /// v0 → v1: a near-identity normalization. v0 predates the invariant that `activeTabID` always
    /// points at a real tab; if it is missing or dangling, repoint it at the first tab (or leave it
    /// `nil` when there are no tabs). TOTAL — no force-unwrap, no throw; `tabs.first?.id` is `nil`
    /// for an empty workspace, which is the correct "no active tab" value.
    @Sendable
    private static func upgradeV0toV1(_ workspace: Workspace) -> Workspace {
        var copy = workspace
        let activeIsValid = copy.activeTabID.map { id in copy.tabs.contains { $0.id == id } } ?? false
        if !activeIsValid {
            copy.activeTabID = copy.tabs.first?.id
        }
        return copy
    }
}
