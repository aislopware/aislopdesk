// PreferencesEnvironment — a SwiftUI environment slot carrying the single live ``PreferencesStore`` down
// to deep views (the AgentInputFooter needs it for the W4 notification dismissal/enable persistence
// without threading it through every intermediate view). The App scene injects it once at the root.
//
// `nil` is the safe default — a footer with no preferences shows the suggestion chip (Warp's default)
// and a click is a no-op persistence-wise, which keeps headless tests / previews trivial.

import AislopdeskWorkspaceCore
import SwiftUI

extension EnvironmentValues {
    /// The single live preferences owner (W4 notification persistence). `nil` outside the app scene.
    @Entry var preferencesStore: PreferencesStore?
}

extension View {
    /// Inject the live ``PreferencesStore`` into the environment (called once at the scene root).
    func preferencesStore(_ store: PreferencesStore?) -> some View {
        environment(\.preferencesStore, store)
    }
}
