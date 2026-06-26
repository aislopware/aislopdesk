// TerminalFindBar — the in-pane ⌘F find overlay (E5 / WI-3). A THIN SwiftUI driver over the PURE
// ``TerminalSearchController`` (count / N-of-M / next-prev-wrap — the single source of truth for the match
// math) plus libghostty's OWN in-surface search bindings (`search:` / `navigate_search:` / `end_search`,
// reached through ``TerminalViewModel/performSearchSurfaceAction(_:)``), which own the amber highlight +
// scroll-to-match in the live grid. The counter counts the `scrollbackTextLines()` snapshot taken when the
// bar opened (divergence #2 in plans/E5.md): the count is the mirror's; the highlight is libghostty's — they
// agree in the common case (same buffer), and the mirror refreshes on open + on the `Aa` / `.*` toggles.
//
// Anatomy matches `find.png` (top-trailing of the focused pane, floating card, `Otty.*` tokens ONLY — raw
// font / radius literals fail `scripts/check-ds-leaks.sh`):
//   [ query field ][ Aa case pill ][ .* regex pill ][ N of M ][ ∧ prev ][ ∨ next ][ × close ]
// (The screenshot places the `N of M` counter before the nav chevrons — `spec/user-interface__find.md` /
// `screenshots/find.png` are the visual source of truth, so the counter sits there rather than after the
// chevrons as the plan's prose anatomy listed it.)
//
// Behaviour (ES-E5-1..4): auto-focus the field on appear (pre-focused per spec); live query → recompute +
// re-arm highlight; ↩ / ⇧↩ next / prev; `Aa` / `.*` toggle case / regex; Esc (or ×) closes + clears all
// highlights. The bar OWNS no match math — `TerminalFindBarModel` wraps the controller + a weak model ref so
// the GUI and the headless unit test (`TerminalFindBarModelTests`) drive the exact same logic.
//
// Hang-safety: NO `GhosttySurface` / VideoToolbox / Metal is touched here — the bar only calls the model
// seam, which probes `surface as? TerminalSurfaceActions` and degrades to a no-op on a headless surface.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// The find bar's view-model: the PURE ``TerminalSearchController`` (count / nav) + a weak pane
/// ``TerminalViewModel`` ref (the scrollback mirror + the libghostty `search:` passthrough). `@Observable`
/// so the bar re-renders on every query / toggle / nav; held as `@State` by ``TerminalLeafView`` and wired to
/// the pane's `onRequestFind` / `onRequestFindNext` / `onRequestFindPrev` callbacks. Weak model ref so a
/// torn-down pane is never kept alive by the bar (the leaf is `.id(PaneID)`-keyed — an identity hazard).
@MainActor
@Observable
final class TerminalFindBarModel {
    /// Whether the bar is shown over its pane (the leaf's top-trailing overlay gate).
    var visible = false
    /// The PURE match engine — the single source of truth for the counter + nav. `private(set)`: only the
    /// model's own methods mutate it (each mutation notifies `@Observable`, so the bar re-renders).
    private(set) var controller = TerminalSearchController()
    /// Bumped on every (re)open so the view re-asserts its `@FocusState` even when the bar is already mounted
    /// (⌘F while the bar is open should re-focus the field, but `.onAppear` won't fire again).
    private(set) var focusToken = 0
    /// The pane's terminal model — the scrollback mirror + the libghostty `search:` / `navigate_search:` /
    /// `end_search` passthrough. Weak (owned by the live session); `@ObservationIgnored` — pure wiring.
    @ObservationIgnored private weak var model: TerminalViewModel?

    init() {}

    /// Bind (or unbind, with `nil`) the pane's terminal model. ``TerminalLeafView`` calls this when it wires /
    /// clears the `onRequestFind*` callbacks (per-pane, so a torn-down leaf can't drive a dead model).
    func attach(_ model: TerminalViewModel?) { self.model = model }

