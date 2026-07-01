import Foundation

/// A parsed `.aislopdesktheme` (E15) — the UNIFORM, leaf-level model both the terminal palette path and the chrome
/// path read.
///
/// WHY it lives in the leaf ``AislopdeskVideoProtocol``: the terminal palette (`foreground`/`background`/the
/// 16-entry ANSI `palette`/`selectionBackground`) must reach ``TerminalConfigBuilder`` (also in this leaf),
/// while the chrome roles must reach `SlateTheme` (up in `AislopdeskClientUI`). A single pure-Foundation model
/// that both layers see — and that the file parsers/importers (WI-4/WI-5) build — keeps the parse logic
/// headlessly testable with no SwiftUI / AppKit. It carries NO behaviour onto the wire: appearance is pure
/// client chrome (the golden-safety invariant ``AppearancePreferences`` documents).
///
/// COLOUR STORAGE: every colour field holds a canonical 6-hex string WITHOUT a leading `#` (e.g. `"FF6188"`)
/// — the shape both libghostty's `palette = N=<hex>` config value and `Color(slateHex:)` consume directly. The
/// one exception is `background`, which may also be the literal `"none"` (a transparent terminal background).
/// The parsers/importers normalise `"#rrggbb"` → `"rrggbb"` BEFORE constructing a document; ``isValid`` then
/// rejects anything that is not a clean 6-hex (validate-then-drop, the same discipline as a hostile datagram).
public struct ThemeDocument: Codable, Sendable, Equatable {
    /// Whether the theme is meant for the light or the dark OS-appearance slot (`[meta] mode`). Drives the
    /// dual-slot assignment + `SlateTheme.isLight`.
    public enum Mode: String, Codable, Sendable, Equatable {
        case light
        case dark
    }

    // Identity / meta
    /// The human-readable name (`[meta] name`).
    public var displayName: String
    /// The filename / lookup slug — `displayName` lowercased with each non-`[a-z0-9]` run-of-one → `-`
    /// (see ``slug(from:)``). Stored (not always derived) so an imported file keeps its on-disk slug.
    public var slug: String
    /// Light / dark slot assignment (`[meta] mode`).
    public var mode: Mode

    // [terminal] — required core palette
    /// Default terminal text colour (6-hex).
    public var foreground: String
    /// Default terminal background colour (6-hex, or `"none"` for transparent).
    public var background: String
    /// The 16 ANSI colours (indices 0–15): 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan,
    /// 7=white, 8–15 = the bright variants in the same order. A valid document has EXACTLY 16 entries.
    public var palette: [String]
    /// Cursor block colour (`[terminal] cursor`); `nil` ⇒ falls back to `foreground`.
    public var cursor: String?
    /// Glyph-under-cursor colour (`[terminal] cursor-text`).
    public var cursorText: String?
    /// Selection highlight background (`[terminal] selection-background` / `[selection] background`).
    public var selectionBackground: String?

    // [token] accent + chrome regions ([ui]/[panel]/[sidebar]/[titlebar]/[tab]/[window])
    /// Focus / active-state accent (`[token] accent`).
    public var accent: String?
    /// Window-frame background (`[window]` / `[ui] title-bar-bg` backdrop).
    public var window: String?
    /// Navigator / tab-sidebar background (`[sidebar]` / `[ui] tab-bar-bg`).
    public var sidebar: String?
    /// Title-bar background (`[titlebar]` / `[ui] title-bar-bg`).
    public var titlebar: String?
    /// Active-tab background (`[tab]` / `[ui] tab-active-bg`).
    public var tab: String?
    /// Inset panel / command-palette surface (`[panel]`).
    public var panel: String?

    // [container] — terminal-card geometry (parsed + stored; container styling applied best-effort later)
    /// Corner radius of the terminal card in points (`[container] radius`).
    public var radius: Double?
    /// Drop shadow, CSS box-shadow syntax verbatim (`[container] shadow`).
    public var shadow: String?
    /// Border, CSS border syntax verbatim (`[container] border`).
    public var border: String?
    /// Inner grid gutter — scalar (1 element) or `[top, right, bottom, left]` (4) (`[container] padding`).
    public var padding: [Double]?
    /// Inset of the card from the window edges — scalar or `[top, right, bottom, left]` (`[container] margin`).
    public var margin: [Double]?

