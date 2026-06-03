#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneCarouselView (the compact projection — docs/22 §4)

/// The **compact** rendering of the active tab: a paged `TabView` carousel that shows exactly ONE
/// leaf at a time (an always-on zoom), swipeable between leaves, with page-indicator dots
/// (docs/22 §1.3, §4). It is a pure VIEW-time projection of the SAME tree the regular
/// ``PaneTreeView`` renders — a 3-pane Mac split opens here as 3 swipeable pages, losslessly — so a
/// regular↔compact flip is view-only: it must NOT call `reconcile()`, drop focus, or tear down
/// sessions (docs/22 §4). Nothing here mutates the tree shape; it only moves *focus*.
///
/// ### Selection is the focused pane (the binding is the whole contract)
/// `TabView`'s selection is BOUND to the active tab's `focusedPane` through a computed `Binding`:
/// reading it returns the focused leaf, writing it (a swipe / a dot tap) routes through
/// `store.focus(_:)`. Focus is therefore the single source of truth for "which page is showing" in
/// both directions — a programmatic `move(.next)` slides the carousel, and a user swipe updates
/// focus, with no stray `@State` to drift. Compact mounts exactly ONE host (the visible page), which
/// structurally sidesteps the iOS two-first-responder race (docs/22 §4); the `PaneFocusCoordinator`
/// is only needed on the multi-visible iPad-regular path.
///
/// ### Identity is load-bearing (docs/22 §7, §11.2)
/// Each page carries `.id(PaneID)` so SwiftUI keys each leaf host by its stable pane identity — a
/// reshape / focus change / regular↔compact flip never reuses a `GhosttySurface` / video pipeline /
/// input `Coordinator` across panes, and never tears down the live session backing a page.
///
/// ### Chrome, not dividers (docs/22 §4)
/// Compact shows NO split dividers — there is only ever one visible leaf. Each page is wrapped in
/// ``PaneChromeView`` so the per-pane affordances (split / zoom / close) stay reachable; `split`
/// still mutates the tree (so it round-trips to desktop) and just adds another swipe page here.
struct PaneCarouselView: View {
    /// The store: read for the active tab / pages / handles, written for focus + add-tab.
    @Bindable var store: WorkspaceStore

    /// Optional affordance to reveal the tab drawer (the `NavigationSplitView` sidebar). The Integrate
    /// phase wires this to flip the shell's `NavigationSplitViewVisibility`; left `nil` the button is
    /// hidden (the native navigation chrome already exposes the sidebar on compact).
    var onShowTabs: (() -> Void)?

    init(store: WorkspaceStore, onShowTabs: (() -> Void)? = nil) {
        self.store = store
        self.onShowTabs = onShowTabs
    }

    var body: some View {
        Group {
            if let tab = store.activeTab {
                content(for: tab)
            } else {
                emptyState
            }
        }
        .background(.background)
    }

    // MARK: Carousel

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        let pages = CompactLayoutResolver.pages(for: tab)

