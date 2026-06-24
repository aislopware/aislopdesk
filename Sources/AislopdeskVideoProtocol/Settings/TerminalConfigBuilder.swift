import Foundation

/// PURE, headless builder: ``TerminalPreferences`` → a libghostty config string (W13).
///
/// libghostty's `ghostty_config_load_string` (header 1133) accepts the SAME newline-separated
/// `key = value` syntax as `~/.config/ghostty/config`. W13's `GhosttyTerminalView` feeds the output of
/// ``string(for:)`` through that call BEFORE `ghostty_config_finalize`, so a font / theme / cursor
/// change applies live (and the host PTY grid is re-measured + resized after the reflow).
///
/// This type is the testable seam: the config-string mapping is pure (no libghostty, no SwiftUI), so
/// `TerminalConfigBuilderTests` can pin every field → its Ghostty config key WITHOUT a surface (the
/// hang-safety rule — no `ghostty_*` symbol is touched in a test). The libghostty apply call site is
/// compiled + code-reviewed only.
///
/// Ghostty config key names (verified against the upstream config reference / `ghostty +list-actions`):
///   • `font-family`        — the monospace family name.
///   • `font-size`          — point size.
///   • `font-style`         — weight / style token (e.g. `Regular`, `Bold`).
///   • `theme`              — named theme / palette.
///   • `background`         — surface background colour (6-hex; overrides the theme).
///   • `foreground`         — text colour (6-hex; overrides the theme).
///   • `cursor-style`       — `block` / `bar` / `underline`.
///   • `cursor-style-blink` — `true` / `false`.
///   • `scrollback-limit`   — scrollback buffer size (BYTES in Ghostty; we map lines × a per-line
///                            estimate — see ``scrollbackLimitBytes``).
///   • `keybind`            — one `keybind = <chord>=<action>` line per user rebind (additive).
public enum TerminalConfigBuilder {
    /// The per-line byte estimate used to convert a user-facing "scrollback lines" count to Ghostty's
    /// BYTE-denominated `scrollback-limit`. A generous 256 B/line (a wide 8-bit-styled row) so the user
    /// gets at LEAST the lines they asked for; over-provisioning scrollback is cheap and never wrong.
    static let bytesPerScrollbackLine = 256

    /// Convert a user-facing scrollback LINE count to Ghostty's BYTE `scrollback-limit`. Clamped at 0
    /// (a negative / nonsensical request → 0, never a trap). Pure integer math.
    public static func scrollbackLimitBytes(lines: Int) -> Int {
        let safe = lines > 0 ? lines : 0
        return safe &* bytesPerScrollbackLine
    }

    /// Build the libghostty config string for `prefs` — one `key = value` line per setting, in a
    /// STABLE order (font, theme, cursor, scrollback). Every value is emitted (these are render prefs
    /// with real defaults, unlike the nil-able video env overlay), so the string is deterministic and
    /// fully pins the surface's appearance. An EMPTY family / theme is SKIPPED (an empty `font-family =`
    /// would clear Ghostty's default to nothing) — the one place "unset" is honoured.
    public static func string(for prefs: TerminalPreferences, keybinds: [String] = []) -> String {
        var lines: [String] = []

        let family = prefs.fontFamily.trimmingCharacters(in: .whitespaces)
        if !family.isEmpty { lines.append("font-family = \(family)") }
        lines.append("font-size = \(formatSize(prefs.fontSize))")
        let weight = prefs.fontWeight.trimmingCharacters(in: .whitespaces)
        if !weight.isEmpty { lines.append("font-style = \(weight)") }
        let theme = prefs.theme.trimmingCharacters(in: .whitespaces)
        if !theme.isEmpty { lines.append("theme = \(theme)") }
        // Emit explicit background/foreground AFTER `theme` so they override the named theme (which isn't
        // bundled and won't resolve) — this is what actually pins the surface to otty's Paper palette. An
        // empty value is skipped (same "unset is honoured" rule as family/theme).
        let background = prefs.background.trimmingCharacters(in: .whitespaces)
        if !background.isEmpty { lines.append("background = \(background)") }
        let foreground = prefs.foreground.trimmingCharacters(in: .whitespaces)
        if !foreground.isEmpty { lines.append("foreground = \(foreground)") }

        lines.append("cursor-style = \(prefs.cursorStyle.rawValue)")
        lines.append("cursor-style-blink = \(prefs.cursorBlink ? "true" : "false")")
        lines.append("scrollback-limit = \(scrollbackLimitBytes(lines: prefs.scrollbackLines))")

        // Additive keybind lines (one per user rebind), validate-then-skip an empty one.
        for kb in keybinds where !kb.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("keybind = \(kb)")
        }

        return lines.joined(separator: "\n")
    }

    /// Format the font size without a spurious decimal / exponent: an integral size prints `13`, a
    /// fractional one `13.5` — what a user would type and what Ghostty's parser accepts. Mirrors
    /// ``EnvBridge/formatDouble(_:)`` so the two surfaces agree.
    static func formatSize(_ size: Double) -> String {
        if size.isFinite, size == size.rounded(), abs(size) < 1e9 {
            return String(Int(size))
        }
        return String(size)
    }
}
