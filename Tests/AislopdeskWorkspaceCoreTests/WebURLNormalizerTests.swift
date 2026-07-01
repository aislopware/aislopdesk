import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E18 WI-3 — the address-bar / dropped-URL normalizer for the Web Browser pane:
/// a bare host gets `https://` prepended; otherwise it acts as a DuckDuckGo search.
///
/// These pin the validate-then-drop contract: web schemes pass, a bare host gets `https://`, everything
/// else searches, and a dangerous/non-web scheme (`javascript:`/`file:`/…) DROPS to `nil` — the web pane
/// is a local surface, never to be coaxed into a non-web scheme. Pure + headless (no `WKWebView`).
final class WebURLNormalizerTests: XCTestCase {
    // MARK: - Explicit http(s) passes through verbatim

    func testHTTPSURLPassesThrough() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("https://example.com/path?q=1"))
        XCTAssertEqual(url.absoluteString, "https://example.com/path?q=1")
        XCTAssertEqual(url.scheme, "https")
    }

    func testHTTPURLWithPortPassesThrough() throws {
        // The web-broswer.png address bar shows exactly this (an explicit http://localhost:5173/).
        let url = try XCTUnwrap(WebURLNormalizer.normalize("http://localhost:5173/"))
        XCTAssertEqual(url.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.port, 5173)
    }

    // MARK: - Bare host → https:// prepended

    func testBareDottedHostGetsHTTPS() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("example.com"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testBareHostWithPathGetsHTTPS() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("example.com/docs/index.html"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.path, "/docs/index.html")
    }

    /// `localhost:5173` is a HOST with a port, NOT the scheme `localhost:` — the normalizer must not be
    /// fooled by the `:` (revert-to-confirm-fail: a naive scheme split would treat `localhost` as a scheme
    /// and drop it). It gets `https://` since the user typed no scheme.
    func testLocalhostWithPortIsHostNotScheme() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("localhost:5173"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 5173)
    }

    func testDottedHostWithPortAndPathIsHost() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("example.com:8080/path"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.port, 8080)
        XCTAssertEqual(url.path, "/path")
    }

    func testIPv4IsHost() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("192.168.1.10"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "192.168.1.10")
    }

    func testLeadingTrailingWhitespaceTrimmed() throws {
        let url = try XCTUnwrap(WebURLNormalizer.normalize("   example.com   "))
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    // MARK: - Non-host text → DuckDuckGo search

    func testSingleWordSearches() throws {
        // A lone word with no dot is NOT a host — it's a search query (browsers do the same).
        let url = try XCTUnwrap(WebURLNormalizer.normalize("swift"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, WebURLNormalizer.searchHost)
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "q" })?.value, "swift")
    }

    func testPhraseWithSpacesSearches() throws {
        let query = "how to write swift tests"
        let url = try XCTUnwrap(WebURLNormalizer.normalize(query))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.scheme, "https")
        XCTAssertEqual(comps.host, WebURLNormalizer.searchHost)
        // URLComponents percent-encodes the value; the decoded query item round-trips to the raw phrase.
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "q" })?.value, query)
    }

    /// A query that happens to contain a colon but ALSO whitespace is a search, not a dropped scheme — the
    /// inner-whitespace guard wins (revert-to-confirm-fail: without it, `time:` is parsed as a scheme and
    /// the whole thing drops to `nil` instead of searching).
    func testColonQueryWithSpaceSearches() throws {
        let query = "time: in tokyo"
        let url = try XCTUnwrap(WebURLNormalizer.normalize(query))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, WebURLNormalizer.searchHost)
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "q" })?.value, query)
    }

    // MARK: - Dangerous / non-web schemes DROP to nil (validate-then-drop)

    func testJavascriptSchemeDropped() {
        XCTAssertNil(WebURLNormalizer.normalize("javascript:alert(1)"))
    }

    func testFileSchemeDropped() {
        XCTAssertNil(WebURLNormalizer.normalize("file:///etc/passwd"))
    }

    func testDataSchemeDropped() {
        XCTAssertNil(WebURLNormalizer.normalize("data:text/html,<h1>hi</h1>"))
    }

    func testMailtoSchemeDropped() {
        XCTAssertNil(WebURLNormalizer.normalize("mailto:foo@bar.com"))
    }

    func testFtpSchemeDropped() {
        XCTAssertNil(WebURLNormalizer.normalize("ftp://files.example.com/x"))
    }

    // MARK: - Empty / whitespace → nil

    func testEmptyDropsToNil() {
        XCTAssertNil(WebURLNormalizer.normalize(""))
        XCTAssertNil(WebURLNormalizer.normalize("   \n\t  "))
    }
}
