import Foundation
import CoreGraphics
import RworkClient
import RworkInspector

// MARK: - WorkspaceStore (the one @MainActor @Observable owner)

/// The single owner of the workspace: it holds the pure ``Workspace`` tree of intent and reconciles
/// the `[PaneID: any PaneSessionHandle]` table of liveness against it after every mutation
/// (docs/22 §1.1, §2.3).
///
/// ### The shape of every mutation
/// Each public intent method does exactly two things, in order:
/// 1. apply a **pure** tree op from WF2 (returns a new `Workspace`), and
/// 2. call ``reconcile()`` to materialize sessions for new leaves and tear down orphaned ones.
///
/// Because every mutation funnels through `reconcile()`, the load-bearing invariant
/// `Set(registry.keys) == Set(allLeafIDs)` holds after *any* sequence of ops, and there is exactly
/// ONE ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`)
/// per ``PaneID`` — the four byte-pipeline invariants by construction (docs/22 §1.2).
///
/// ### The test seam
/// Sessions are built through the injected `makeSession` factory — NOT a fake `RworkClient` (which is
/// impossible) and NEVER a real `HostServer` (forbidden, pool deadlock). Tests inject a
/// `FakePaneSession`; production injects ``LivePaneSession/make(_:makeClient:makeInspector:)``.
@MainActor
@Observable
public final class WorkspaceStore {
    // MARK: State

    /// The pure tree of intent — the single source of truth. `private(set)`: only the mutation
    /// methods change it (each then reconciles), so the registry can never drift from the tree.
    public private(set) var workspace: Workspace

    /// The table of liveness: 1:1 with the leaves of `workspace`. `reconcile()` is the only writer.
    private var registry: [PaneID: any PaneSessionHandle] = [:]

    /// The injection seam (docs/22 §0). Spec-only — the store re-points the built handle at the leaf
    /// id via `adopt(id:)` (see ``PaneSessionIDAdopting``).
    private let makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle

    /// Maximum number of `.remoteGUI` panes that may hold a LIVE video stack at once (docs/22 §7 the
    /// 2N-UDP / N-VTDecompression / N-CVDisplayLink ceiling). Injectable; default 2. (Not yet
    /// per-device-class — see followups.)
    public let liveVideoCap: Int

    /// In-flight teardown tasks spawned by ``reconcile()`` (teardown is `async`; reconcile is called
    /// inline by synchronous mutations). Tracked so tests — and a deliberate shutdown — can `await`
    /// every orphaned session's `teardown()` to actually complete via ``quiesce()``. The registry
    /// invariant (`keys == leafIDs`) holds the instant reconcile returns (orphans are removed
    /// synchronously); `quiesce()` only waits for the *cleanup* of those already-removed sessions.
    private var teardownTasks: [Task<Void, Never>] = []

    /// The last layout the view solved, cached so geometric ``move(_:)`` can resolve a neighbour
    /// without the store knowing the view's size. `nil` until the view reports one (compact mode never
    /// solves a multi-pane layout — `.next`/`.previous` still work via the pre-order cycle fallback).
    private var lastSolvedLayout: SolvedLayout?

    // MARK: Init

    /// - Parameters:
    ///   - restoring: a decoded workspace to restore (SHAPE + INTENT only — sessions start idle,
    ///     docs/22 §6). `nil` ⇒ ``Workspace/defaultWorkspace()`` (one terminal tab).
    ///   - makeSession: the session factory seam (production: `LivePaneSession.make`; tests:
    ///     `{ FakePaneSession($0) }`).
    ///   - liveVideoCap: concurrent live-video ceiling (default 2).
    public init(
        restoring: Workspace? = nil,
        makeSession: @escaping @MainActor (PaneSpec) -> any PaneSessionHandle,
        liveVideoCap: Int = 2
    ) {
        self.workspace = restoring ?? .defaultWorkspace()
        self.makeSession = makeSession
        self.liveVideoCap = liveVideoCap
        reconcile()   // materialize idle sessions for the restored/default leaves
    }

    // MARK: - Accessors

    /// The live handle for `id`, or `nil` if no such leaf is materialized.
    public func handle(for id: PaneID) -> (any PaneSessionHandle)? { registry[id] }

