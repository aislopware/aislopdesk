// CursorPreviewView — the otty Appearance → Cursor section (E8 WI-3).
//
// Faithful clone of `docs/otty-clone/screenshots/cursor-style.png`: a "CURSOR" section that opens with a
// one-line description + a LIVE PREVIEW card (the `john@doe-pc$ git commit -m "│"` mock that re-renders the
// caret as the user tunes it), then the cursor-color / text-color-under-cursor color wells, the opacity
// slider, and the Style / Blink / Animation dropdowns. Every control binds `store.terminal` (a
// `TerminalPreferences` render-pref field), so a change flows through the store's `terminal` `didSet`
// → `applyTerminal()` → `TerminalConfigBroadcaster` and re-applies live (the cursor color/opacity/text lines
// are emitted by `TerminalConfigBuilder`, WI-2) — there is NO `refreshTerminalControls()` hop here (that seam
// is for the fire-time `Defaults` Controls toggles, not the typed render prefs).
//
// macOS-only: `ColorPicker` + the `NSColor` hex glue are AppKit. The Appearance tab keeps a simpler
// Style/Blink section on iOS (see `AppearanceSettingsTab`). The pure hex helper (`CursorColorHex`) is
// cross-platform + headlessly testable (`CursorColorHexTests`). Otty.* tokens only (no raw font/radius
// literals — `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import SwiftUI

// MARK: - CursorColorHex (pure 6-hex ↔ RGB bridge — no SwiftUI / AppKit, so it is unit-pinned)

/// The pure conversion between a libghostty `cursor-color` 6-hex string (what `TerminalPreferences` persists
/// and `TerminalConfigBuilder` emits) and integer / unit RGB channels. Kept AppKit-free so
/// `CursorColorHexTests` can pin the round-trip headlessly; the `NSColor` glue that feeds a SwiftUI
/// `ColorPicker` lives in the macOS-only `Color` extension below and is code-reviewed, not unit-tested.
enum CursorColorHex {
    /// Parse a 6-hex RGB string (no leading `#`) into 0…255 channels. Returns `nil` for an empty string
    /// (otty's "Default" = follow the theme), the wrong length, or any non-hex character — the caller then
    /// falls back to the effective default colour. Case-insensitive.
    static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// Format unit RGB doubles (each clamped to `0…1`, NaN → `0`) into an UPPERCASE 6-hex string (no `#`) —
    /// exactly the shape `TerminalConfigBuilder` forwards as `cursor-color = …`. The clamp uses an ordered
    /// comparison (NaN-faithful) rather than a bare `min`/`max` ternary.
    static func hex(r: Double, g: Double, b: Double) -> String {
        String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// One unit-double channel → a `0…255` int (rounded-to-nearest). NaN → `0` (a safe default); ±infinity
    /// falls through to the ordered, NaN-faithful clamp (→ `1` / `0`).
    private static func channel(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let clamped = Double.minimum(1, Double.maximum(0, value))
        return Int((clamped * 255).rounded())
    }
}

#if os(macOS)
import AppKit

// MARK: - Color ↔ cursor-hex glue (macOS — NSColor sRGB component extraction)

extension Color {
    /// Build a colour from a 6-hex `cursor-color` string, or `nil` when the string is empty / malformed (the
    /// caller then substitutes the effective default — the foreground for the cursor body, the background for
    /// the glyph-under-cursor).
    init?(cursorHex hex: String) {
        guard let rgb = CursorColorHex.rgb(hex) else { return nil }
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }

    /// This colour as a 6-hex `cursor-color` string (sRGB), or `""` (follow the theme) when it cannot be
    /// resolved into an sRGB triple — so a colour that resists conversion degrades to "Default", never traps.
    var cursorHexString: String {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return "" }
        return CursorColorHex.hex(
            r: Double(srgb.redComponent),
            g: Double(srgb.greenComponent),
            b: Double(srgb.blueComponent),
        )
    }
}

// MARK: - CursorPreviewView

/// The Appearance → Cursor `Section` (live preview + colour / opacity / style / blink / animation), bound to
/// `store.terminal`. Hosted by `AppearanceSettingsTab` on macOS.
struct CursorPreviewView: View {
    @Bindable var store: PreferencesStore

    /// Drives the blink animation of the preview caret (mirrors the chosen `cursorBlink`, purely cosmetic).
    @State private var blinkVisible = true

