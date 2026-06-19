import Foundation

/// Live, client-side terminal-render preferences (decision #6: these DO apply live, unlike the video
/// flags). Persisted via `@AppStorage` / `UserDefaults` (the model is the source of truth); W13 applies
/// font/theme live via `ghostty_config_load_string` before `ghostty_config_finalize`.
///
/// Pure `Codable` value type — no SwiftUI import, so it is headlessly testable and the libghostty
/// config-string builder (`ghosttyConfigString()`, W13) can be unit-tested without a surface. Every
/// field has a real default (these are render prefs, not env overrides), so a default-constructed
/// value is a sensible terminal.
public struct TerminalPreferences: Codable, Sendable, Equatable {
    /// Monospace font family (libghostty `font-family`).
    public var fontFamily: String
    /// Font point size (libghostty `font-size`).
    public var fontSize: Double
    /// Font weight token (libghostty `font-style`, e.g. "regular" / "bold").
    public var fontWeight: String
    /// Theme name / palette (libghostty `theme`).
    public var theme: String

    /// Cursor style (libghostty `cursor-style`).
    public enum CursorStyle: String, Codable, Sendable, CaseIterable {
        case block
        case bar
        case underline
    }

    /// Terminal cursor style.
    public var cursorStyle: CursorStyle
    /// Whether the cursor blinks (libghostty `cursor-style-blink`).
    public var cursorBlink: Bool
    /// Scrollback buffer size in lines (libghostty `scrollback-limit`, rows).
    public var scrollbackLines: Int

    public init(
        fontFamily: String = "SF Mono",
        fontSize: Double = 13,
        fontWeight: String = "regular",
        theme: String = "Aislopdesk Dark",
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true,
        scrollbackLines: Int = 10000,
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.theme = theme
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.scrollbackLines = scrollbackLines
    }
}
