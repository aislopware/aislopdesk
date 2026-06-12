import Foundation

// MARK: - WorkspaceTransfer (portable export / import)

/// Encodes a workspace to a PORTABLE document (backup / share / move-to-another-machine) and decodes one
/// back, defensively. The document is a small versioned envelope around the same `Codable` `Workspace`
/// the app already persists, with two safety rules baked in:
///
/// - **The host connection is stripped on export and never adopted on import** — a shared workspace must
///   not leak (or silently graft on) someone's `host:port`. The importer keeps its OWN connection.
/// - **A hostile / foreign / future file decodes to `nil`, never a crash** — wrong magic, unsupported
///   format version, mismatched schema, or garbage JSON all return `nil` so the live workspace is left
///   untouched.
///
/// Pure + table-tested. The id re-minting that keeps an import from colliding with the live registry is
/// the store's job (it knows the live ids); this layer only validates + repairs the shape.
public enum WorkspaceTransfer {
    /// A magic string so a random JSON file isn't mistaken for a workspace document.
    public static let magic = "aislopdesk.workspace"
    /// The document envelope version (independent of the inner ``Workspace/currentSchemaVersion``).
    public static let formatVersion = 1

    public struct Document: Codable, Sendable {
        public var format: String
        public var formatVersion: Int
        public var workspace: Workspace
        public init(format: String, formatVersion: Int, workspace: Workspace) {
            self.format = format
            self.formatVersion = formatVersion
            self.workspace = workspace
        }
    }

    /// Encodes `workspace` to a shareable document. The caller should pass an already-persistable workspace
    /// (ephemeral panes stripped); this additionally nils the host connection. Pretty-printed + key-sorted
    /// so a committed/diffed export reads cleanly.
    public static func export(_ workspace: Workspace) -> Data {
        var ws = workspace
        ws.connection = nil
        let doc = Document(format: magic, formatVersion: formatVersion, workspace: ws)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(doc)) ?? Data()
    }

    /// Decodes + REPAIRS `data` into a restorable workspace, or `nil` when the bytes are not a valid
    /// aislopdesk workspace document (wrong magic / unsupported format / schema mismatch / garbage). The
    /// host connection is dropped (the importer keeps its own); duplicate ids are re-minted and a
    /// dangling focus / group membership is normalized — the same repair the on-disk load applies.
    public static func decode(_ data: Data) -> Workspace? {
        guard let doc = try? JSONDecoder().decode(Document.self, from: data),
              doc.format == magic,
              doc.formatVersion <= formatVersion,
              doc.workspace.schemaVersion == Workspace.currentSchemaVersion else { return nil }
        var seen = Set<PaneID>()
        var ws = doc.workspace
        ws.connection = nil
        ws.canvas = ws.canvas.dedupingItemIDs(seen: &seen)
        return ws.normalizingFocus().normalizingGroups()
    }
}
