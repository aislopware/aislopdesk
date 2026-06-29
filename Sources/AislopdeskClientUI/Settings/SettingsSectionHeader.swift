// SettingsSectionHeader (Batch-5 UI fidelity) — otty's signature in-page Settings SECTION-header treatment.
//
// otty renders Settings section labels (`MOUSE` / `SECURE INPUT` in `mouse-option.png`, `NOTIFICATION` /
// `TAB BADGE` in `notification-setting.png`, `ALL SETTINGS` in `all-settings.png`) as UPPERCASE,
// letter-TRACKED, secondary-gray small-caps headers — NOT macOS's default Title-Case dark `Section(_:)`
// header. The clone previously used the native `Section("Title")` initializer, which renders Title-Case bold
// dark on macOS grouped Forms (e.g. "Selection", "Copy & Paste"). This helper consolidates every grouped
// settings section onto ONE shared header style that matches both the otty screenshots AND the clone's own
// command-palette section headers (`PaletteView.sectionHeader` — the same three tokens), so the Settings form
// and the palette no longer diverge. Call sites swap `Section("X") {` → `ottyFormSection("X") {`; the content
// closure is unchanged, so no layout in the section body moves.

#if canImport(SwiftUI)
import SwiftUI

/// Pure, testable transform for the otty section-header label — UPPERCASE. Extracted so the casing is pinned
/// by `SettingsSectionHeaderTests` and can't silently regress to macOS's Title-Case default if the render
/// helper is refactored.
enum OttySettingsSectionHeader {
    static func label(_ title: String) -> String { title.uppercased() }
}

/// A grouped-`Form` section whose header carries otty's UPPERCASE / tracked / secondary-gray treatment
/// (`Otty.Typeface.small` semibold · `Otty.State.header`), instead of macOS's default Title-Case dark header.
/// Drop-in for `Section(_ title:content:)`: the trailing `content` closure is identical, so swapping the
/// initializer name restyles the header without touching the section body. `@MainActor` because the gray
/// header color resolves through the main-actor `Otty.State` palette (every call site is a SwiftUI body).
@MainActor
func ottyFormSection(
    _ title: String,
    @ViewBuilder content: () -> some View,
) -> some View {
    Section {
        content()
    } header: {
        Text(OttySettingsSectionHeader.label(title))
            .font(.system(size: Otty.Typeface.small, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Otty.State.header)
    }
}
#endif
