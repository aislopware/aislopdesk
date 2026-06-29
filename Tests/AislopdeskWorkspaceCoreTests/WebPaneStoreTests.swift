import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E18 — `PaneKind.web` plumbing.
///
/// This file owns the WI-2 PERSISTENCE half: the additive `PaneSpec.webURL` field (schema v11, no version
/// bump — the `floatingFrame` pattern) round-trips, an old file without the key decodes `nil`, and a whole
/// `TreeWorkspace` carrying a `.web` leaf restores its address through the Session spec table. The store
/// INGRESS half (`openWebPane` newTab/split materializing a sessionless `.web` leaf, `setPaneWebURL`
/// write-back) is added by WI-3 to this same class.
///
/// Contract (revert-to-confirm-fail): on the un-fixed `PaneSpec` (no `webURL` field) (a) fails — the
/// round-trip drops the address → unequal — and (c) fails — the restored spec has no address to read. (b)
/// is the decode-fail-to-default regression guard. The WI-3 INGRESS tests below (`openWebPane` /
/// `setPaneWebURL`) fail to even COMPILE on the un-fixed store (the methods do not exist).
@MainActor
final class WebPaneStoreTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private let decoder = JSONDecoder()

    /// A live tree-model store whose sessions are headless fakes (no socket, no `WKWebView`) — the same
    /// seam `WorkspaceStoreProgressTests` / `DockTintPolicyTests` use.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    // MARK: (a) PaneSpec round-trips the web address

    func testPaneSpecRoundTripsWebURL() throws {
        let spec = PaneSpec(kind: .web, title: "Web", webURL: "https://example.com/path?q=1")
        let restored = try decoder.decode(PaneSpec.self, from: makeEncoder().encode(spec))
        XCTAssertEqual(restored, spec)
        XCTAssertEqual(restored.webURL, "https://example.com/path?q=1", "the persisted address survives")
        XCTAssertEqual(restored.kind, .web)
    }

    // MARK: (b) a spec without the key decodes nil (legacy / non-web pane)

    func testPaneSpecWithoutWebURLDecodesNil() throws {
        // A minimal v11-era spec JSON written before this field existed: kind + title only, NO webURL key.
        let json = #"{ "kind": "terminal", "title": "Terminal" }"#
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        XCTAssertNil(spec.webURL, "an old spec without the key decodes nil (no address)")
        XCTAssertEqual(spec.kind, .terminal)
    }

    // MARK: (c) survives a whole TreeWorkspace round-trip via the Session spec table

    func testWebPaneSurvivesWorkspaceRoundTrip() throws {
        let ws = TreeWorkspace.singlePane(
            spec: PaneSpec(kind: .web, title: "Web", webURL: "https://duckduckgo.com/"),
        )
        let paneID = ws.allPaneIDs()[0]

        let data = try makeEncoder().encode(ws)
        let restored = try decoder.decode(TreeWorkspace.self, from: data)

        let spec = try XCTUnwrap(restored.spec(for: paneID), "the web leaf survives the round-trip")
        XCTAssertEqual(spec.kind, .web, "the restored leaf is still a web pane")
        XCTAssertEqual(spec.webURL, "https://duckduckgo.com/", "the web address survives persistence")
    }

    // MARK: (d) openWebPane .newTab — a new tab whose lone leaf is a SESSIONLESS web pane

    func testOpenWebPaneNewTabMaterializesSessionlessWebLeaf() throws {
        let store = makeStore()
        let url = try XCTUnwrap(WebURLNormalizer.normalize("https://example.com/"))
        let before = Set(store.tree.allPaneIDs())

        store.openWebPane(url: url, placement: .newTab)

        let new = try XCTUnwrap(
            store.tree.allPaneIDs().first { !before.contains($0) },
            "openWebPane(.newTab) adds a new leaf",
        )
        let spec = try XCTUnwrap(store.tree.spec(for: new))
        XCTAssertEqual(spec.kind, .web, "the new leaf is a web pane")
        XCTAssertEqual(spec.webURL, "https://example.com/", "the address is stamped on it")
        XCTAssertNil(store.handle(for: new), "a web pane materializes NO host session (reconcile skips it)")
    }

    // MARK: (e) openWebPane .split — splits the active pane; the original keeps its live session

    func testOpenWebPaneSplitMaterializesSessionlessWebLeaf() throws {
        let store = makeStore()
        let original = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertNotNil(store.handle(for: original), "precondition: the seeded terminal has a live session")
        let url = try XCTUnwrap(WebURLNormalizer.normalize("duckduckgo.com"))
        let before = Set(store.tree.allPaneIDs())

        store.openWebPane(url: url, placement: .split(leading: false))

        let leaves = store.tree.allPaneIDs()
        XCTAssertEqual(leaves.count, before.count + 1, "the split added exactly one leaf")
        let new = try XCTUnwrap(leaves.first { !before.contains($0) })
        let spec = try XCTUnwrap(store.tree.spec(for: new))
        XCTAssertEqual(spec.kind, .web)
        XCTAssertEqual(spec.webURL, "https://duckduckgo.com", "the normalized bare host is stamped")
        XCTAssertNil(store.handle(for: new), "the web pane has no live session")
        XCTAssertNotNil(store.handle(for: original), "the split did NOT replace the original live terminal")
    }

    // MARK: (f) openWebPane .current — sessionless web pane navigates IN PLACE (same id, no new leaf)

    func testOpenWebPaneCurrentNavigatesSessionlessWebPaneInPlace() throws {
        let store = makeStore()
        // First open a web pane in a new tab — it is sessionless and now the active pane.
        let before = Set(store.tree.allPaneIDs())
        try store.openWebPane(url: XCTUnwrap(WebURLNormalizer.normalize("example.com")), placement: .newTab)
        let webPane = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) })
        XCTAssertNil(store.handle(for: webPane), "the web pane is sessionless")
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, webPane, "a new tab is selected")
        let leafCount = store.tree.allPaneIDs().count

        // .current on the (sessionless) active web pane NAVIGATES it in place — no new leaf, same id.
        let next = try XCTUnwrap(WebURLNormalizer.normalize("https://example.org/page2"))
        store.openWebPane(url: next, placement: .current)
        XCTAssertEqual(store.tree.allPaneIDs().count, leafCount, "in-place navigation adds no leaf")
        XCTAssertEqual(store.tree.spec(for: webPane)?.kind, .web)
        XCTAssertEqual(store.tree.spec(for: webPane)?.webURL, "https://example.org/page2", "navigated in place")
    }

    // MARK: (g) openWebPane .current on a LIVE terminal must NOT strand its session — opens a new tab

    func testOpenWebPaneCurrentOnLiveTerminalOpensNewTabInstead() throws {
        let store = makeStore()
        let terminal = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertEqual(store.tree.spec(for: terminal)?.kind, .terminal, "precondition: active pane is a terminal")
        XCTAssertNotNil(store.handle(for: terminal), "precondition: it has a live session")
        let before = Set(store.tree.allPaneIDs())

        try store.openWebPane(url: XCTUnwrap(WebURLNormalizer.normalize("example.com")), placement: .current)

        // The live terminal is preserved (a kind-flip would strand its session: reconcile diffs by id).
        XCTAssertEqual(store.tree.spec(for: terminal)?.kind, .terminal, "the live terminal is NOT replaced")
        XCTAssertNotNil(store.handle(for: terminal), "its session is intact")
        let new = try XCTUnwrap(
            store.tree.allPaneIDs().first { !before.contains($0) },
            "the URL opened in a new web leaf instead",
        )
        XCTAssertEqual(store.tree.spec(for: new)?.kind, .web)
        XCTAssertEqual(store.tree.spec(for: new)?.webURL, "https://example.com")
    }

    // MARK: (h) setPaneWebURL write-back + dirty guard

    func testSetPaneWebURLWriteBackIsDirtyGuarded() throws {
        let store = makeStore()
        let before = Set(store.tree.allPaneIDs())
        try store.openWebPane(url: XCTUnwrap(WebURLNormalizer.normalize("example.com")), placement: .newTab)
        let webPane = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) })
        XCTAssertEqual(store.tree.spec(for: webPane)?.webURL, "https://example.com")

        store.setPaneWebURL("https://example.com/page2", for: webPane)
        XCTAssertEqual(store.tree.spec(for: webPane)?.webURL, "https://example.com/page2", "navigation writes back")

        // Idempotent: re-stamping the SAME address leaves it unchanged (the dirty guard, like setLastKnownCwd).
        store.setPaneWebURL("https://example.com/page2", for: webPane)
        XCTAssertEqual(store.tree.spec(for: webPane)?.webURL, "https://example.com/page2")
    }

    // MARK: (h2) setPaneWebTitle write-back + dirty guard (E18 M1)

    /// The loaded page's `<title>` flows through ``WebPaneContext/onTitle`` → `setPaneWebTitle` into the
    /// spec's `lastKnownTitle` (the field the rail + titlebar resolve ahead of the static "Web" default), and
    /// is DIRTY-GUARDED like `setPaneWebURL`. Revert-to-confirm-fail: on the un-fixed store `setPaneWebTitle`
    /// does not exist, so this fails to COMPILE (the same idiom as the WI-3 ingress tests above).
    func testSetPaneWebTitleWriteBackIsDirtyGuarded() throws {
        let store = makeStore()
        let before = Set(store.tree.allPaneIDs())
        try store.openWebPane(url: XCTUnwrap(WebURLNormalizer.normalize("example.com")), placement: .newTab)
        let webPane = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) })
        XCTAssertNil(store.tree.spec(for: webPane)?.lastKnownTitle, "no live page title yet — only the default")

        store.setPaneWebTitle("Example Domain", for: webPane)
        XCTAssertEqual(
            store.tree.spec(for: webPane)?.lastKnownTitle, "Example Domain",
            "the loaded page <title> writes back into lastKnownTitle (rail resolves lastKnownTitle ?? title)",
        )
        // The page title does NOT overwrite the user-visible `title` default — only `lastKnownTitle`.
        XCTAssertEqual(store.tree.spec(for: webPane)?.title, PaneChooserRegistry.option(for: .web).title)

        // Idempotent: re-stamping the SAME title leaves it unchanged (the dirty guard, like setPaneWebURL).
        store.setPaneWebTitle("Example Domain", for: webPane)
        XCTAssertEqual(store.tree.spec(for: webPane)?.lastKnownTitle, "Example Domain")
    }

    // MARK: (i) drop actuation — newTabCd opens a terminal rooted at the dropped folder (E18 WI-6)

    /// Drains the deferred (0 ms-grace) drop `cd` send by yielding the main actor until `fake` records bytes
    /// or the budget runs out (mirrors `CwdInheritanceStoreTests.waitForBytes`).
    private func waitForBytes(_ fake: FakePaneSession?) async {
        for _ in 0..<200 {
            if (fake?.sentBytes.count ?? 0) > 0 { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// ES-E18-2 / test #8: a dropped folder on the New-Tab zone (`DropAction.newTabCd`) opens a fresh
    /// TERMINAL tab and `cd`s it to the dropped path — falling back to the path's PARENT (a dropped FILE →
    /// its containing folder) via ``LinkActionPolicy/changeDirectoryCommandLine(_:)`` — sent VERBATIM through
    /// the new pane's `FakePaneSession` sink, NEVER `SendKeysParser`. `home` new-tab policy ⇒ the new tab
    /// inherits NO cwd, so the drop `cd` is the ONLY thing the fresh terminal sees and the exact line can be
    /// pinned. Revert-to-confirm-fail: on the un-fixed store `openTerminalRooted` does not exist (the test
    /// fails to compile); a `SendKeysParser` path would also yield different bytes.
    func testOpenTerminalRootedNewTabSendsParentFallbackCd() async throws {
        UserDefaults.standard.set("home", forKey: SettingsKey.workingDirectoryNewTabKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.workingDirectoryNewTabKey) }

        let store = makeStore()
        let before = Set(store.tree.allPaneIDs())

        store.openTerminalRooted(at: "/Users/me/project", split: false, leading: false, launchGrace: .zero)

        let new = try XCTUnwrap(
            store.tree.allPaneIDs().first { !before.contains($0) },
            "openTerminalRooted(.newTab) adds a leaf",
        )
        XCTAssertEqual(store.tree.spec(for: new)?.kind, .terminal, "the dropped folder opens a terminal")
        let fake = store.handle(for: new) as? FakePaneSession
        await waitForBytes(fake)

        XCTAssertEqual(
            fake?.sentBytes,
            [Array("cd '/Users/me/project' 2>/dev/null || cd '/Users/me'\n".utf8)],
            "the new tab cd's to the dropped path, falling back to its parent — VERBATIM, not SendKeysParser",
        )
    }

    /// The split sibling (`DropAction.splitInjectPath`): the dropped path opens beside the active pane and the
    /// NEW split pane (only it) receives the `cd … || cd <parent>` line; the original terminal gets nothing.
    func testOpenTerminalRootedSplitSendsCdToTheNewPaneOnly() async throws {
        UserDefaults.standard.set("home", forKey: SettingsKey.workingDirectoryNewSplitKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.workingDirectoryNewSplitKey) }

        let store = makeStore()
        let original = try XCTUnwrap(store.tree.allPaneIDs().first)
        let before = Set(store.tree.allPaneIDs())

        store.openTerminalRooted(at: "/srv/app/main.swift", split: true, leading: false, launchGrace: .zero)

        let new = try XCTUnwrap(store.tree.allPaneIDs().first { !before.contains($0) }, "the split adds one leaf")
        let fake = store.handle(for: new) as? FakePaneSession
        await waitForBytes(fake)

        XCTAssertEqual(
            fake?.sentBytes,
            [Array("cd '/srv/app/main.swift' 2>/dev/null || cd '/srv/app'\n".utf8)],
            "the split pane cd's to the dropped path (file → parent fallback)",
        )
        XCTAssertEqual(
            (store.handle(for: original) as? FakePaneSession)?.sentBytes ?? [], [],
            "the original terminal receives nothing — the drop `cd` targets only the new pane",
        )
    }

    /// Batch-4 item 9 — the Open-Quickly Folder "Split Down" action passes `axis: .vertical` to
    /// `openTerminalRooted`, which must split the active pane VERTICALLY (a stacked split), not horizontally.
    /// Revert-to-confirm-fail: on the un-fixed store `openTerminalRooted` has NO `axis` parameter (the call
    /// fails to compile) and always split `.horizontal`.
    func testOpenTerminalRootedSplitDownIsAVerticalSplit() throws {
        let store = makeStore()
        store.openTerminalRooted(at: "/srv/app", split: true, leading: false, axis: .vertical, launchGrace: .zero)

        let root = try XCTUnwrap(store.tree.activeSession?.activeTab?.root, "the active tab has a root")
        guard case let .split(_, axis, children) = root else {
            XCTFail("Split Down produces a split node at the tab root, not a bare leaf")
            return
        }
        XCTAssertEqual(axis, .vertical, "Split Down splits the active pane vertically (axis: .vertical)")
        XCTAssertEqual(children.count, 2, "the split has the original pane + the new folder terminal")
    }
}
