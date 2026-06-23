// FileExplorerModel — the minimal per-pane file panel logic (W2). A functional toggle on the footer's
// "File explorer" pill shows a small side panel listing the entries of the pane's cwd. This is the pure
// LOGIC half (listing + sort + the directory entry value type); the panel VIEW is `FileExplorerPanel`.
//
// Scope (minimal but real): for a LOCAL pane whose `lastKnownCwd` resolves to a real directory on this
// machine, we list it via `FileManager`. For a remote pane there is no client-side filesystem access yet
// (the cwd lives on the host) → we surface a clear "remote — listing not yet wired" state.
//   TODO(host): add a host-side directory-listing wire (or reuse the NDJSON ctl `read` path) so a remote
//   pane's cwd can be browsed; until then `.remoteUnavailable` is the honest state.

import Foundation
import Observation

/// One listed filesystem entry (a child of the cwd). Pure value type → unit-tested.
public struct FileEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var isDirectory: Bool
    public var id: String { name }

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// The result of attempting to list a cwd. Drives the panel's three states.
public enum FileListing: Equatable, Sendable {
    /// A successful local listing (already sorted: dirs first, then case-insensitive name).
    case entries([FileEntry])
    /// The cwd is unknown/empty (no `lastKnownCwd` for the pane).
    case unknownCwd
    /// A remote pane — client-side listing is not wired yet (TODO(host)).
    case remoteUnavailable
    /// The path could not be read (does not exist / not a directory / permission).
    case unreadable(String)
}

/// The per-pane file-explorer panel model (W2). `@MainActor @Observable` so the panel re-renders when a
/// listing arrives; the listing itself is computed by the pure ``FileExplorerLister``.
@preconcurrency
@MainActor
@Observable
public final class FileExplorerModel {
    /// Whether the panel is currently shown (toggled by the footer pill).
    public private(set) var isOpen = false
    /// The most recent listing for the bound cwd.
    public private(set) var listing: FileListing = .unknownCwd
    /// The cwd path the listing reflects (for the panel header).
    public private(set) var cwd: String?

    public init() {}

    /// Toggle the panel. On opening, refresh the listing for `cwd`. `isRemote` selects the remote stub.
    @discardableResult
    public func toggle(cwd: String?, isRemote: Bool) -> Bool {
        isOpen.toggle()
        if isOpen { refresh(cwd: cwd, isRemote: isRemote) }
        return isOpen
    }

    /// Recompute the listing for `cwd` (called on open + on cwd change while open).
    public func refresh(cwd: String?, isRemote: Bool) {
        self.cwd = cwd
        listing = FileExplorerLister.list(cwd: cwd, isRemote: isRemote)
    }

    public func close() { isOpen = false }
}

/// Tilde-expansion without bridging to `NSString` (SwiftLint legacy_objc_type). `~` and `~/…` resolve
/// to the user's home directory; an absolute or relative path is returned unchanged.
enum FilePath {
    static func expandingTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) } // keep the leading "/"
        return path // "~user" form — not supported; leave as-is
    }
}

/// The pure listing function (no view, no observation) — unit-tested directly.
public enum FileExplorerLister {
    /// List `cwd`'s children. Remote panes return `.remoteUnavailable`; an empty/nil cwd returns
    /// `.unknownCwd`; a real local directory returns sorted `.entries`; anything else `.unreadable`.
    public static func list(cwd: String?, isRemote: Bool, fileManager: FileManager = .default) -> FileListing {
        if isRemote { return .remoteUnavailable }
        guard let cwd, !cwd.trimmingCharacters(in: .whitespaces).isEmpty else { return .unknownCwd }
        let expanded = FilePath.expandingTilde(cwd)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return .unreadable(expanded)
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: expanded) else {
            return .unreadable(expanded)
        }
        let baseURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let entries: [FileEntry] = names.map { name in
            var childIsDir: ObjCBool = false
            let child = baseURL.appendingPathComponent(name).path
            _ = fileManager.fileExists(atPath: child, isDirectory: &childIsDir)
            return FileEntry(name: name, isDirectory: childIsDir.boolValue)
        }
        return .entries(sorted(entries))
    }

    /// Directories first, then case-insensitive name (a stable, predictable order).
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
