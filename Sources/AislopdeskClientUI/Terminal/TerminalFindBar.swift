#if canImport(SwiftUI)
import AislopdeskTerminal
import SwiftUI

// MARK: - TerminalFindBar (the ⌘F find-in-terminal overlay)

/// The SwiftUI find-in-terminal bar (docs/42 W14 #5, Warp/Ghostty ⌘F parity): a slim overlay anchored to
/// the top of ``TerminalScreenView`` with a query field, case/regex toggles, a live "N of M" match count,
/// and prev/next navigation. It drives the PURE ``TerminalSearchController`` (unit-tested) over the
/// terminal's scrollback text mirror, and pushes the query into libghostty's own in-surface search via
/// `start_search:<needle>` (so the surface highlights/scrolls to the match) when the surface exposes
/// ``TerminalSurfaceActions``.
///
/// ### What is and isn't tested
/// This VIEW is compiled + code-reviewed only (it touches the libghostty surface via the
/// ``TerminalSurfaceActions`` seam — never instantiated in a test, the hang-safety rule). The
/// ``TerminalSearchController`` it binds — query parsing, the ordered match list, count, wrap navigation
/// — IS unit-tested headlessly against an in-memory buffer (`TerminalSearchControllerTests`).
///
/// ### libghostty API gap (documented)
/// libghostty exposes a real search lever: `ghostty_surface_binding_action(s, "start_search:…", len)` +
/// the `GHOSTTY_ACTION_START_SEARCH / SEARCH_TOTAL / SEARCH_SELECTED` action callbacks. We FIRE
/// `start_search` (so the surface owns the highlight) but the surface's match COUNT / current-index come
/// back only through the C `action_cb`, which Aislopdesk's embedding does not plumb the surface→view route
/// for yet. So the "N of M" + prev/next UX is computed by `TerminalSearchController` over the text mirror
/// (`scrollbackTextLines()`), which is exact for the line-oriented mirror; closing that gap (routing the
/// surface's search-result callbacks into this view) is a future enhancement, not a blocker.
struct TerminalFindBar: View {
    /// The pane's terminal model — its surface is the search target + the scrollback-text source.
    let model: TerminalViewModel
    /// Binding to the find-bar's open state (the leaf owns the `@State`; ⌘F / the menu flips it).
    @Binding var isPresented: Bool

    @State private var controller = TerminalSearchController()
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(minWidth: 120, maxWidth: 220)
                .focused($fieldFocused)
                .onSubmit { navigate(forward: true) }
                .onChange(of: query) { _, newValue in applyQuery(newValue) }

            // "N of M" position (or "No results" / nothing for an empty query).
            Group {
                if let pos = controller.positionLabel {
                    Text("\(pos.current) of \(pos.total)")
                } else if !query.isEmpty {
                    Text("No results").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 56, alignment: .leading)

            // Case-sensitive toggle.
            Toggle(isOn: Binding(
                get: { controller.caseSensitive },
                set: { controller.setCaseSensitive($0)
                    syncSurface()
                },
            )) { Text("Aa").font(.system(size: 11, weight: .semibold)) }
                .toggleStyle(.button)
                .help("Case sensitive")

            // Regex toggle.
            Toggle(isOn: Binding(
                get: { controller.isRegex },
                set: { controller.setRegex($0)
                    syncSurface()
                },
            )) { Text(".*").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                .toggleStyle(.button)
                .help("Regular expression")

            // Prev / next navigation.
            Button { navigate(forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(controller.matchCount == 0)
                .help("Previous match")
            Button { navigate(forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(controller.matchCount == 0)
                .help("Next match")

            // Close.
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close find bar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .padding(8)
        .onAppear { seedFromSelection()
            fieldFocused = true
        }
    }

    // MARK: Actions

    /// Re-reads the scrollback mirror + applies the query to the controller, then pushes it to the surface.
    private func applyQuery(_ text: String) {
        if let actions = model.surface as? TerminalSurfaceActions {
            controller.setLines(actions.scrollbackTextLines())
        }
        controller.setQuery(text)
        syncSurface()
    }

    /// Pushes the current query into libghostty's in-surface search so it highlights/scrolls to matches.
    /// A no-op for a surface that doesn't expose the action seam (headless / placeholder).
    private func syncSurface() {
        guard let actions = model.surface as? TerminalSurfaceActions else { return }
        if query.isEmpty {
            actions.performBindingAction("end_search")
        } else {
            // The needle is the literal query; libghostty's search needle is plain text (the controller
            // owns regex/case semantics for the count). Quote-free name:value action form.
            actions.performBindingAction("start_search:\(query)")
        }
    }

    /// Moves the selection + asks the surface to step to the next/prev match (libghostty `navigate_search`).
    private func navigate(forward: Bool) {
        guard controller.matchCount > 0 else { return }
        if forward { controller.next() } else { controller.previous() }
        if let actions = model.surface as? TerminalSurfaceActions {
            actions.performBindingAction(forward ? "navigate_search:next" : "navigate_search:previous")
        }
    }

    /// Pre-fills the field with the current selection (the macOS "use selection for find" convention).
    private func seedFromSelection() {
        if query.isEmpty,
           let actions = model.surface as? TerminalSurfaceActions,
           let sel = actions.readSelection(),
           !sel.contains("\n"), !sel.isEmpty
        {
            query = sel
            applyQuery(sel)
        }
    }

    private func close() {
        controller.clear()
        (model.surface as? TerminalSurfaceActions)?.performBindingAction("end_search")
        isPresented = false
    }
}
#endif
