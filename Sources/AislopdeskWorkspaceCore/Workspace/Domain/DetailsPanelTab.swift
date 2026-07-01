import Foundation

// MARK: - DetailsPanelTab (the cross-module Details-panel tab vocabulary)

/// The four tabs of the right-hand Details / inspector panel: Info | Outline | Git | Files.
///
/// This is the shared vocabulary the COMMAND layer (``WorkspaceAction/selectDetailsTab(_:)`` + its four
/// `Details: *` registry bindings) and the VIEW layer (the client UI's segmented Details header + the
/// `@Observable` selection state) both speak — `AislopdeskWorkspaceCore` cannot see the client UI's
/// view-local tab enum, so the tab identity is hoisted here (E9/WI-7, ES-E9-5). A pure value enum (no
/// SwiftUI / view import) so the `selectDetailsTab` routing is fully unit-testable with no view.
///
/// The `String` raw values double as the stable on-the-wire-free tab ids the view reads, and the
/// `CaseIterable` order is the canonical tab order (Info first, then Outline / Git / Files).
public enum DetailsPanelTab: String, CaseIterable, Sendable {
    case info
    case outline
    case git
    case files
}
