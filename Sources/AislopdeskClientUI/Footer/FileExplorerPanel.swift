// FileExplorerPanel — the minimal file panel shown when the footer's "File explorer" pill is ON (W2).
// A small surface_1 panel listing the pane's cwd entries (folder/file glyph + name), with a header
// showing the cwd and the three non-entry states (unknown cwd / remote unavailable / unreadable).
//
// Clicking an entry emits `selectFile(path)` (the same intent the file-attach picker would emit), so a
// file can be inserted into the prompt. Directories are listed but not navigable yet (minimal scope).

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct FileExplorerPanel: View {
    @Environment(\.theme) private var theme

    let model: FileExplorerModel
    /// Emitted when a file row is clicked → its absolute path.
    var onSelect: (String) -> Void = { _ in }

    private var headerText: String {
        if let cwd = model.cwd, !cwd.isEmpty { return PaneMath.truncatedCwd(cwd, maxChars: 36) }
        return "Files"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.splitPaneBorder)
            content
        }
        .frame(width: 240)
        .background(theme.surface1)
        .overlay(
            Rectangle().fill(theme.splitPaneBorder).frame(width: WarpBorder.width),
            alignment: .leading,
        )
    }

    private var header: some View {
        HStack(spacing: WarpSpace.s) {
            Image(systemName: "folder")
                .font(.system(size: WarpType.uiSize, weight: .regular))
                .foregroundStyle(theme.textSub)
            Text(headerText)
                .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                .foregroundStyle(theme.textMain)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", help: "Close file explorer") { model.close() }
        }
        .padding(.horizontal, WarpSpace.m)
        .padding(.vertical, WarpSpace.s)
    }

    @ViewBuilder private var content: some View {
        switch model.listing {
        case let .entries(entries):
            if entries.isEmpty {
                emptyState("Empty directory")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        case .unknownCwd:
            emptyState("No working directory")
        case .remoteUnavailable:
            emptyState("Remote — file listing not yet wired")
        case let .unreadable(path):
            emptyState("Can't read \(PaneMath.truncatedCwd(path, maxChars: 28))")
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        Button {
            guard !entry.isDirectory, let cwd = model.cwd else { return }
            let baseURL = URL(fileURLWithPath: FilePath.expandingTilde(cwd), isDirectory: true)
            onSelect(baseURL.appendingPathComponent(entry.name).path)
        } label: {
            HStack(spacing: WarpSpace.s) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .font(.system(size: WarpType.uiSize, weight: .regular))
                    .foregroundStyle(entry.isDirectory ? theme.accent : theme.textSub)
                Text(entry.name)
                    .font(WarpType.ui(WarpType.uiSize))
                    .foregroundStyle(theme.textMain)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarpSpace.m)
            .padding(.vertical, WarpSpace.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(WarpType.ui(WarpType.uiSize))
            .foregroundStyle(theme.textDisabled)
            .padding(WarpSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