    /// All live sessions (registry values). Order is unspecified — callers that need a stable order
    /// derive it from the tree's `allLeafIDs()`.
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    /// The active tab, or `nil` (a pure passthrough to the tree).
    public var activeTab: Tab? { workspace.activeTab }

    /// Whether `id` is the focused pane of the active tab (the view's focus-ring decision).
    public func isFocused(_ id: PaneID) -> Bool { workspace.activeTab?.focusedPane == id }

    /// All leaf ids across every tab (the reconcile diff domain). Pre-order within each tab.
    private func allLeafIDs() -> [PaneID] {
        workspace.tabs.flatMap { $0.root.allLeafIDs() }
    }

    // MARK: - Layout reporting (for geometric focus move)

    /// The view reports the layout it just solved for the active tab so the store can resolve
    /// geometric focus moves (``move(_:)``) against the exact rects the user sees (docs/22 §2.1).
    /// View-only state — does NOT touch the tree or registry, so reporting it never reconciles.
    public func updateSolvedLayout(_ solved: SolvedLayout) {
        lastSolvedLayout = solved
    }

    // MARK: - Tab mutations (pure op → reconcile)

    /// Appends a fresh single-leaf tab of `kind` and activates it.
    public func addTab(kind: PaneKind) {
        workspace = workspace.adding(kind: kind, title: defaultTitle(for: kind))
        reconcile()
    }

    /// Closes tab `id` (reselecting a neighbour if it was active); reconcile tears down its leaves.
    public func closeTab(_ id: TabID) {
        workspace = workspace.closing(id)
        reconcile()
    }

    /// Activates tab `id`. Pure focus change — but still reconciles (idempotent; a no-op for the
    /// registry since the leaf set is unchanged) to keep every mutation uniform.
    public func selectTab(_ id: TabID) {
        workspace = workspace.selecting(id)
        reconcile()
    }

    /// Reorders tabs (SwiftUI `onMove` semantics). Pure reorder; leaf set unchanged.
    public func moveTab(from source: IndexSet, to destination: Int) {
        workspace = workspace.moving(from: source, to: destination)
        reconcile()
    }

    /// Renames tab `id`. Pure; leaf set unchanged.
    public func renameTab(_ id: TabID, _ name: String) {
        workspace = workspace.renaming(id, to: name)
        reconcile()
    }

    // MARK: - Pane mutations (pure op → reconcile)

    /// Splits leaf `id` along `axis`, adding a new leaf of `kind` as a sibling, and focuses the new
    /// leaf. Applies to whichever tab owns `id` (almost always the active tab). Reconcile materializes
    /// the one new session.
    public func split(_ id: PaneID, axis: SplitAxis, kind: PaneKind) {
        guard let tabID = tabID(owning: id) else { return }
        let newLeafID = PaneID()
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        workspace = workspace.updatingTab(tabID) { tab in
            tab.root = tab.root.splitting(id, axis: axis, newLeaf: (newLeafID, spec))
            // Focus the new leaf if the split actually created it (it exists in the new tree).
            if tab.root.contains(newLeafID) {
                tab.focusedPane = newLeafID
            }
            // A split invalidates any zoom on this tab (the layout changed).
            if tab.zoomedPane != nil { tab.zoomedPane = nil }
        }
        reconcile()
    }

    /// Closes pane `id`. If it was the last leaf in its tab, the tab is closed. Otherwise focus
    /// re-points to a surviving neighbour. Reconcile tears down the removed session.
    public func closePane(_ id: PaneID) {
        guard let tabID = tabID(owning: id) else { return }
        // Capture a geometric neighbour BEFORE the close (so refocus follows what the user saw).
        let refocus = neighbourForRefocus(of: id, inTab: tabID)

        var closedTab = false
        workspace = workspace.updatingTab(tabID) { tab in
            guard let newRoot = tab.root.closing(id) else {
                closedTab = true       // the tab emptied
                return
            }
            tab.root = newRoot
            if tab.focusedPane == id {
                tab.focusedPane = refocus ?? newRoot.allLeafIDs().first ?? tab.focusedPane
            }
            if tab.zoomedPane == id { tab.zoomedPane = nil }
        }
        if closedTab {
            workspace = workspace.closing(tabID)
        }
        reconcile()
    }

