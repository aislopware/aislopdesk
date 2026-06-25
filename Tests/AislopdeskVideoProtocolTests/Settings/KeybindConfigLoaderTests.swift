import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// E1/WI-6 (production wiring) — pins for ``KeybindConfigLoader``, the config-file → ``KeybindingPreferences``
/// population path that makes the `text:` / `csi:` / `esc:` / `unbind:` half of ES-E1-6 reachable end-to-end.
/// Before this loader existed NOTHING wrote ``KeybindingPreferences/textBindings`` / ``unbinds`` from a real
/// user-facing source, so the dispatcher's text-binding / unbind branch was dead code in practice; these
/// tests FAIL to compile/run against that earlier tree (the type did not exist) and prove the fold here.
final class KeybindConfigLoaderTests: XCTestCase {
    // MARK: text: / csi: / esc: → textBindings (the literal-byte half)

    /// `keybind = cmd+shift+h:text:hi` populates `textBindings` on the ⌘⇧H chord with the literal bytes — so
    /// after publishing into `activeOverrides` a ⌘⇧H keystroke injects `[h, i]` (the ES-E1-6 acceptance).
    func testTextBindingIsFoldedIntoTextBindings() {
        let prefs = KeybindConfigLoader.apply(configText: "keybind = cmd+shift+h:text:hi")
        let chord = KeybindingPreferences.KeyChord(key: "h", command: true, shift: true)
        XCTAssertEqual(prefs.textBindings[chord], .init(kind: .text, payload: [0x68, 0x69]))
        XCTAssertTrue(prefs.unbinds.isEmpty)
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    /// `csi:` / `esc:` route into `textBindings` with the ESC / ESC-`[` lead bytes already resolved (the
    /// dispatcher hands `payload` straight to `sendBytes`) and the matching `Kind` recorded for the UI.
    func testCSIAndEscBindingsFoldWithLeadBytes() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+pageup:csi:5~
            keybind = opt+o:esc:O
            """,
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "pageup", command: true)],
            .init(kind: .csi, payload: [0x1B, 0x5B, 0x35, 0x7E]),
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "o", option: true)],
            .init(kind: .esc, payload: [0x1B, 0x4F]),
        )
    }

    // MARK: unbind: → unbinds (the disable-a-default half)

    /// `keybind = unbind:cmd+d` inserts ⌘D into `unbinds` so the dispatcher passes the chord through instead
    /// of firing the default split-right action (the ES-E1-6 "an unbind: directive disables a default").
    func testUnbindIsFoldedIntoUnbinds() {
        let prefs = KeybindConfigLoader.apply(configText: "keybind = unbind:cmd+d")
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "d", command: true)))
        XCTAssertTrue(prefs.textBindings.isEmpty)
    }

    // MARK: lenient flat-config dialect (otty config-file format)

    /// Blank lines, `#` comments, OTHER config keys (silently ignored), lenient `=` whitespace, and an
    /// optional quoted value all parse — only `keybind` lines contribute, every other key is dropped.
    func testLenientDialectIgnoresCommentsBlanksAndOtherKeys() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            # a comment line

            font-size = 14
            theme = Nord
            keybind=cmd+shift+h:text:hi
            keybind = "ctrl+a:text:x"
            """,
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
        XCTAssertEqual(prefs.textBindings[.init(key: "a", control: true)]?.payload, [0x78])
        // No `font-size` / `theme` key leaked into any override map.
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    /// A malformed `keybind` line is DROPPED (validate-then-drop) and does NOT abort the load — the
    /// well-formed line on the next row still folds. Revert-to-confirm-fail: deleting the parse guard would
    /// make the bad line crash / poison the whole load.
    func testMalformedLineIsDroppedAndRestStillLoads() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = badmod+h:text:nope
            keybind = cmd+shift+h:text:hi
            """,
        )
        XCTAssertEqual(prefs.textBindings.count, 1)
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// Later `keybind` on the same chord wins (last-writer-wins within the file).
    func testLastWriterWinsOnTheSameChord() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+shift+h:text:aa
            keybind = cmd+shift+h:text:bb
            """,
        )
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x62, 0x62],
        )
    }

    // MARK: merge into an existing base + named-action hook

    /// Folding preserves the `base` prefs (existing single-chord overrides / sequence overrides survive) and
    /// the file's text bindings are layered on top.
    func testFoldPreservesBaseOverrides() {
        let base = KeybindingPreferences(overrides: ["pane.splitRight": .init(key: "k", command: true)])
        let prefs = KeybindConfigLoader.apply(configText: "keybind = cmd+shift+h:text:hi", to: base)
        XCTAssertEqual(prefs.overrides["pane.splitRight"], .init(key: "k", command: true))
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    /// A NAMED action (`goto_tab:1`) is routed through the caller-supplied `resolveNamedBinding` hook into
    /// `overrides` (the registry lives in another module, so the loader cannot resolve the id itself). When
    /// the hook returns `nil` (unknown action), the named line is dropped.
    func testNamedActionRoutesThroughResolverHook() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+1:goto_tab:1
            keybind = cmd+2:unknown_action
            """,
            resolveNamedBinding: { named in
                guard named.id == "goto_tab", let arg = named.arg else { return nil }
                return (bindingID: "tab.select.\(arg)", chord: named.chord)
            },
        )
        XCTAssertEqual(prefs.overrides["tab.select.1"], .init(key: "1", command: true))
        // The unknown action resolved to nil ⇒ dropped, no stray override.
        XCTAssertEqual(prefs.overrides.count, 1)
    }

    /// With NO resolver supplied, named-action lines are simply dropped (the text/unbind directives are still
    /// honoured — they need no registry). This is the launch-time default for the ES-E1-6 wiring.
    func testNamedActionDroppedWithoutResolver() {
        let prefs = KeybindConfigLoader.apply(
            configText: """
            keybind = cmd+1:goto_tab:1
            keybind = unbind:cmd+q
            """,
        )
        XCTAssertTrue(prefs.overrides.isEmpty)
        XCTAssertTrue(prefs.unbinds.contains(.init(key: "q", command: true)))
    }

    // MARK: file I/O entry (missing / present)

    /// A MISSING file returns `base` unchanged (a fresh install authored no config ⇒ behaviour-identical).
    func testMissingFileReturnsBaseUnchanged() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-no-such-\(UUID().uuidString).toml")
        let base = KeybindingPreferences(unbinds: [.init(key: "z", command: true)])
        XCTAssertEqual(KeybindConfigLoader.loadFile(at: url, into: base), base)
    }

    /// A real on-disk file is read and folded — the full path the app launch uses (sans the default URL).
    func testFileOnDiskIsLoadedAndFolded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-config-\(UUID().uuidString).toml")
        try "keybind = cmd+shift+h:text:hi\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = KeybindConfigLoader.loadFile(at: url)
        XCTAssertEqual(
            prefs.textBindings[.init(key: "h", command: true, shift: true)]?.payload, [0x68, 0x69],
        )
    }

    // MARK: default config URL resolution

    /// `XDG_CONFIG_HOME` wins; else `$HOME/.config`; the file is `aislopdesk/config.toml`.
    func testDefaultConfigURLHonoursXDGThenHome() {
        let xdg = KeybindConfigLoader.defaultConfigURL(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"])
        XCTAssertEqual(xdg?.path, "/tmp/cfg/aislopdesk/config.toml")
        let home = KeybindConfigLoader.defaultConfigURL(environment: ["HOME": "/Users/me"])
        XCTAssertEqual(home?.path, "/Users/me/.config/aislopdesk/config.toml")
        XCTAssertNil(KeybindConfigLoader.defaultConfigURL(environment: [:]))
    }
}
