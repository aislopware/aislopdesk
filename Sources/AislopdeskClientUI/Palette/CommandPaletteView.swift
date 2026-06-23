// CommandPaletteView — the 640×464 top-center palette overlay (warp-overlays-actions.md §1). It is a
// `surface_2` card, 8pt radius, 1pt `outline` border, the standard drop-shadow, pushed down 117pt from the
// top edge. Wrapped by `DismissBackdrop` (a transparent click-blocker — NOT a tinted scrim, §1.1) so a tap
// OUTSIDE the card closes it while a tap INSIDE does not propagate (the card swallows the tap).
//
// Body: a search field (16pt V / 24pt H padding) over a scrolling result list. Zero-state (empty query) =
// filter chips + recents (the coordinator computes `paletteResults`). Keyboard: ↑/↓ move selection, ⏎ runs
// the selected row, esc closes. For headless snapshots, `staticMirror` renders a static text field mirror
// (no first-responder) and the at-rest row fills.

import AislopdeskDesignSystem
import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.theme) private var theme

    @Bindable var coordinator: OverlayCoordinator
    var staticMirror: Bool = false

    @FocusState private var searchFocused: Bool

    private static let width: CGFloat = 640
    private static let maxHeight: CGFloat = 464
    private static let topMargin: CGFloat = 117

    var body: some View {
        DismissBackdrop(onDismiss: { coordinator.closePalette() }) {
            card
                .frame(width: Self.width)
                .frame(maxHeight: Self.maxHeight)
                .background(
                    RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                        .fill(theme.surface2),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                        .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
                )
                .shadow(
                    color: theme.shadowColor,
                    radius: WarpShadow.blur,
                    x: WarpShadow.offset.width,
                    y: WarpShadow.offset.height,
                )
                .padding(.top, Self.topMargin)
                .padding(.bottom, WarpSpace.l)
                // Mouse-down inside the card must NOT reach the backdrop's dismiss tap (§1.1 stopPropagation).
                .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
                .onTapGesture {}
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(theme.outline)
            resultsArea
        }
    }

    // MARK: Search field

    @ViewBuilder private var searchField: some View {
        HStack(spacing: WarpSpace.l) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: WarpSize.iconGlyph))
                .foregroundStyle(theme.textSub)
            if staticMirror {
                Text(coordinator.paletteQuery.isEmpty ? Self.placeholder : coordinator.paletteQuery)
                    .font(WarpType.ui(WarpType.paletteSize))
                    .foregroundStyle(coordinator.paletteQuery.isEmpty ? theme.textSub : theme.textMain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.placeholder, text: $coordinator.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(WarpType.ui(WarpType.paletteSize))
                    .foregroundStyle(theme.textMain)
                    .focused($searchFocused)
                    .onSubmit { coordinator.acceptSelected() }
                    .onChange(of: coordinator.paletteQuery) { _, _ in coordinator.paletteSelection = 0 }
            }
        }
        .padding(.horizontal, WarpSpace.dialogHorizontal)
        .padding(.vertical, WarpSpace.xxl)
        #if os(macOS) || os(iOS)
            .onAppear { if !staticMirror { searchFocused = true } }
        #endif
    }

    private static let placeholder = "Search for a command"

    // MARK: Results

    @ViewBuilder private var resultsArea: some View {
        let results = coordinator.paletteResults
        let selectable = coordinator.selectableResults
        let zeroState = coordinator.paletteQuery.trimmingCharacters(in: .whitespaces).isEmpty
            && coordinator.paletteFilter == nil

        VStack(spacing: 0) {
            if zeroState { chipsRow }
            if results.isEmpty {
                emptyPlaceholder
            } else {
                resultList(results: results, selectable: selectable)
            }
        }
        // Keyboard handling on the whole results area (works without first-responder on the field too).
        #if os(macOS) || os(iOS)
        .modifier(PaletteKeyHandler(coordinator: coordinator, enabled: !staticMirror))
        #endif
    }

    @ViewBuilder private var chipsRow: some View {
        if let mixer = coordinator.mixer {
            let filters = mixer.availableFilters
            if !filters.isEmpty {
                FlowChips(
                    filters: filters,
                    selected: coordinator.paletteFilter,
                    staticMirror: staticMirror,
                    onSelect: { coordinator.selectFilter($0) },
                )
                .padding(.horizontal, WarpSpace.dialogHorizontal)
                .padding(.vertical, WarpSpace.m)
            }
        }
    }

    private func resultList(results: [PaletteItem], selectable: [PaletteItem]) -> some View {
        let selectedID = selectable.indices.contains(coordinator.paletteSelection)
            ? selectable[coordinator.paletteSelection].id : nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results) { item in
                    PaletteRow(
                        item: item,
                        isSelected: item.id == selectedID,
                        staticMirror: staticMirror,
                        onRun: { coordinator.run(item) },
                    )
                }
            }
            .padding(.vertical, WarpSpace.s)
        }
    }

    private var emptyPlaceholder: some View {
        Text("No results found")
            .font(WarpType.ui(WarpType.paletteSize))
            .foregroundStyle(theme.textSub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarpSpace.dialogHorizontal)
            .padding(.vertical, WarpSpace.l)
    }
}

/// A simple wrapping chip row (Warp's `Wrap::row`). Uses `Layout`-free `HStack`s in rows of up to 4 chips
/// so it stays EAGER/STATIC-snapshot friendly (no `Layout` measurement pass needed).
private struct FlowChips: View {
    let filters: [QueryFilter]
    let selected: QueryFilter?
    var staticMirror: Bool
    let onSelect: (QueryFilter) -> Void

    var body: some View {
        let rows = stride(from: 0, to: filters.count, by: 4).map { start in
            Array(filters[start..<min(start + 4, filters.count)])
        }
        VStack(alignment: .leading, spacing: WarpSpace.m) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: WarpSpace.m) {
                    ForEach(row, id: \.self) { filter in
                        FilterChip(
                            filter: filter,
                            isSelected: selected == filter,
                            staticMirror: staticMirror,
                            onSelect: { onSelect(filter) },
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Keyboard handling for the palette (↑/↓ select, ⏎ run, esc close). A `ViewModifier` so the `#if` guard
/// stays out of the body. `onKeyPress` is macOS 14+/iOS 17+; gated to the live (non-static) path.
#if os(macOS) || os(iOS)
private struct PaletteKeyHandler: ViewModifier {
    @Bindable var coordinator: OverlayCoordinator
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onKeyPress(.upArrow) { coordinator.moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) { coordinator.moveSelection(1)
                    return .handled
                }
                .onKeyPress(.return) { coordinator.acceptSelected()
                    return .handled
                }
                .onKeyPress(.escape) { coordinator.closePalette()
                    return .handled
                }
        } else {
            content
        }
    }
}
#endif
