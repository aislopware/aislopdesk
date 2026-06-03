import Foundation

// MARK: - Workspace persistence (the tree of intent ↔ disk)

/// Loads + saves the pure ``Workspace`` value tree to disk (docs/22 §6).
///
/// The tree IS the format — it is already `Codable`, with a hand-written discriminated `PaneNode`
/// codec (`PaneNode+Codable.swift`) so the JSON is stable and versionable. This type is deliberately
/// **IO-thin**: it owns only the file URL and the encode/decode, so it is unit-testable against a
/// temp directory with no store, no UI, no client.
///
/// ### The RESTORED-vs-RECONNECTED discipline (docs/22 §6)
/// Persistence restores SHAPE and INTENT only — never live connections, byte buffers, or sessionIDs.
/// On launch the store decodes the tree and starts the registry empty; `reconcile()` materializes
/// **idle** sessions; the view connects lazily on appear. A relaunch is a fresh session.
///
/// ### Failure policy
/// Any failure to read OR decode (missing file, corrupt JSON, unknown `schemaVersion`) falls back to
/// ``Workspace/defaultWorkspace()`` rather than crashing — a corrupt store must never brick launch.
/// `@unchecked Sendable`: the only stored properties are a `URL` (value type, Sendable) and a
/// `FileManager` that is read-only here and documented thread-safe for these file operations, so a
/// `WorkspacePersistence` value can cross actor boundaries for the store's off-main-actor debounced
/// write (docs/22 §6) without data-race risk.
public struct WorkspacePersistence: @unchecked Sendable {
    /// The file the workspace is written to / read from. Defaults to
    /// `Application Support/Rwork/workspace.json` (the app container on iOS).
    public let fileURL: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - fileURL: where to persist. Defaults to ``defaultFileURL(using:)``.
    ///   - fileManager: injected for tests (point at a temp dir). Defaults to `.default`.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(using: fileManager)
    }

    /// The default persistence location: `<Application Support>/Rwork/workspace.json`. Falls back to a
    /// temporary directory if Application Support cannot be resolved (sandboxed edge cases) — the data
    /// is non-critical (a fresh default workspace is always recoverable).
    public static func defaultFileURL(using fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Rwork", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    // MARK: Encoding (deterministic, reviewable)

    /// A JSON encoder configured for a stable, reviewable on-disk shape (sorted keys, pretty-printed).
    /// Sorted keys keep the byte-stable round-trip tests meaningful (docs/22 §8).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: Save

    /// Encodes `workspace` and writes it atomically to ``fileURL``, creating the parent directory if
    /// needed. Throws on an IO/encode failure (the store debounces + best-effort calls this; a thrown
    /// error is logged, not fatal — a failed save just means the previous good file is kept).
    public func save(_ workspace: Workspace) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: Load

    /// Reads + decodes the workspace, then forward-migrates it to this build's schema (docs/22 §6).
    /// Never throws — launch must always get a usable workspace:
    /// - A read failure (missing file) → ``Workspace/defaultWorkspace()``.
    /// - A decode failure (corrupt JSON, an unknown discriminator) → ``Workspace/defaultWorkspace()``.
    /// - An *older* payload → upgraded in place by ``WorkspaceSchemaMigration`` (an older store is
    ///   migrated forward, no longer discarded on the first schema bump).
    /// - A *future* / un-migratable version → ``WorkspaceSchemaMigration/migrate(_:from:to:)`` returns
    ///   `nil` and we fall back to the default (a build cannot interpret a newer shape).
    ///
    /// Because migration runs on the *already-decoded* value, it only covers schema changes that are
    /// still parseable by today's `Codable`. A future **v2 that reshapes the wire format** (so the v1
    /// decoder can no longer parse it) would fail the `decode` above and fall back to default; handling
    /// it would need a pre-decode raw-JSON branch here (peek `schemaVersion` off the raw object, run a
    /// JSON→JSON upgrade, then decode). That is out of scope — see ``WorkspaceSchemaMigration``.
    public func load() -> Workspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaultWorkspace()
        }
        guard let decoded = try? JSONDecoder().decode(Workspace.self, from: data) else {
            return .defaultWorkspace()
        }
        // Forward-migrate the decoded value to this build's schema. A future/un-migratable version
        // (migrate → nil) falls back to the default; v1-today is an identity passthrough.
        guard let migrated = WorkspaceSchemaMigration.migrate(decoded, from: decoded.schemaVersion) else {
            return .defaultWorkspace()
        }
        return migrated
    }
}
