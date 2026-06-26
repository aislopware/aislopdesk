// OverlayHostView — the single ZStack that composes EVERY floating overlay above the workspace (E2 / WI-5).
// Driven entirely by the injected ``OverlayCoordinator`` flags, it mounts (in z-order) the command palette,
// the keyboard cheat sheet, the Connect-to-Host editor, and the Remote-Window picker — each behind a dimmed,
// tap-to-dismiss ``Scrim`` — plus the ALWAYS-mounted ``ToastStackView`` (which renders nothing when the
// stack is empty). One host so the four scrimmed panels share one mount point, one fade, and one hit-testing
// gate; the workspace beneath stays interactive whenever nothing is up.
//
// MOUNTING: the root view (`WorkspaceRootView`) attaches this as a top `.overlay` on the macOS
// `WorkspaceSplitRepresentable` (SwiftUI overlays compose over an `NSViewControllerRepresentable`) and on the
// iOS `NavigationSplitView` — the same ZStack reads on both platforms (the panels' AppKit-only Esc handling
// is already `#if os(macOS)`-gated inside each panel view).
//
// HIT-TESTING: `.allowsHitTesting(anyModalVisible || !toasts.isEmpty)` — when no modal is up and no toast is
// showing, the whole host is transparent to clicks so the terminal/video panes beneath receive them; the
// instant a panel or toast appears the host takes hits (the scrim swallows background clicks; the toast X
// stays live). The empty regions of the toast frame carry no background, so a scrim tap still reaches the
// scrim through them.
//
// SEAM discipline: the host owns NO state — every read/close goes through the coordinator (the single
// `@Observable` reducer). The `toggledState` predicate is built by the root from the live `WorkspaceChromeState`
// (macOS) or a no-op (iOS, until iOS chrome exists) and handed in, so the pure coordinator never learns about
// chrome. `Otty.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct OverlayHostView: View {
    /// The live store — passed to ``PaletteView`` (the WORKING-DIRECTORY badge reads the focused pane's cwd).
    let store: WorkspaceStore
    /// The app-global connection — bound by ``ConnectHostView`` (the host/port form is a thin view over it).
    let connection: AppConnection
    /// The single overlay reducer — `@Bindable` so the composed panels can two-way edit its query/selection.
    @Bindable var coordinator: OverlayCoordinator
    /// Whether a palette row currently shows its ✓ (toggled-on) gutter. Built by the root from the live chrome
    /// (see ``OverlayHostView/toggledState(for:)``) so the pure coordinator stays chrome-agnostic. Defaults to
    /// "nothing toggled" (iOS / previews).
    var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }

    var body: some View {
        ZStack {
            if coordinator.paletteVisible {
                Scrim { coordinator.closePalette() }
                PaletteView(coordinator: coordinator, store: store, toggledState: toggledState)
            }
            if coordinator.cheatSheetVisible {
                Scrim { coordinator.closeCheatSheet() }
                KeyboardCheatSheetView(coordinator: coordinator)
            }
            if coordinator.connectVisible {
                Scrim { coordinator.closeConnect() }
                ConnectHostView(connection: connection, coordinator: coordinator)
            }
            if coordinator.remotePickerVisible {
                Scrim { coordinator.closeRemotePicker() }
                RemoteWindowPickerModal(coordinator: coordinator)
            }
            // E3 WI-4: the busy-shell / policy close confirmation for a PANE or TAB (the ⌘W / ⌘⇧W /
            // close-button path parks `store.pendingClose` / `store.pendingTabCloseID`). The window-scope
            // confirmation is the macOS `NSAlert` (`WindowCloseConfirmationDelegate`); this in-app panel
            // covers the pane/tab scope on BOTH platforms, so a ⌘W on a pane (or ⌘⇧W on a tab) with a running
            // command no longer silently no-ops. The two parks are mutually exclusive — at most one branch is
            // ever live. Tapping the scrim cancels (no close), matching the other panels.
            if let spec = store.pendingCloseSpec {
                Scrim { store.cancelPendingClose() }
                CloseConfirmationPanel(
                    title: spec.title.isEmpty ? "Close this pane?" : "Close “\(spec.title)”?",
                    onConfirm: { store.confirmPendingClose() },
                    onCancel: { store.cancelPendingClose() },
                )
            } else if store.pendingTabCloseID != nil {
                Scrim { store.cancelPendingClose() }
                CloseConfirmationPanel(
                    title: "Close this tab?",
                    onConfirm: { store.confirmPendingClose() },
                    onCancel: { store.cancelPendingClose() },
                )
            }
            // Always mounted (renders nothing when empty) so an arriving toast animates in without a re-mount;
            // last in the ZStack ⇒ top-most, so a toast X stays clickable even with a panel up.
            ToastStackView(coordinator: coordinator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One fade for the whole panel layer, keyed on the modal gate so a panel appearing/dismissing
        // cross-fades with its scrim (the toast stack runs its own value-keyed animation internally).
        .animation(Otty.Anim.standard, value: anyScrimmedModal)
        // Transparent to hits when nothing is up so the workspace beneath stays interactive.
        .allowsHitTesting(anyScrimmedModal || !coordinator.toasts.isEmpty)
    }

    /// Whether ANY scrimmed modal is up — the coordinator's four panels OR the store-driven pane/tab close
    /// confirmation. Drives the host's hit-testing gate + the single cross-fade so the close panel behaves
    /// exactly like the others (the coordinator's `anyModalVisible` stays chrome/overlay-only by design).
    private var anyScrimmedModal: Bool {
        coordinator.anyModalVisible || store.pendingCloseSpec != nil || store.pendingTabCloseID != nil
    }

    /// The toggled-state predicate the root hands to ``PaletteView`` — built from the live chrome so the
    /// palette's ✓ gutter reflects the real sidebar/inspector visibility (a visible panel ⇒ ✓ on its toggle
    /// row). Pure + `static` so it is unit-pinnable without instantiating the view (E2 / WI-6). `@MainActor`
    /// because it reads the `@MainActor` ``WorkspaceChromeState``. Future Details/inspector rows resolve here
    /// too (the catalog has only the Tabs-panel row today).
    @MainActor
    static func toggledState(for chrome: WorkspaceChromeState) -> @MainActor (PaletteItem) -> Bool {
        { item in
            switch item.id {
            case "action.toggleSidebar": !chrome.sidebarCollapsed
            case "action.toggleInspector": !chrome.inspectorCollapsed
            default: false
            }
        }
    }
}

// MARK: - Scrim

/// The dimmed, tap-to-dismiss backdrop behind a centered overlay panel. A full-bleed plate tinted with the
/// theme's panel-shadow token (no dedicated scrim role exists — E2 plan §WI-5) that closes the active panel
/// on tap. Shared by all four scrimmed panels so the dim + dismiss behave identically.
struct Scrim: View {
    /// The dismiss action (the active panel's `close*()` — tapping outside the panel closes it).
    var onTap: () -> Void = {}

    var body: some View {
        Rectangle()
            .fill(Otty.State.shadow)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .transition(.opacity)
    }
}

// MARK: - OverlayPanel

/// The shared floating-panel shell (E2 / WI-5): a fixed-width `Otty.Surface.card` panel with the family's
/// rounded corners, hairline border, and drop shadow — used by ``ConnectHostView`` and
/// ``RemoteWindowPickerModal`` so the aislopdesk-specific overlays read as one family with the palette /
/// cheat sheet (which bake the same shell inline). The ZStack in ``OverlayHostView`` centers it.
struct OverlayPanel<Content: View>: View {
    /// The fixed panel width (the palette is ~720; the editor/picker forms are tighter).
    var width: CGFloat = 460
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: width)
            .background(Otty.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusCard)
                    .stroke(Otty.Line.card, lineWidth: Otty.Metric.hairline),
            )
            .shadow(color: Otty.State.shadow, radius: 30, x: 0, y: 12)
    }
}