        VStack(spacing: 0) {
            topBar(for: tab, pages: pages)
            Divider()

            TabView(selection: focusBinding(in: tab)) {
                ForEach(pages, id: \.id) { page in
                    pageView(for: page, in: tab)
                        .padding(8)
                        .tag(page.id)
                }
            }
            #if os(iOS)
            // Page style with dot indicators; one leaf visible, horizontal swipe between leaves.
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            #else
            // macOS narrow-window compact: TabView has no page style, but the SAME selection binding
            // keeps the focused leaf showing. The top bar's prev/next + dots drive paging.
            .tabViewStyle(.automatic)
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One page: the focused-leaf chrome + content, keyed by stable ``PaneID``. Every page renders as
    /// focused (it is the only visible leaf — an always-on zoom), so the chrome highlights it and the
    /// leaf shows at full opacity.
    @ViewBuilder
    private func pageView(for page: CompactPage, in tab: Tab) -> some View {
        if let spec = tab.root.spec(for: page.id) {
            PaneChromeView(
                id: page.id,
                spec: spec,
                handle: store.handle(for: page.id),
                isFocused: true,
                isZoomed: tab.zoomedPane == page.id,
                store: store
            ) {
                PaneLeafView(handle: store.handle(for: page.id), spec: spec, isFocused: true, store: store)
            }
            // Stable identity across swipes / reshape / a regular↔compact flip (docs/22 §4, §7): never
            // tear down or rewire the live session backing this page.
            .id(page.id)
            #if os(macOS)
            // macOS `.automatic` TabView needs a per-page label to render a real tab bar instead of
            // blank buttons. iOS uses `.page` style (ignores `.tabItem`), so this is macOS-scoped.
            .tabItem { Text(spec.title) }
            #endif
        }
    }

    // MARK: Top bar (tab drawer + add + page position)

    /// A slim top affordance: open the tab drawer, the tab title with a page-position chip, and a `+`
    /// to add a pane (split the focused leaf). Kept thin and native — the page dots live inside the
    /// carousel; this bar is the reachable command surface on a touch device with no keyboard.
    @ViewBuilder
    private func topBar(for tab: Tab, pages: [CompactPage]) -> some View {
        HStack(spacing: 10) {
            if let onShowTabs {
                Button(action: onShowTabs) {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .help("Show tabs")
                .accessibilityLabel("Show tabs")
            }

            Text(tab.name)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)

            if pages.count > 1 {
                Text("\(CompactLayoutResolver.selectedIndex(for: tab) + 1)/\(pages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 8)

            // Prev / next page on macOS (no swipe) and as an explicit affordance on iOS too. These
            // wrap (like ⌘]/⌘[ and the carousel selection binding) — never disabled at the ends, so
            // the chevron's affordance can't contradict the keyboard's wrap semantics.
            if pages.count > 1 {
                Button { store.move(.previous) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Previous pane")
                    .accessibilityLabel("Previous pane")
                Button { store.move(.next) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Next pane")
                    .accessibilityLabel("Next pane")
            }

            addMenu(for: tab)
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The `+` affordance: split the focused leaf into a new pane of a chosen kind (adds a swipe page).
    /// A plain tap adds the common case (a terminal split); the menu offers the other kinds — mirroring
    /// the sidebar / detail "New" idiom so the user always picks the pane KIND (docs/22 WF6 decisions).
    private func addMenu(for tab: Tab) -> some View {
        Menu {
            Button {
                store.split(tab.focusedPane, axis: .horizontal, kind: .terminal)
            } label: {
                Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
            }
            Button {
                store.split(tab.focusedPane, axis: .horizontal, kind: .claudeCode)
            } label: {
                Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
            }
            Button {
                store.split(tab.focusedPane, axis: .horizontal, kind: .remoteGUI)
            } label: {
                Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
            }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            store.split(tab.focusedPane, axis: .horizontal, kind: .terminal)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .help("Add pane")
        .accessibilityLabel("Add pane")
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Pane", systemImage: "rectangle.dashed")
        } description: {
            Text("Add a tab to get started.")
        } actions: {
            Button("New Tab") { store.addTab(kind: .terminal) }
        }
    }

    // MARK: Selection binding (focus IS the page)

    /// The carousel's selection, bound to the active tab's `focusedPane`. Reading returns the focused
    /// leaf (so a programmatic `store.move(...)` slides the carousel); writing routes a swipe / dot tap
    /// through `store.focus(_:)` — a view-only focus change that never reshapes the tree or reconciles
    /// the registry. The setter guards against an empty/out-of-tree id so a transient projection swap
    /// (regular↔compact) can't push focus to a stale pane.
    private func focusBinding(in tab: Tab) -> Binding<PaneID> {
        Binding(
            get: { tab.focusedPane },
            set: { newID in
                guard newID != tab.focusedPane, tab.root.contains(newID) else { return }
                store.focus(newID)
            }
        )
    }
}
#endif