    // [token] — typography
    /// Terminal grid font stack (`[token] font-mono`).
    public var fontMono: [String]?
    /// Window-chrome font stack (`[token] font-ui`).
    public var fontUI: [String]?
    /// Terminal font size in points (`[token] font-size`).
    public var fontSize: Double?
    /// Line height (`[token] adjust-cell-height`), kept as the raw token (`"Npx"` / `"N"` / `"N%"` / `"0"`).
    public var adjustCellHeight: String?

    public init(
        displayName: String,
        slug: String,
        mode: Mode,
        foreground: String,
        background: String,
        palette: [String],
        cursor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        accent: String? = nil,
        window: String? = nil,
        sidebar: String? = nil,
        titlebar: String? = nil,
        tab: String? = nil,
        panel: String? = nil,
        radius: Double? = nil,
        shadow: String? = nil,
        border: String? = nil,
        padding: [Double]? = nil,
        margin: [Double]? = nil,
        fontMono: [String]? = nil,
        fontUI: [String]? = nil,
        fontSize: Double? = nil,
        adjustCellHeight: String? = nil,
    ) {
        self.displayName = displayName
        self.slug = slug
        self.mode = mode
        self.foreground = foreground
        self.background = background
        self.palette = palette
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.accent = accent
        self.window = window
        self.sidebar = sidebar
        self.titlebar = titlebar
        self.tab = tab
        self.panel = panel
        self.radius = radius
        self.shadow = shadow
        self.border = border
        self.padding = padding
        self.margin = margin
        self.fontMono = fontMono
        self.fontUI = fontUI
        self.fontSize = fontSize
        self.adjustCellHeight = adjustCellHeight
    }
}

// MARK: - Slug derivation + colour validation (pure, headlessly testable)

public extension ThemeDocument {
    /// The number of ANSI palette entries a valid theme MUST declare (indices 0–15).
    static let paletteCount = 16

    /// Derive the filename / lookup slug from a display name: lowercased, then every character that is not an
    /// ASCII `a–z` / `0–9` becomes a `-` (e.g. `"My Cool Theme"` → `"my-cool-theme"`, the documented rule). No
    /// collapsing / trimming — the mapping is character-for-character so it is total and deterministic; the
    /// themes library (WI-4) handles slug COLLISIONS by appending `-1` / `-2`.
    static func slug(from displayName: String) -> String {
        var out = ""
        out.reserveCapacity(displayName.count)
        for scalar in displayName.lowercased().unicodeScalars {
            let v = scalar.value
            let isLower = v >= 97 && v <= 122 // a–z
            let isDigit = v >= 48 && v <= 57 // 0–9
            if isLower || isDigit {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        return out
    }

    /// `true` iff `value` is a 6-digit hex colour with NO leading `#` (case-insensitive). Rejects the wrong
    /// length, `#`-prefixed strings, and any non-hex character — the caller drops the whole document then
    /// (validate-then-drop). The check is on the exact 6 characters, so embedded whitespace also fails.
    static func isValidHex(_ value: String) -> Bool {
        guard value.count == hexLength else { return false }
        for scalar in value.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57 // 0–9
            let isUpperAF = v >= 65 && v <= 70 // A–F
            let isLowerAF = v >= 97 && v <= 102 // a–f
            if !(isDigit || isUpperAF || isLowerAF) { return false }
        }
        return true
    }

    /// `true` iff `value` is valid for a `[terminal] background` — a 6-hex colour OR the literal `"none"`
    /// (transparent). Only `background` may be `"none"`; every other colour field uses ``isValidHex(_:)``.
    static func isValidBackground(_ value: String) -> Bool {
        value == "none" || isValidHex(value)
    }

    /// The structural invariants a document must satisfy to render: `foreground` + every optional colour are
    /// clean 6-hex, `background` is 6-hex or `"none"`, and `palette` is exactly 16 valid-hex entries. A parser
    /// / importer that produces a document failing this check must DROP it (return `nil`), never ship it.
    var isValid: Bool {
        guard Self.isValidBackground(background) else { return false }
        guard Self.isValidHex(foreground) else { return false }
        guard palette.count == Self.paletteCount else { return false }
        guard palette.allSatisfy(Self.isValidHex) else { return false }
        let optionalColours = [cursor, cursorText, selectionBackground, accent, window, sidebar, titlebar, tab, panel]
        for colour in optionalColours {
            if let colour, !Self.isValidHex(colour) { return false }
        }
        return true
    }

    /// The exact character length of a `#`-less 6-hex colour.
    private static let hexLength = 6
}