// MARK: - CloseConfirmationPanel

/// E3 WI-4 — the in-app PANE/TAB close confirmation (the ⌘W / close-button busy-shell + policy guard that
/// parks ``WorkspaceStore/pendingClose``). A compact ``OverlayPanel`` with a Cancel / Close button row;
/// "Close" is tinted with the warn role (a destructive action). The window-scope confirmation is the macOS
/// native `NSAlert` in ``WindowCloseConfirmationDelegate``; this covers the pane/tab scope on both platforms
/// so a close behind a running command always surfaces a prompt instead of silently doing nothing. The store
/// owns the resolve (`confirmPendingClose()` / `cancelPendingClose()`); this view is pure plumbing.
/// `Otty.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`).
struct CloseConfirmationPanel: View {
    /// The headline ("Close “<pane>”?") the host builds from the pending pane's spec.
    let title: String
    /// Resolve actions wired to the store by the host.
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        OverlayPanel(width: 380) {
            VStack(alignment: .leading, spacing: Otty.Metric.space3) {
                HStack(spacing: Otty.Metric.space2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: Otty.Typeface.body))
                        .foregroundStyle(Otty.Status.warn)
                    Text(title)
                        .font(.system(size: Otty.Typeface.body, weight: .semibold))
                        .foregroundStyle(Otty.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("A process is still running. Closing it will stop the command.")
                    .font(.system(size: Otty.Typeface.footnote))
                    .foregroundStyle(Otty.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Otty.Metric.space2) {
                    Spacer(minLength: 0)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: Otty.Typeface.body))
                        .foregroundStyle(Otty.Text.secondary)
                        .padding(.horizontal, Otty.Metric.space3)
                        .padding(.vertical, Otty.Metric.space1)
                    Button { onConfirm() } label: {
                        Text("Close")
                            .font(.system(size: Otty.Typeface.body, weight: .semibold))
                            .foregroundStyle(Otty.Surface.card)
                            .padding(.horizontal, Otty.Metric.space3)
                            .padding(.vertical, Otty.Metric.space1)
                            .background(
                                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                                    .fill(Otty.Status.warn),
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Otty.Metric.space4)
        }
        #if os(macOS)
        .onExitCommand { onCancel() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            onCancel()
            return .handled
        }
        #endif
    }
}
#endif
