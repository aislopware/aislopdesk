import Foundation

// MARK: - Address-bar / dropped-URL normalization

/// Turns a raw address-bar string (or a dropped URL/text) into a SAFE, navigable `http(s)` ``URL`` — or
/// `nil` when nothing safe can be produced (E18, `spec/user-interface__files-and-links.md` › Web
/// Browser Pane: *"A bare host in the address bar gets `https://` prepended; otherwise it acts as a
/// DuckDuckGo search."*).
///
/// The contract (CLAUDE.md untrusted-input / validate-then-drop — the web pane is a non-persistent local
/// surface, never an auth boundary, so it must never be coaxed into a dangerous scheme):
///
/// 1. An explicit **`http` / `https`** URL passes through verbatim (after validating it has a host).
/// 2. An explicit **non-web scheme** (`javascript:`, `file:`, `data:`, `mailto:`, `ftp:`, …) is **DROPPED**
///    → `nil`. We never synthesize a `file://` / `javascript:` URL from address-bar text.
/// 3. A **bare host** (a dotted domain, `localhost`, an IPv4, optionally with a `:port` and/or a path) gets
///    **`https://` prepended**.
/// 4. **Anything else** (free text, a single word, a phrase with spaces) becomes a **DuckDuckGo search**.
/// 5. Empty / whitespace-only input → `nil`.
///
/// PURE + headless: imports only `Foundation`, touches no disk, no `WKWebView`. Never force-unwraps — every
/// `URL`/`URLComponents` build is checked, and a build failure degrades to the search fallback or `nil`.
/// Pinned by `WebURLNormalizerTests`.
public enum WebURLNormalizer {
    /// The search engine a non-URL query is sent to (DuckDuckGo).
    static let searchHost = "duckduckgo.com"

    /// Normalize `raw` into a navigable `http(s)` ``URL``, or `nil` (validate-then-drop). See the type doc
    /// for the full table.
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A real URL/host never contains INNER whitespace, so anything that does is unambiguously a search
        // query — never a scheme to validate nor a host to fix up. (This also keeps a `"javascript: x"`-with-
        // space string from reaching scheme detection; searching it on DuckDuckGo is harmless.)
        if trimmed.contains(where: \.isWhitespace) {
            return searchURL(for: trimmed)
        }

        // (1)/(2) An explicit scheme decides immediately: web schemes pass; everything else is dropped.
        if let scheme = explicitScheme(of: trimmed) {
            guard scheme == "http" || scheme == "https" else { return nil }
            // A malformed `http(s)` string (no host) still drops to the search fallback rather than
            // producing a hostless URL — e.g. `https://` alone is meaningless.
            if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
                return url
            }
            return searchURL(for: trimmed)
        }

        // (3) No scheme but it looks like a host → prepend https:// and re-validate.
        if looksLikeHost(trimmed), let url = URL(string: "https://" + trimmed),
           let host = url.host, !host.isEmpty
        {
            return url
        }

        // (4) Otherwise a search query.
        return searchURL(for: trimmed)
    }

    // MARK: Scheme detection (scheme vs. `host:port`)

    /// The explicit URL scheme prefixing `s` (lower-cased), or `nil` when there is none. A bare `host:port`
    /// (the part after the first `:`, up to a `/`, is all digits) is NOT a scheme — `localhost:5173` is a
    /// host, not the scheme `localhost`. A real scheme name is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`.
    static func explicitScheme(of s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        // `host:port` disambiguation: digits-up-to-`/` after the colon mean a port, not a scheme.
        let afterColon = s[s.index(after: colon)...]
        let portCandidate = afterColon.prefix { $0 != "/" }
        if !portCandidate.isEmpty, portCandidate.allSatisfy(\.isNumber) {
            return nil
        }
        let head = s[s.startIndex..<colon]
        guard let first = head.first, first.isLetter,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return head.lowercased()
    }

    // MARK: Host heuristic

    /// True when `s` (which carries NO explicit scheme) reads as a bare host: no inner whitespace, and its
    /// authority (up to the first `/`, minus any `:port`) is `localhost`, a dotted domain with non-empty
    /// labels, or an IPv4. A single word like `swift` (no dot, not localhost) is NOT a host → it searches.
    static func looksLikeHost(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace) else { return false }
        let authority = s.prefix { $0 != "/" }
        guard !authority.isEmpty else { return false }
        let host = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? String(authority)
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        guard host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    // MARK: Search fallback

    /// A DuckDuckGo search URL for `query` (`https://duckduckgo.com/?q=…`), or `nil` only if the components
    /// build fails (never force-unwrap). `URLComponents` percent-encodes the query value for us.
    static func searchURL(for query: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = searchHost
        comps.path = "/"
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps.url
    }
}
