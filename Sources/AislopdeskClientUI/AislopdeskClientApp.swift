// AislopdeskClientApp — L0 scaffold of the native-SwiftUI rewrite (REBUILD-V2 contract).
//
// The old Warp-clone view tree + the custom design-system token target were DELETED in L0. This is the
// minimal building stub: a public `App` that the xcodegen app shell (`Apps/Shared/AppMain.swift`) launches
// via `AislopdeskClientApp.main()` after its five WorkspaceCore seam registrations. It compiles fully
// HEADLESS (no libghostty / Metal / VideoToolbox / SCStream) and uses ONLY system semantic colours/fonts.
//
// L1 replaces this with the real native IDE shell (NSSplitViewController 3-pane / NavigationSplitView, the
// proven `AislopdeskWorkspaceCore` logic behind it, terminal/video behind the factory seams).

import AislopdeskWorkspaceCore
import SwiftUI

/// The single SwiftUI scene the app shell launches (`AislopdeskClientApp.main()`). L0 = placeholder only.
public struct AislopdeskClientApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            RebuildPlaceholderView()
        }
        #if os(macOS)
        Settings {
            Text("Settings — rebuilding")
                .padding()
        }
        #endif
    }
}

/// The L0 placeholder window content — a neutral "rebuild in progress" card on the system window background.
struct RebuildPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Aislopdesk — native UI rebuild in progress")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .background(Color(.windowBackgroundColor))
        #else
            .background(Color(.systemBackground))
        #endif
    }
}
