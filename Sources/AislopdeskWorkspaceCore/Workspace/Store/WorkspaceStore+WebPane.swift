import Foundation

// MARK: - Web-pane store ingress (E18 WI-3)

/// The `WorkspaceStore` entry points for the LOCAL built-in web pane (`PaneKind.web`), factored out of the
/// class body like ``WorkspaceStore`` `+TabOrdering` / `+Attention` so the type stays under the
/// `type_body_length` ceiling.
///
/// A web pane materializes **no live session** (``reconcileTree()`` skips `.web`, exactly like `.chooser`):
/// the `WKWebView` is fully client-side and lives only in the app target behind ``WebRendererFactory``. So
/// the store's job is purely the TREE intent — create/flip a `.web` leaf and stamp/refresh its address —
/// after which `handle(for:)` for that leaf is `nil` and the leaf view renders the browser chrome straight
/// from the spec. The address persists in the additive ``PaneSpec/webURL`` field so a restored pane reopens
/// the same page.
public extension WorkspaceStore {
    /// Opens `url` in a `.web` pane at `placement` — the single ingress the drop actuator (E18 WI-6, a
    /// `.openWeb`/`.splitWeb` ``DropAction``) and the address bar's "open in new tab / split" both call.
    ///
    /// - `.newTab` → a brand-new tab whose lone leaf is the web pane (reuses ``newTab(kind:)``, so it
    ///   honours `new-tab-position`), then stamps the address on it.
    /// - `.split(leading:)` → splits the ACTIVE pane side-by-side (a `.horizontal` column split — Split
    ///   Left/Right; `leading` picks the side) via ``splitActivePane(axis:kind:leading:)``, which focuses
    ///   the new leaf, then stamps the address. No-op if there is no active pane to split.
    /// - `.current` → Open-In-Place on a URL. A **sessionless** active pane (a `.chooser`, or an existing
    ///   `.web` being re-navigated) flips to `.web` in place (same `PaneID`; an already-`.web` pane simply
    ///   NAVIGATES, keeping its title). A **session-backed** active pane (a live `.terminal`/`.remoteGUI`)
    ///   is NOT swapped in place — ``reconcileTree()`` diffs the registry by `PaneID`, not kind, so an
    ///   in-place flip would STRAND the old session (neither orphaned nor re-materialized); the URL opens in
    ///   a new tab instead of silently killing live work. No-op if there is no active pane.
    ///
    /// The newly-created leaf is identified by diffing the leaf set across the op (robust regardless of
    /// which op was used), then `setPaneWebURL` stamps the address through the same dirty-guarded write-back
    /// a live navigation uses.
    func openWebPane(url: URL, placement: WebPanePlacement) {
        let address = url.absoluteString
        switch placement {
        case .current:
            guard let active = tree.activeSession?.activeTab?.activePane else { return }
            // Only a sessionless pane is safe to flip in place (see the doc note on the reconcile-by-id diff).
            if handle(for: active) == nil {
                flipActivePaneToWeb(active, address: address)
            } else {
                openWebInNewTab(address: address)
            }
        case .newTab:
            openWebInNewTab(address: address)
        case let .split(leading):
            guard tree.activeSession?.activeTab?.activePane != nil else { return }
            let before = Set(tree.allPaneIDs())
            splitActivePane(axis: .horizontal, kind: .web, leading: leading)
            if let target = tree.allPaneIDs().first(where: { !before.contains($0) }) {
                setPaneWebURL(address, for: target)
            }
        }
    }

    /// Write-back of a web pane's CURRENT address (E18) — fired by the live `WKWebView`'s navigation
    /// callback through ``WebPaneContext/onNavigated`` so a restored pane reopens the same page. Mirrors
    /// ``setLastKnownCwd(_:for:)``: live-model-aware and DIRTY-GUARDED (an unchanged address spends no
    /// reconcile, so a re-render / repeated navigation to the same URL never churns the tree).
    func setPaneWebURL(_ url: String, for paneID: PaneID) {
        let current: String? =
            switch liveModel {
            case .tree: tree.spec(for: paneID)?.webURL
            case .canvas: workspace.canvas.spec(for: paneID)?.webURL
            }
        guard current != url else { return }
        updateWebSpecLive(paneID) { $0.webURL = url }
    }

    /// Write-back of a web pane's CURRENT page title (E18 M1) — fired by the live `WKWebView`'s `didFinish`
    /// title callback through ``WebPaneContext/onTitle`` so the rail tab + titlebar label the pane after the
    /// loaded page (a web pane is titled after its host, e.g. "localhost"; the rail and
    /// titlebar resolve `lastKnownTitle ?? title`, so the live page title flows in without disturbing the
    /// user-visible default `title`). Mirrors ``setPaneWebURL`` exactly: live-model-aware and DIRTY-GUARDED
    /// (an unchanged title spends no reconcile, so a repeated `didFinish` to the same `<title>` never churns
    /// the tree). The page title rides ``PaneSpec/lastKnownTitle`` — the same field the terminal's live OSC
    /// title uses — NOT `title`, so the static "Web" chooser default survives for the load-time promotion gate.
    func setPaneWebTitle(_ title: String, for paneID: PaneID) {
        let current: String? =
            switch liveModel {
            case .tree: tree.spec(for: paneID)?.lastKnownTitle
            case .canvas: workspace.canvas.spec(for: paneID)?.lastKnownTitle
            }
        guard current != title else { return }
        updateWebSpecLive(paneID) { $0.lastKnownTitle = title }
    }

    // MARK: - Internals

    /// Opens `address` in a brand-new `.web` tab (reusing ``newTab(kind:)``) and stamps the address on the
    /// freshly-created leaf (identified by diffing the leaf set). Shared by `.newTab` and the `.current`
    /// fallback for a live pane.
    private func openWebInNewTab(address: String) {
        let before = Set(tree.allPaneIDs())
        newTab(kind: .web)
        if let target = tree.allPaneIDs().first(where: { !before.contains($0) }) {
            setPaneWebURL(address, for: target)
        }
    }

    /// In-place flip of the (SESSIONLESS — `handle(for:) == nil`) pane `id` to a `.web` pane carrying
    /// `address`. Sets the kind + default title ONLY when the pane is not already `.web` (so navigating an
    /// existing web pane keeps its title); the address is always stamped. Same `PaneID` and no session on
    /// either side, so ``reconcileTree()`` is a registry no-op and the leaf re-renders as the browser. The
    /// caller guarantees the no-session precondition (a live pane would be stranded by a kind-only flip).
    private func flipActivePaneToWeb(_ id: PaneID, address: String) {
        let webTitle = PaneChooserRegistry.option(for: .web).title
        updateWebSpecLive(id) { spec in
            if spec.kind != .web {
                spec.kind = .web
                spec.title = webTitle
            }
            spec.webURL = address
        }
    }

    /// Live-model-aware spec write (the same wire ``setLastKnownCwd(_:for:)`` rides, replicated here because
    /// the class-private `updateSpecLive` is file-scoped to `WorkspaceStore.swift`). Routes the `.web` spec
    /// edit into whichever model is live and reconciles.
    private func updateWebSpecLive(_ id: PaneID, _ transform: @escaping (inout PaneSpec) -> Void) {
        switch liveModel {
        case .tree:
            tree = WorkspaceTreeOps.updatingSpec(id, in: tree, transform)
            reconcileTree()
        case .canvas:
            updateSpec(id, transform)
        }
    }
}