    /// ⌘F / Find… — open (or re-focus) the bar, refreshing the scrollback mirror snapshot the counter counts
    /// (divergence #2: libghostty owns the live in-surface highlight; this snapshot owns the `N of M` count).
    func open() {
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
        visible = true
        focusToken &+= 1
    }

    /// Live query edit — recompute matches (counter) + re-arm libghostty's in-surface highlight.
    func setQuery(_ text: String) {
        controller.setQuery(text)
        armSearch()
    }

    /// `Aa` — flip case sensitivity, refresh the mirror (divergence #2), recompute + re-arm.
    func toggleCaseSensitive() {
        controller.setCaseSensitive(!controller.caseSensitive)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// `.*` — flip regex mode (ICU `NSRegularExpression`), refresh the mirror, recompute + re-arm.
    func toggleRegex() {
        controller.setRegex(!controller.isRegex)
        controller.setLines(model?.searchScrollbackLines() ?? [])
        armSearch()
    }

    /// ↩ / ⌘G — advance the selection (wraps past the last) + move libghostty's highlight / scroll. Opens the
    /// bar first if it is closed (faithful "find next opens find").
    func next() {
        if !visible { open() }
        controller.next()
        model?.performSearchSurfaceAction("navigate_search:next")
    }

    /// ⇧↩ / ⇧⌘G — retreat the selection (wraps past the first) + move libghostty's highlight / scroll. Opens
    /// the bar first if it is closed.
    func previous() {
        if !visible { open() }
        controller.previous()
        model?.performSearchSurfaceAction("navigate_search:prev")
    }

    /// × / Esc — clear the query + matches, end libghostty's search (drops every highlight), hide the bar. The
    /// buffer mirror is kept (in the controller) so a re-open is cheap.
    func close() {
        controller.clear()
        model?.performSearchSurfaceAction("end_search")
        visible = false
    }

    /// Push the current query into libghostty's own in-surface search (it owns the amber highlight + the
    /// scroll-to-match); an empty query ends the search so a stale highlight clears.
    private func armSearch() {
        let query = controller.query
        if query.isEmpty {
            model?.performSearchSurfaceAction("end_search")
        } else {
            model?.performSearchSurfaceAction("search:\(query)")
        }
    }
}

/// The find bar strip (the view). Owns only its `@FocusState` (field auto-focus) — every match / nav / toggle
/// mutation routes through ``TerminalFindBarModel`` so the GUI and the headless test stay byte-for-byte.
struct TerminalFindBar: View {
    let model: TerminalFindBarModel

    /// Pre-focuses the query field on appear (ES-E5-1: the field is pre-focused so typing lands immediately).
    @FocusState private var queryFocused: Bool

    // Platform hit-target sizing: iOS uses larger plates + a wider field for touch; macOS is compact (find.png
    // is a tight horizontal strip). Frame dimensions are not gated by check-ds-leaks (only font/radius are).
    // iOS note: ↩ / ⇧↩ (next/prev) work on a hardware keyboard; the in-bar ∧ / ∨ chevrons are the touch path
    // for nav, and the app-level ⌘G / ⇧⌘G chords need a hardware keyboard (a future iOS toolbar button is TODO).
    #if os(iOS)
    private let plate: CGFloat = 34
    private let iconSize: CGFloat = 16
    private let fieldWidth: CGFloat = 200
    #else
    private let plate: CGFloat = Otty.Metric.plate
    private let iconSize: CGFloat = Otty.Metric.iconSize
    private let fieldWidth: CGFloat = 130
    #endif

