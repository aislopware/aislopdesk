// RemoteWindowPicker — the themed modal that lists the host's shareable windows (logic-api §4.1 / §4.3,
// docs/31) and opens a remote-window pane streaming the chosen one. This is the core "remote window" UX:
// the `/remote-control` footer pill and the "New Remote Window Tab" palette action both present it.
//
// It binds a dedicated `RemoteWindowModel` (the discovery half — `refresh()` over the `RemoteWindowDiscovery`
// seam + the pure `filtered(_:query:)`), shows loading / empty / error / list states, and on a pick calls
// `onOpen(summary)` (the root wires it to `store.newRemoteWindowTab(...)`). It NEVER opens the model itself
// — the pane's own `RemoteWindowModel` (materialized for the new `.remoteGUI` tab) drives the live stream.
//
// Styling mirrors `ConfirmModal` (overlays §3.1): a 70%-black scrim, a `surface_2` card at dialog radius
// with a 1pt outline, centered. Esc / scrim-tap → cancel.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import SwiftUI

struct RemoteWindowPicker: View {
    @Environment(\.theme) private var theme

    /// The discovery-driving model (its own instance — NOT a pane's; it only refreshes + filters).
    let model: RemoteWindowModel
    /// A window was chosen → open a pane streaming it. The root wires this to `store.newRemoteWindowTab`.
    let onOpen: (RemoteWindowSummary) -> Void
    /// Dismiss without choosing.
    let onCancel: () -> Void
    /// EAGER/STATIC render path for headless snapshots (skips the on-appear `refresh()` task).
    var staticMirror: Bool = false

    /// Local filter text over the discovered window list (token-AND via `RemoteWindowModel.filtered`).
    @State private var query = ""

    private static let width: CGFloat = 440
    private static let listMaxHeight: CGFloat = 320

    /// The discovered windows narrowed by the local filter (pure helper — same policy the old panel used).
    private var visibleWindows: [RemoteWindowSummary] {
        RemoteWindowModel.filtered(model.availableWindows, query: query)
    }

    var body: some View {
        ZStack {
            Color(WarpShadow.modalBackdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard !staticMirror else { return }
            await model.refresh()
        }
        #if os(macOS) || os(iOS)
        .modifier(PickerEscHandler(onCancel: onCancel))
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WarpSpace.xl) {
            header
            filterField
            listBody
        }
        .padding(WarpSpace.dialogHorizontal)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous).fill(theme.surface2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
        .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
        .onTapGesture {}
    }

    private var header: some View {
        HStack(spacing: WarpSpace.m) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: WarpType.headerSize, weight: .regular))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Open a Remote Window")
                    .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                Text("Stream a window from the host into a pane")
                    .font(WarpType.ui(WarpType.overlineSize))
                    .foregroundStyle(theme.textSub)
            }
            Spacer(minLength: 0)
            IconButton(systemName: "arrow.clockwise", help: "Refresh window list") {
                Task { await model.refresh() }
            }
            IconButton(systemName: "xmark", help: "Cancel") { onCancel() }
        }
    }

    private var filterField: some View {
        HStack(spacing: WarpSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: WarpType.uiSize))
                .foregroundStyle(theme.textSub)
            TextField("Filter windows…", text: $query)
                .textFieldStyle(.plain)
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textMain)
        }
        .padding(.horizontal, WarpSpace.m)
        .frame(height: WarpSize.controlHeightSmall)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous).fill(theme.surface1),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
    }

    @ViewBuilder private var listBody: some View {
        if model.isLoading {
            stateMessage("Looking for windows on the host…", systemImage: "hourglass")
        } else if let error = model.loadError, model.availableWindows.isEmpty {
            stateMessage(error, systemImage: "exclamationmark.triangle")
        } else if visibleWindows.isEmpty {
            stateMessage(
                RemoteWindowModel.windowFilterEmptyMessage(
                    filter: query, totalCount: model.availableWindows.count,
                ),
                systemImage: "line.3.horizontal.decrease.circle",
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleWindows) { window in
                        RemoteWindowRow(summary: window) { onOpen(window) }
                    }
                }
            }
            .frame(maxHeight: Self.listMaxHeight)
        }
    }

    private func stateMessage(_ text: String, systemImage: String) -> some View {
        VStack(spacing: WarpSpace.m) {
            Image(systemName: systemImage)
                .font(.system(size: WarpType.headerSize, weight: .regular))
                .foregroundStyle(theme.textSub)
            Text(text)
                .font(WarpType.ui(WarpType.uiSize))
                .foregroundStyle(theme.textSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarpSpace.xxl)
    }
}

/// One row in the picker: an app/window glyph + the "App — Title (W×H)" label; click → open.
struct RemoteWindowRow: View {
    @Environment(\.theme) private var theme

    let summary: RemoteWindowSummary
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: WarpSpace.m) {
                Image(systemName: "macwindow")
                    .font(.system(size: WarpType.uiSize, weight: .regular))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary.title.isEmpty ? summary.appName : summary.title)
                        .font(WarpType.ui(WarpType.uiSize, weight: .semibold))
                        .foregroundStyle(theme.textMain)
                        .lineLimit(1)
                    Text("\(summary.appName)  ·  \(summary.width)×\(summary.height)")
                        .font(WarpType.ui(WarpType.overlineSize))
                        .foregroundStyle(theme.textSub)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarpSpace.m)
            .padding(.vertical, WarpSpace.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WarpRadius.control, style: .continuous)
                    .fill(hovering ? theme.surface3 : Color.clear),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#if os(macOS) || os(iOS)
private struct PickerEscHandler: ViewModifier {
    let onCancel: () -> Void
    func body(content: Content) -> some View {
        content.onKeyPress(.escape) { onCancel()
            return .handled
        }
    }
}
#endif