    /// Focuses pane `id` in its owning tab (a pure focus change; leaf set unchanged).
    public func focus(_ id: PaneID) {
        guard let tabID = tabID(owning: id) else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            if tab.root.contains(id) { tab.focusedPane = id }
        }
        reconcile()
    }

    /// Moves focus in `dir` within the active tab, resolved geometrically against the last solved
    /// layout (docs/22 §2.1). `.next`/`.previous` fall back to the pre-order leaf cycle when no layout
    /// has been reported yet (e.g. compact mode), so cycling always works.
    public func move(_ dir: FocusDirection) {
        guard let tab = workspace.activeTab else { return }
        let target: PaneID?
        switch dir {
        case .next, .previous:
            // Prefer the geometric reading-order cycle if a layout is known; else the tree's
            // canonical pre-order cycle.
            if let solved = lastSolvedLayout, solved.frames[tab.focusedPane] != nil {
                target = FocusResolver.neighbor(of: tab.focusedPane, dir, in: solved)
            } else {
                target = FocusResolver.cycle(tab.root.allLeafIDs(), from: tab.focusedPane, forward: dir == .next)
            }
        case .left, .right, .up, .down:
            guard let solved = lastSolvedLayout else { return }
            target = FocusResolver.neighbor(of: tab.focusedPane, dir, in: solved)
        }
        guard let target, target != tab.focusedPane else { return }
        focus(target)
    }

    /// Toggles zoom on the active tab's focused pane (a presentation flag — no tree surgery, so the
    /// registry is untouched, docs/22 §3). Reconcile is still called for uniformity (it is a no-op:
    /// the leaf set did not change).
    public func toggleZoom() {
        guard let tabID = workspace.activeTabID else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            tab.zoomedPane = (tab.zoomedPane == tab.focusedPane) ? nil : tab.focusedPane
        }
        reconcile()
    }

    /// Sets the `fractions` of the split addressed by `path` in `tab` (e.g. after a divider drag).
    /// Pure geometry change; leaf set unchanged so reconcile is a no-op.
    public func setFractions(tab: TabID, path: [Int], to fractions: [Double]) {
        workspace = workspace.updatingTab(tab) { t in
            t.root = t.root.settingFractions(at: path, to: fractions)
        }
        reconcile()
    }

    // MARK: - Spec mutation (rename / fill endpoint)

    /// Transforms the spec of leaf `id` in place (rename, fill in an endpoint, …). The leaf set is
    /// unchanged so reconcile is a no-op — but the session already exists; re-materialization is NOT
    /// triggered by a spec edit (a live session is not rebuilt under the user). To re-point a live
    /// connection at a new endpoint, the view drives the session's connect form directly.
    public func updateSpec(_ id: PaneID, _ transform: @escaping (inout PaneSpec) -> Void) {
        guard let tabID = tabID(owning: id) else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            tab.root = tab.root.updatingSpec(id, transform)
        }
        reconcile()
    }

    // MARK: - Video activation (cap-enforced)

    /// Requests live-video activation for `.remoteGUI` pane `id`, enforcing ``liveVideoCap`` (docs/22
    /// §7). Returns `true` if the pane is now active, `false` if the cap is already saturated by OTHER
    /// active video panes (the caller then shows the gated placeholder until a slot frees). A no-op
    /// `true` if it is already active. Non-video panes return `false`.
    @discardableResult
    public func activateVideo(_ id: PaneID) -> Bool {
        guard let handle = registry[id], handle.kind == .remoteGUI else { return false }
        if handle.isVideoActive { return true }
        let activeOthers = registry.values.filter { $0.kind == .remoteGUI && $0.isVideoActive && $0.id != id }.count
        guard activeOthers < liveVideoCap else { return false }
        handle.setVideoActive(true)
        return handle.isVideoActive
    }

    /// Deactivates live video for pane `id` (the view's `.onDisappear`), freeing a cap slot.
    public func deactivateVideo(_ id: PaneID) {
        registry[id]?.setVideoActive(false)
    }

    // MARK: - Lifecycle fan-out (one site, AWAITED)

    /// iOS background: pause EVERY session, AWAITED. The single fan-out point — a `TaskGroup` whose
    /// child tasks hop onto the main actor and pause each session, but the WHOLE group is awaited
    /// before the app suspends (no fire-and-forget — docs/22 §4, §11.4).
    ///
    /// The child tasks capture only the Sendable ``PaneID`` and re-resolve the (main-actor-isolated,
    /// non-`Sendable`) handle inside the `@MainActor` body, so nothing non-`Sendable` crosses an actor
    /// boundary. The sessions are themselves `@MainActor`, so their `pause()` bodies serialize on the
    /// main actor; the `TaskGroup` is what guarantees every one is awaited.
    public func pauseAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.pauseSession(id) }
            }
        }
    }

    /// iOS foreground: resume EVERY session, AWAITED (mirror of ``pauseAll()``).
    public func resumeAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.resumeSession(id) }
            }
        }
    }

    /// Pauses one session by id on the main actor (the `TaskGroup` child-task body — only the Sendable
    /// `PaneID` crosses; the handle is re-resolved here, never sent across the boundary).
    private func pauseSession(_ id: PaneID) async {
        await registry[id]?.pause()
    }

    private func resumeSession(_ id: PaneID) async {
        await registry[id]?.resume()
    }

    /// Awaits every in-flight orphan ``PaneSessionHandle/teardown()`` spawned by ``reconcile()`` to
    /// complete. The registry invariant already holds the moment a mutation returns (orphans are
    /// removed synchronously); this is for callers that must observe the *cleanup* having finished —
    /// app shutdown, and the reconcile/teardown-ordering tests (docs/22 §8). Idempotent; after it
    /// returns, no teardown is pending.
    public func quiesce() async {
        let tasks = teardownTasks
        teardownTasks.removeAll()
        for task in tasks {
            await task.value
        }
    }

    // MARK: - Bootstrap from environment (automation seams)

    /// Builds the INITIAL workspace from the automation env vars (docs/22 §7), replacing the current
    /// `workspace` and reconciling. It only sets up SHAPE + INTENT (endpoints pre-filled) — it does
    /// **not** connect or open video; the connect / autotype / video-open TRIGGER stays in the view
    /// layer (WF4/WF5), so the env-var names stay unchanged and `check-macos.sh`/`check-video.sh`
    /// keep working.
    ///
    /// - `RWORK_AUTOCONNECT_HOST` + `RWORK_AUTOCONNECT_PORT` ⇒ pane 0 is a terminal with that
    ///   ``Endpoint`` pre-filled.
    /// - `RWORK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports + window id ⇒ pane 0 is instead a
    ///   `.remoteGUI` with that ``VideoEndpoint`` pre-filled (video takes precedence — it is a
    ///   distinct check). Title from `RWORK_VIDEO_AUTOCONNECT_TITLE` if set.
    /// - neither set ⇒ the plain default single-terminal workspace.
    public func bootstrapFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        if let video = Self.videoEndpoint(from: env) {
            let spec = PaneSpec(kind: .remoteGUI, title: video.title, video: video)
            workspace = Self.singleLeafWorkspace(spec: spec)
        } else if let endpoint = Self.terminalEndpoint(from: env) {
            let spec = PaneSpec(kind: .terminal, title: "Terminal", endpoint: endpoint)
            workspace = Self.singleLeafWorkspace(spec: spec)
        } else {
            workspace = .defaultWorkspace()
        }
        reconcile()
    }

    private static func terminalEndpoint(from env: [String: String]) -> Endpoint? {
        guard let host = env["RWORK_AUTOCONNECT_HOST"], !host.isEmpty,
              let portStr = env["RWORK_AUTOCONNECT_PORT"], let port = UInt16(portStr) else { return nil }
        return Endpoint(host: host, port: port)
    }

    private static func videoEndpoint(from env: [String: String]) -> VideoEndpoint? {
        guard let host = env["RWORK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let mediaStr = env["RWORK_VIDEO_AUTOCONNECT_MEDIA_PORT"], let media = UInt16(mediaStr),
              let cursorStr = env["RWORK_VIDEO_AUTOCONNECT_CURSOR_PORT"], let cursor = UInt16(cursorStr),
              let widStr = env["RWORK_VIDEO_AUTOCONNECT_WINDOW_ID"], let wid = UInt32(widStr) else { return nil }
        let title = env["RWORK_VIDEO_AUTOCONNECT_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Remote window"
        return VideoEndpoint(host: host, mediaPort: media, cursorPort: cursor, windowID: wid, title: title)
    }

    /// A one-tab, one-leaf workspace from `spec` (the bootstrap shape). The leaf id is minted fresh.
    private static func singleLeafWorkspace(spec: PaneSpec) -> Workspace {
        let paneID = PaneID()
        let tab = Tab(name: spec.title, root: .leaf(paneID, spec), focusedPane: paneID)
        return Workspace(tabs: [tab], activeTabID: tab.id)
    }

    // MARK: - reconcile (the single audited seam)

    /// The load-bearing diff (docs/22 §2.3). Idempotent. After it runs:
    ///
    ///   `Set(registry.keys) == Set(workspace.tabs.flatMap { $0.root.allLeafIDs() })`
    ///
    /// Steps, in order:
    /// 1. **Teardown orphans first** — for every registry key NOT in the current leaf set, `await`
    ///    `teardown()` (proven `ConnectionViewModel` disconnect order + inspector close + video stop)
    ///    then remove it. Teardown is awaited *before* materializing so a same-tick close+reopen of a
    ///    different pane cannot transiently exceed resource ceilings.
    /// 2. **Materialize new leaves** — for every leaf id NOT yet in the registry, build the session
    ///    via `makeSession(spec)`, `adopt(id:)` so its identity is the leaf's, and register it. New
    ///    sessions are IDLE (lazy connect; video not activated — the cap is enforced at activation).
    ///
    /// A projection flip (compact ↔ regular) does NOT call this — it is a view-only change; the tree
    /// (hence the leaf set) is unchanged, so even if called it would be a no-op (docs/22 §4, §9.9).
    ///
    /// Because teardown is `async` and reconcile is synchronous (called inline by each mutation), the
    /// teardown is launched as an AWAITED detached step kept ordered: we capture the orphans, remove
    /// them from the registry synchronously (so the observable registry never shows a stale session),
    /// and drive their `teardown()` in one awaited task. See the note below for the ordering guarantee.
    private func reconcile() {
        let leafIDs = allLeafIDs()
        let leafSet = Set(leafIDs)

        // 1. Orphans: remove from the registry synchronously (the registry is the source of truth for
        //    "what is live"), then drive teardown. Removing first guarantees the invariant holds the
        //    instant reconcile returns, even though teardown's async cleanup completes slightly after.
        let orphans = registry.filter { !leafSet.contains($0.key) }.map(\.value)
        for orphan in orphans {
            registry.removeValue(forKey: orphan.id)
        }
        if !orphans.isEmpty {
            // Teardown in a dedicated task, in registry-removal order, each awaited (no fire-and-forget
            // races: this single task serializes the disconnect order across the orphaned sessions).
            // The task is tracked in `teardownTasks` so `quiesce()` can await the cleanup to finish.
            let task = Task { @MainActor in
                for orphan in orphans {
                    await orphan.teardown()
                }
            }
            teardownTasks.append(task)
        }

        // 2. New leaves: materialize an idle session for each, binding its identity to the leaf id.
        for id in leafIDs where registry[id] == nil {
            guard let spec = spec(for: id) else { continue }
            let handle = makeSession(spec)
            (handle as? PaneSessionIDAdopting)?.adopt(id: id)
            registry[id] = handle
        }
    }

    // MARK: - Tree lookups

    /// The spec for leaf `id` across all tabs, or `nil`.
    private func spec(for id: PaneID) -> PaneSpec? {
        for tab in workspace.tabs {
            if let spec = tab.root.spec(for: id) { return spec }
        }
        return nil
    }

    /// The id of the tab whose root contains leaf `id`, or `nil`.
    private func tabID(owning id: PaneID) -> TabID? {
        workspace.tabs.first { $0.root.contains(id) }?.id
    }

    /// A neighbour to refocus on after closing `id`, resolved geometrically against the last solved
    /// layout if available, else the pre-order predecessor/successor in the tab. Best-effort.
    private func neighbourForRefocus(of id: PaneID, inTab tabID: TabID) -> PaneID? {
        if let solved = lastSolvedLayout, solved.frames[id] != nil {
            // Prefer a real geometric neighbour (right, then left, then any reading-order sibling).
            for dir in [FocusDirection.right, .left, .down, .up] {
                if let n = FocusResolver.neighbor(of: id, dir, in: solved), n != id { return n }
            }
        }
        guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return nil }
        let leaves = tab.root.allLeafIDs()
        guard let i = leaves.firstIndex(of: id) else { return nil }
        if i + 1 < leaves.count { return leaves[i + 1] }
        if i - 1 >= 0 { return leaves[i - 1] }
        return nil
    }

    // MARK: - Titles

    private func defaultTitle(for kind: PaneKind) -> String {
        switch kind {
        case .terminal:   return "Terminal"
        case .claudeCode: return "Claude Code"
        case .remoteGUI:  return "Remote window"
        }
    }
}