    var body: some View {
        Section("Cursor") {
            Text("Live preview of your cursor color, style, opacity and blink behavior.")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)

            previewCard

            ColorPicker(
                "Cursor color",
                selection: cursorColorBinding(\.cursorColor, fallbackHex: store.terminal.foreground),
                supportsOpacity: false,
            )
            ColorPicker(
                "Text color under cursor",
                selection: cursorColorBinding(\.cursorTextColor, fallbackHex: store.terminal.background),
                supportsOpacity: false,
            )

            LabeledContent("Cursor opacity") {
                HStack(spacing: Otty.Metric.space2) {
                    Text(String(format: "%.2f", store.terminal.cursorOpacity))
                        .foregroundStyle(Otty.Text.secondary)
                        .monospacedDigit()
                    Slider(value: $store.terminal.cursorOpacity, in: 0...1)
                }
            }

            Picker("Cursor Style", selection: $store.terminal.cursorStyle) {
                ForEach(TerminalPreferences.CursorStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }

            LabeledContent {
                Picker("", selection: $store.terminal.cursorBlink) {
                    Text("Default").tag(TerminalPreferences.CursorBlink.default)
                    Text("On").tag(TerminalPreferences.CursorBlink.on)
                    Text("Off").tag(TerminalPreferences.CursorBlink.off)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                    Text("Cursor blink style")
                    Text("The `Default` option defers to DEC mode 12 to determine blinking state.")
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent {
                Picker("", selection: $store.terminal.cursorAnimation) {
                    Text("Off").tag(TerminalPreferences.CursorAnimation.off)
                    Text("Smooth").tag(TerminalPreferences.CursorAnimation.smooth)
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                VStack(alignment: .leading, spacing: Otty.Metric.space1) {
                    Text("Cursor Animation")
                    Text("Smooth glides the caret on same-row moves and adds an overshoot on click/focus.")
                        .font(.system(size: Otty.Typeface.footnote))
                        .foregroundStyle(Otty.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Live preview

    /// The `john@doe-pc$ git commit -m "│"` mock — a monospaced prompt line with the live caret between the
    /// quotes, on the inset element surface (the otty preview card).
    private var previewCard: some View {
        HStack(spacing: 0) {
            Text("john").foregroundStyle(Otty.Status.ok)
            Text("@").foregroundStyle(Otty.Text.primary)
            Text("doe-pc").foregroundStyle(Otty.Status.ok)
            Text("$ git commit -m \"").foregroundStyle(Otty.Text.primary)
            cursorGlyph
            Text("\"").foregroundStyle(Otty.Text.primary)
        }
        .font(.system(size: Otty.Typeface.body, design: .monospaced))
        .padding(.vertical, Otty.Metric.space2)
        .padding(.horizontal, Otty.Metric.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous)
                .fill(Otty.Surface.element),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Otty.Metric.radiusCard, style: .continuous)
                .strokeBorder(Otty.Line.subtle, lineWidth: 1),
        )
    }

    /// The preview caret, rendered per the chosen style / colour / opacity, blinking when `cursorBlink` is on.
    private var cursorGlyph: some View {
        cursorShape
            .opacity(blinkVisible ? store.terminal.cursorOpacity : 0)
            .onAppear { restartBlink() }
            .onChange(of: store.terminal.cursorBlink) { _, _ in restartBlink() }
    }

    @ViewBuilder private var cursorShape: some View {
        let cell = previewCellSize
        switch store.terminal.cursorStyle {
        case .block:
            Rectangle().fill(cursorPreviewColor).frame(width: cell.width, height: cell.height)
        case .blockHollow:
            Rectangle()
                .strokeBorder(cursorPreviewColor, lineWidth: 1)
                .frame(width: cell.width, height: cell.height)
        case .bar:
            Rectangle().fill(cursorPreviewColor).frame(width: 2, height: cell.height)
                .frame(width: cell.width, height: cell.height, alignment: .leading)
        case .underline:
            Rectangle().fill(cursorPreviewColor).frame(width: cell.width, height: 2)
                .frame(width: cell.width, height: cell.height, alignment: .bottom)
        }
    }

    /// The approximate monospace cell for the preview font (advance ≈ 0.62 em, line height ≈ 1.3 em). A
    /// preview-only estimate — the real surface metrics come from libghostty.
    private var previewCellSize: (width: CGFloat, height: CGFloat) {
        let em = Otty.Typeface.body
        return (width: em * 0.62, height: em * 1.3)
    }

    /// The effective caret colour: the pinned `cursorColor`, else the foreground (otty's "Default").
    private var cursorPreviewColor: Color {
        Color(cursorHex: store.terminal.cursorColor)
            ?? Color(cursorHex: store.terminal.foreground)
            ?? Otty.Text.primary
    }

    /// Whether the cosmetic preview caret blinks: `.on` (and `.default`, which defers to DEC mode 12 — the
    /// terminal's usual blink-on default) animate; `.off` holds steady. Preview-only — the real surface
    /// honours DEC mode 12 for `.default`.
    private var previewBlinks: Bool { store.terminal.cursorBlink != .off }

    private func restartBlink() {
        blinkVisible = true
        guard previewBlinks else { return }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            blinkVisible = false
        }
    }

    // MARK: Colour bindings

    /// Bridge a `TerminalPreferences` 6-hex colour string field to a `ColorPicker`'s `Binding<Color>`. An
    /// empty / unset field reads as `fallbackHex` (the theme default) so the well shows the effective colour;
    /// picking a colour writes its sRGB 6-hex back, which re-applies live through the store's `terminal`
    /// `didSet`.
    private func cursorColorBinding(
        _ keyPath: WritableKeyPath<TerminalPreferences, String>, fallbackHex: String,
    ) -> Binding<Color> {
        Binding(
            get: {
                let hex = store.terminal[keyPath: keyPath]
                return Color(cursorHex: hex) ?? Color(cursorHex: fallbackHex) ?? Otty.Text.primary
            },
            set: { store.terminal[keyPath: keyPath] = $0.cursorHexString },
        )
    }
}
#endif
#endif
