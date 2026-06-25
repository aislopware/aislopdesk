// ThemeStore tests (WS-D / D3) — the runtime theme holder that defeats the STATIC `Otty.theme` across the
// AppKit `NSSplitViewController` boundary. Pure logic only: `apply(_:)` mapping, the default Monokai Pro
// Classic invariant, and the IDENTITY-keyed cross-boundary change notification (so a same-lightness variant
// switch still repaints). NO SCStream/VT/Metal/VideoWindowView is touched.

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskClientUI

@MainActor
final class ThemeStoreTests: XCTestCase {
    /// The default theme is Monokai Pro Classic (dark) — the product default.
    func testDefaultIsMonokaiProClassic() {
        let store = ThemeStore()
        XCTAssertFalse(store.active.isLight, "the default theme is the dark Monokai Pro Classic")
        XCTAssertEqual(store.active.id, "monokai-classic")
    }

    func testApplyMapsThemeChoiceToTheTheme() {
        let store = ThemeStore()
        store.apply(.monokaiProClassic)
        XCTAssertEqual(store.active.id, "monokai-classic")
        XCTAssertFalse(store.active.isLight, "Monokai Pro Classic is dark")
        store.apply(.monokaiProClassicLight)
        XCTAssertEqual(store.active.id, "monokai-classic-light")
        XCTAssertTrue(store.active.isLight, "Monokai Pro Light is light")
        store.apply(.monokaiProSpectrum)
        XCTAssertEqual(store.active.id, "monokai-spectrum")
        // The legacy palettes still resolve.
        store.apply(.dark)
        XCTAssertFalse(store.active.isLight, ".dark maps to the dark theme")
        store.apply(.paper)
        XCTAssertTrue(store.active.isLight, ".paper maps to the light theme")
        // nil (appearance reset/unset) falls back to the compile-time default Monokai Pro Classic.
        store.active = .dark
        store.apply(nil)
        XCTAssertEqual(store.active.id, "monokai-classic", "nil falls back to the default Monokai Pro Classic")
    }

    /// Each theme carries the libghostty terminal bg/fg matching its chrome window colour (flat design): a
    /// dark variant's terminal background must equal its chrome window hex. Guards the chrome↔terminal sync.
    func testTerminalBackgroundMatchesChromeWindow() {
        // Monokai Classic chrome window is #2D2A2E ⇒ the terminal background hex is the same, no `#`.
        XCTAssertEqual(OttyTheme.monokaiProClassic.terminalBackgroundHex, "2D2A2E")
        XCTAssertEqual(OttyTheme.monokaiProClassic.terminalForegroundHex, "FCFCFA")
        XCTAssertEqual(OttyTheme.monokaiProSpectrum.terminalBackgroundHex, "222222")
        XCTAssertEqual(OttyTheme.monokaiProClassicLight.terminalBackgroundHex, "FAF4F2")
    }

    /// A theme change posts the cross-`NSHostingController` repaint notification keyed on theme IDENTITY —
    /// so even a SAME-lightness variant switch (Classic → Spectrum, both dark) posts; an idempotent re-apply
    /// of the SAME theme does NOT.
    func testApplyPostsChangeNotificationOnIdentityChange() {
        let store = ThemeStore.shared
        store.active = .monokaiProClassic

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChangeNotification, object: nil, queue: nil,
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.apply(.monokaiProClassic) // no change → no post
        XCTAssertEqual(posts, 0)
        store.apply(.monokaiProSpectrum) // SAME lightness, different variant → one post
        XCTAssertEqual(posts, 1)
        store.apply(.monokaiProSpectrum) // idempotent → no post
        XCTAssertEqual(posts, 1)
        store.apply(.monokaiProClassicLight) // dark → light → one more post
        XCTAssertEqual(posts, 2)
    }
}
#endif
