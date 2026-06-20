// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
// See THIRD_PARTY_NOTICES.md.
#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// The global UI density control for the chrome. Muxy stores this in a `CodableFileStore`; we drop that
/// dependency and persist a single preset string in `UserDefaults` (key `aislopdesk.uiScale`). Every
/// `UIMetrics` token multiplies its base by `UIScale.shared.multiplier`, so flipping the preset rescales
/// the whole chrome at once. Changing the preset posts `aislopdeskThemeDidChange` so views can refresh.
@preconcurrency @MainActor
@Observable
public final class UIScale {
    /// The process-wide instance every chrome view reads.
    public static let shared = UIScale()

    /// The discrete density steps (Muxy `UIScale.Preset`): a multiplier + a human title.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case regular
        case large
        case extraLarge

        public var id: String { rawValue }

        /// The scale factor applied to every metric base.
        public var multiplier: CGFloat {
            switch self {
            case .regular: 1.00
            case .large: 1.12
            case .extraLarge: 1.24
            }
        }

        /// The menu / settings label for this preset.
        public var title: String {
            switch self {
            case .regular: "Default"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }
    }

    /// The preset chosen if nothing is persisted.
    public static let defaultPreset: Preset = .regular

    /// The `UserDefaults` key the chosen preset is stored under.
    private static let storageKey = "aislopdesk.uiScale"

    /// The active density. Persists to `UserDefaults` and posts `aislopdeskThemeDidChange` when changed.
    public var preset: Preset = UIScale.defaultPreset {
        didSet {
            guard !isLoading, preset != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .aislopdeskThemeDidChange, object: nil)
        }
    }

    /// The current scale factor — the only thing `UIMetrics` needs.
    public var multiplier: CGFloat { preset.multiplier }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let raw = defaults.string(forKey: Self.storageKey),
              let stored = Preset(rawValue: raw)
        else { return }
        isLoading = true
        preset = stored
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(preset.rawValue, forKey: Self.storageKey)
    }
}

public extension Notification.Name {
    /// Posted when a theme-affecting setting (currently the UI scale preset) changes, so chrome views can
    /// invalidate cached metrics and redraw (Muxy posts `.themeDidChange`).
    static let aislopdeskThemeDidChange = Notification.Name("aislopdeskThemeDidChange")
}
#endif
