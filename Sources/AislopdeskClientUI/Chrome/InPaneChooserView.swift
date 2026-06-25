// InPaneChooserView — the pane-type chooser rendered AS THE CONTENT of a freshly-minted `.chooser` pane.
//
// New-pane gestures (⌘D / ⌘⇧D split, the `+` button, title-menu split, right-click split, new-session /
// floating) create a real, FOCUSED `.chooser` pane immediately; `PaneContainer` renders THIS view as that
// pane's content. The user picks Terminal or Remote window INLINE — `store.choosePaneKind(paneID, kind)`
// flips the pane's spec kind in place (same `PaneID`) so reconcile materializes the real session (a
// `.remoteGUI` pick then lands in its OWN in-pane window picker). No modal, no popover — the chooser IS the
// pane. Replaces the old `PaneChooserPopover` (a centred overlay), per the "create + focus, content = the
// choices" UX.
//
// Otty.* tokens only (raw font/radius literals fail scripts/check-ds-leaks.sh).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct InPaneChooserView: View {
    let store: WorkspaceStore
    let paneID: PaneID

    /// The kinds a user can deliberately create (Terminal, Remote window) — the shared registry list, so the
    /// chooser, the navigator, and the cheat sheet can never drift.
    private var options: [PaneChooserOption] { PaneChooserRegistry.options }

    var body: some View {
        VStack(spacing: Otty.Metric.space2) {
            Spacer(minLength: 0)
            Text("New Pane")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Text("Choose what to open in this pane")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
                .padding(.bottom, Otty.Metric.space2)
            VStack(spacing: Otty.Metric.space2) {
                ForEach(options, id: \.kind) { option in
                    InPaneChooserCard(option: option) { store.choosePaneKind(paneID, kind: option.kind) }
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(Otty.Metric.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// One large, focusable chooser card: SF-Symbol + title + single-key mnemonic hint. The mnemonic is a bare
/// `.keyboardShortcut` so a focused chooser pane resolves on a single key press (t = Terminal, r = Remote).
private struct InPaneChooserCard: View {
    let option: PaneChooserOption
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space3) {
                Image(systemName: option.symbol)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(Otty.State.accent)
                    .frame(width: 22)
                Text(option.title)
                    .font(.system(size: Otty.Typeface.body))
                    .foregroundStyle(Otty.Text.primary)
                Spacer(minLength: Otty.Metric.space2)
                Text(String(option.mnemonic).uppercased())
                    .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Otty.Text.secondary)
            }
            .padding(.horizontal, Otty.Metric.space3)
            .frame(height: 44)
            .background(hovering ? Otty.State.hover : Otty.Surface.element)
            .overlay(
                RoundedRectangle(cornerRadius: Otty.Metric.radiusControl)
                    .stroke(Otty.Line.subtle, lineWidth: Otty.Metric.hairline),
            )
            .clipShape(RoundedRectangle(cornerRadius: Otty.Metric.radiusControl))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(option.mnemonic), modifiers: [])
        .onHover { hovering = $0 }
    }
}
#endif
