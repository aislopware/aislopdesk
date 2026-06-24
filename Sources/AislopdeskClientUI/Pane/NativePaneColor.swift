// NativePaneColor — cross-platform system colour aliases for the pane grid (REBUILD-V2, L2).
//
// The pane views use only SYSTEM semantic colours; AppKit's `NSColor`-backed `Color(.windowBackgroundColor)`
// family is macOS-only, so this one helper localizes the `#if os(macOS)` / UIKit fallback split. No
// design-system, no custom tokens — these all resolve to the OS's auto dark/light system palette.

#if canImport(SwiftUI)
import SwiftUI

enum NativePaneColor {
    /// The chrome / window background (pane header, divider bands, empty content).
    static var window: Color {
        #if os(macOS)
        Color(.windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    /// The terminal / editable content surface background.
    static var terminalBackground: Color {
        #if os(macOS)
        Color(.textBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    /// The hairline separator colour.
    static var separator: Color {
        #if os(macOS)
        Color(.separatorColor)
        #else
        Color(.separator)
        #endif
    }
}
#endif
