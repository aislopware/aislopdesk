// DismissBackdrop — a transparent, full-window click-blocker (warp-overlays-actions.md §1.1 `Dismiss` +
// `prevent_interaction_with_other_elements()`). It is NOT a tinted scrim (the palette uses no dim) — just
// an invisible layer that (a) blocks clicks reaching the chrome behind, and (b) closes the overlay when
// tapped OUTSIDE its content. The content view stops propagation (its own Button/onTapGesture consumes the
// tap) so a click INSIDE never triggers the dismiss.
//
// The Modal (§3.1) uses `ModalScrim` instead (a real 70%-black backdrop).

import AislopdeskDesignSystem
import SwiftUI

struct DismissBackdrop<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            // Transparent click-blocker — `Color.clear` doesn't hit-test, so use a near-zero-opacity fill
            // with an explicit contentShape so the outside-tap closes the overlay.
            Rectangle()
                .fill(Color.black.opacity(0.001)) // ds-leak-allow: near-zero hit-test fill, not a scrim
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