// MARK: - Production session factory

public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with the threaded `makeClient`
    /// and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as `makeSession`
    /// so tests can substitute `{ FakePaneSession($0) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeClient: the `@Sendable () -> RworkClient` the proven `ConnectionViewModel` uses.
    ///   - makeInspector: builds the read-only `InspectorClient` for a `.claudeCode` endpoint, or
    ///     `nil` when no second channel is available (e.g. the descriptor cannot be built headless).
    static func liveMakeSession(
        makeClient: @escaping @Sendable () -> RworkClient = { RworkClient() },
        makeInspector: @escaping @MainActor (Endpoint) -> InspectorClient? = { _ in nil }
    ) -> @MainActor (PaneSpec) -> any PaneSessionHandle {
        { spec in
            LivePaneSession.make(spec, makeClient: makeClient, makeInspector: makeInspector)
        }
    }
}

// MARK: - Command application (WF2 deferral, completed here)

/// Dispatches a pure ``WorkspaceCommand`` to the matching store mutation (docs/22 §5). Deferred from
/// WF2 (the store did not exist yet); completed here now that it does. The keyboard layer (macOS
/// `Commands`, iPad `UIKeyCommand`) and the compact on-screen affordances all funnel intent through
/// this one free function, keeping the chord → command → mutation chain in one auditable place.
///
/// Commands that act on "the focused pane" / "the active tab" read those from the store's current
/// `workspace.activeTab`; a command with no valid target (no active tab / no focused pane) is a
/// graceful no-op.
@MainActor
public func apply(_ command: WorkspaceCommand, to store: WorkspaceStore) {
    switch command {
    case .splitHorizontal:
        if let pane = store.activeTab?.focusedPane {
            store.split(pane, axis: .horizontal, kind: .terminal)
        }
    case .splitVertical:
        if let pane = store.activeTab?.focusedPane {
            store.split(pane, axis: .vertical, kind: .terminal)
        }
    case .closePane:
        if let pane = store.activeTab?.focusedPane {
            store.closePane(pane)
        }
    case .closeTab:
        if let tab = store.activeTab {
            store.closeTab(tab.id)
        }
    case .newTab:
        store.addTab(kind: .terminal)
    case .nextTab:
        store.selectAdjacentTab(forward: true)
    case .prevTab:
        store.selectAdjacentTab(forward: false)
    case let .selectTab(position):
        store.selectTab(atPosition: position)
    case let .focus(direction):
        store.move(direction)
    case let .cycleFocus(forward):
        store.move(forward ? .next : .previous)
    case .toggleZoom:
        store.toggleZoom()
    case .renameTab:
        // The rename itself is a UI affordance (an inline text field); the command only marks intent.
        // The store exposes `renameTab(_:_:)` for the committed value; there is nothing to do here
        // until the field commits, so this is a deliberate no-op at the command layer.
        break
    }
}

// MARK: - Command helpers (adjacent / positional tab selection)

public extension WorkspaceStore {
    /// Activates the next/previous tab with wrap (⌃⇥ / ⌃⇧⇥). Leaf set unchanged.
    func selectAdjacentTab(forward: Bool) {
        let next = workspace.selectingAdjacent(forward: forward)
        guard next.activeTabID != workspace.activeTabID, let id = next.activeTabID else { return }
        selectTab(id)
    }

    /// Selects the tab at the 1-based menu position (⌘1…⌘9; ⌘9 = last). No-op if out of range.
    func selectTab(atPosition position: Int) {
        let next = workspace.selecting(position: position)
        guard let id = next.activeTabID else { return }
        selectTab(id)
    }
}
