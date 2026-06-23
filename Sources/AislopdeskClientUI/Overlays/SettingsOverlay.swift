// SettingsOverlay — a minimal Settings surface (ORCH W-settings). Opened by the L4 Settings pill, the top
// bar's settings icon, and the palette "Open Settings" row. A centered modal card over the 70% scrim, with
// a few REAL `PreferencesStore`/`SettingsKey`-backed toggles:
//   - Notifications (OSC 9/777 + long-command) — `SettingsKey.oscNotifications`
//   - System-dialog panes — `SettingsKey.systemDialogPanes`
//   - Density tier — `SettingsKey.density` (compact / comfortable)
// Theme is fixed to Warp Dark for now (a disabled row showing the active theme name).
//
// The toggle state is a thin `@Observable` over `UserDefaults` (the same keys the rest of the app reads at
// fire-time), so a flip takes effect immediately without a restart. Esc / scrim-tap / Done closes.

import AislopdeskDesignSystem
import AislopdeskWorkspaceCore
import Foundation
import Observation
import SwiftUI

/// A tiny `UserDefaults`-backed settings model (the keys are the shared `SettingsKey` ids the app reads).
@MainActor
@Observable
final class SettingsModel {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// OSC + long-command notifications master toggle (default ON).
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: SettingsKey.oscNotifications) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: SettingsKey.oscNotifications)
            defaults.set(newValue, forKey: SettingsKey.longCommandNotifications)
        }
    }

    /// Auto-spawn a pane for system password dialogs (default ON).
    var systemDialogPanesEnabled: Bool {
        get { defaults.object(forKey: SettingsKey.systemDialogPanes) as? Bool ?? true }
        set { defaults.set(newValue, forKey: SettingsKey.systemDialogPanes) }
    }

    /// Density tier — "comfortable" (default) or "compact".
    var compactDensity: Bool {
        get { (defaults.string(forKey: SettingsKey.density) ?? "comfortable") == "compact" }
        set { defaults.set(newValue ? "compact" : "comfortable", forKey: SettingsKey.density) }
    }
}

struct SettingsOverlay: View {
    @Environment(\.theme) private var theme

    @Bindable var model: SettingsModel
    var staticMirror: Bool = false
    let onClose: () -> Void

    private static let width: CGFloat = 440

    var body: some View {
        ZStack {
            Color(WarpShadow.modalBackdrop)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS) || os(iOS)
            .modifier(SettingsEscHandler(enabled: !staticMirror, onClose: onClose))
        #endif
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WarpSpace.xl) {
            HStack {
                Text("Settings")
                    .font(WarpType.ui(WarpType.headerSize, weight: .semibold))
                    .foregroundStyle(theme.textMain)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: WarpType.uiSize, weight: .semibold))
                        .foregroundStyle(theme.textSub)
                        .frame(width: WarpSize.iconButton, height: WarpSize.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            settingRow(title: "Theme", subtitle: theme.name) {
                Text(theme.name)
                    .font(WarpType.ui(WarpType.uiSize))
                    .foregroundStyle(theme.textDisabled)
            }
            Divider().overlay(theme.outline)
            toggleRow(
                title: "Notifications",
                subtitle: "OSC 9/777 + long-running command completion",
                isOn: $model.notificationsEnabled,
            )
            toggleRow(
                title: "System Dialog Panes",
                subtitle: "Auto-open a pane for host password prompts",
                isOn: $model.systemDialogPanesEnabled,
            )
            toggleRow(
                title: "Compact Density",
                subtitle: "Tighter chrome spacing",
                isOn: $model.compactDensity,
            )

            HStack {
                Spacer()
                ModalButton(label: "Done", kind: .primary, action: onClose)
            }
        }
        .padding(WarpSpace.dialogHorizontal)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous).fill(theme.surface2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous)
                .strokeBorder(theme.outline, lineWidth: WarpBorder.width),
        )
        .contentShape(RoundedRectangle(cornerRadius: WarpRadius.dialog, style: .continuous))
        .onTapGesture {}
    }

    private func settingRow(title: String, subtitle: String, @ViewBuilder trailing: () -> some View)
        -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: WarpSpace.xxs) {
                Text(title).font(WarpType.ui(WarpType.uiSize, weight: .semibold)).foregroundStyle(theme.textMain)
                Text(subtitle).font(WarpType.ui(WarpType.overlineSize)).foregroundStyle(theme.textSub)
            }
            Spacer()
            trailing()
        }
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        settingRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
    }
}

#if os(macOS) || os(iOS)
private struct SettingsEscHandler: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onKeyPress(.escape) { onClose()
                return .handled
            }
        } else {
            content
        }
    }
}
#endif