    var body: some View {
        HStack(spacing: Otty.Metric.space1) {
            queryField
            FindTogglePill(label: "Aa", isOn: model.controller.caseSensitive, help: "Case sensitive", plate: plate) {
                model.toggleCaseSensitive()
            }
            FindTogglePill(label: ".*", isOn: model.controller.isRegex, help: "Regex (ICU)", plate: plate) {
                model.toggleRegex()
            }
            counter
            OttyPlateButton(symbol: .chevronUp, help: "Previous match (⇧⌘G)", size: iconSize, plate: plate) {
                model.previous()
            }
            OttyPlateButton(symbol: .chevronDown, help: "Next match (⌘G)", size: iconSize, plate: plate) {
                model.next()
            }
            OttyPlateButton(symbol: .xmark, help: "Close (Esc)", size: iconSize, plate: plate) {
                model.close()
            }
        }
        .padding(.horizontal, Otty.Metric.space2)
        .padding(.vertical, Otty.Metric.space1)
        .background(Otty.Surface.element, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                .strokeBorder(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
        )
        .shadow(color: Otty.State.shadow, radius: 12, x: 0, y: 4)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the palette / cheat-sheet idiom).
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: model.focusToken) { _, _ in
            DispatchQueue.main.async { queryFocused = true }
        }
        // ↩ → next is the field's `.onSubmit`; ⇧↩ → previous reaches THIS container (a single-line field does
        // not submit on shift+return). Guard on `.shift` so the two never double-fire (the PaletteView idiom).
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            model.previous()
            return .handled
        }
        #if os(macOS)
        .onExitCommand { model.close() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            model.close()
            return .handled
        }
        #endif
    }

    // MARK: - Query field

    private var queryField: some View {
        TextField("Find", text: queryBinding)
            .textFieldStyle(.plain)
            .font(.system(size: Otty.Typeface.body))
            .foregroundStyle(Otty.Text.primary)
            .tint(Otty.State.accent) // the active caret is the accent colour (otty parity)
            .focused($queryFocused)
            .frame(width: fieldWidth)
            .padding(.horizontal, Otty.Metric.space2)
            .padding(.vertical, Otty.Metric.space1)
            .background(Otty.Surface.card, in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall))
            .onSubmit { model.next() } // plain ↩ → next match
    }

    /// Two-way binding into the controller's query (read the live value, write through `setQuery` so every
    /// keystroke recomputes the counter + re-arms the libghostty highlight).
    private var queryBinding: Binding<String> {
        Binding(get: { model.controller.query }, set: { model.setQuery($0) })
    }

    // MARK: - N of M counter

    @ViewBuilder private var counter: some View {
        if let label = counterText {
            Text(label)
                .font(.system(size: Otty.Typeface.footnote))
                .monospacedDigit()
                .foregroundStyle(Otty.Text.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Otty.Metric.space1)
        }
    }

    /// `N of M` when there is a current match; a muted "No results" when the query is non-empty but matched
    /// nothing; `nil` (hidden) for an empty query — matching `controller.positionLabel`.
    private var counterText: String? {
        if let position = model.controller.positionLabel {
            return "\(position.current) of \(position.total)"
        }
        if !model.controller.query.isEmpty { return "No results" }
        return nil
    }
}

/// A compact `Aa` / `.*` toggle pill (the two find-bar mode buttons). Active → accent text on an accent wash +
/// hairline; idle → secondary text, hover plate. Factored to file scope (internal) so the WI-4 GlobalSearch
/// surface reuses the EXACT pill. `Otty.*` tokens only.
struct FindTogglePill: View {
    let label: String
    let isOn: Bool
    var help: String?
    var plate: CGFloat = Otty.Metric.plate
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Otty.State.accent : Otty.Text.secondary)
                .frame(minWidth: plate, minHeight: plate)
                .padding(.horizontal, Otty.Metric.space1)
                .background(
                    isOn ? Otty.State.accentMuted : (hovering ? Otty.State.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall)
                        .strokeBorder(
                            isOn ? Otty.State.accent.opacity(0.5) : Color.clear,
                            lineWidth: Otty.Metric.hairline,
                        ),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .ottyHelp(help)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
    }
}
#endif
