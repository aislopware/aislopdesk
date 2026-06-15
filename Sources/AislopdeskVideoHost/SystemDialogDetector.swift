#if os(macOS)
import CoreGraphics
import Foundation

/// Host-side façade over the Rust-core classifier behind the "show system popups/prompts in their
/// own pane" feature. The classify rules + secure/system allowlists live in
/// `aislopdesk_core::system_dialog_detector` (the single source of truth), reached over the C-ABI via
/// `RustVideoHostFFI`; this enum keeps only the `WindowSnapshot` / `Dialog` value types the host passes.
///
/// A SYSTEM dialog is a cross-process modal window that NO app-pane would ever capture — the prime
/// case (the user's ask) being a `SecurityAgent` login/admin **password** prompt. The host enumerates
/// the on-screen windows, runs this classifier, and answers the client's `listSystemDialogs` poll with
/// the matches; the client auto-spawns an ephemeral pane per dialog.
///
/// **HW-grounded (probe 2026-06-12 + 2026-06-15, Tahoe 26.5.1):** `SCShareableContent` DOES list the
/// SecurityAgent prompt (own window, layer 1000, onScreen), and `desktopIndependentWindow` captures it
/// with real pixels — it is NOT capture-blocked. While it is up `IsSecureEventInputEnabled() == true`,
/// BUT — corrected 2026-06-15 — that does NOT block injection: the host's `CGEvent(.cghidEventTap)`
/// keystrokes LAND in the field anyway (it fills with dots + authenticates), so the password CAN be
/// typed from the client. `Dialog/isSecure` therefore flags a secure-credential prompt (for the client
/// paste-guard + a "Secure prompt" chip), NOT a view-only restriction.
///
/// **Scope (v1):** system AUTH prompts only — `SecurityAgent` / `coreauthd`. These never overlap with a
/// streamed app window (different system pid, never a child of an app window) nor with the DIALOG-EXPAND
/// union (which handles app-OWNED save/open panels in the streamed pane). The allowlists below are the
/// single expansion point — adding a new system-prompt source is one entry.
public enum SystemDialogDetector {
    /// One enumerated on-screen window (the fields ``classify(_:minSize:)`` reads). Built from an
    /// `SCWindow` on the host; kept as a plain value so the classifier is pure + testable off-device.
    public struct WindowSnapshot: Equatable, Sendable {
        public var windowID: UInt32
        public var ownerName: String
        public var bundleID: String
        public var isOnScreen: Bool
        public var title: String
        public var frame: CGRect
        public init(
            windowID: UInt32,
            ownerName: String,
            bundleID: String,
            isOnScreen: Bool,
            title: String,
            frame: CGRect,
        ) {
            self.windowID = windowID
            self.ownerName = ownerName
            self.bundleID = bundleID
            self.isOnScreen = isOnScreen
            self.title = title
            self.frame = frame
        }
    }

    /// A classified system dialog (shape mirrors the wire ``SystemDialogSummary``).
    public struct Dialog: Equatable, Sendable {
        public var windowID: UInt32
        public var owner: String
        public var title: String
        public var width: Int
        public var height: Int
        /// `true` ⇒ a secure-credential (password/auth) prompt class. NOT a typing restriction — the
        /// host injects keystrokes into these fields fine (see the type doc); flags it for the client.
        public var isSecure: Bool
        public init(windowID: UInt32, owner: String, title: String, width: Int, height: Int, isSecure: Bool) {
            self.windowID = windowID
            self.owner = owner
            self.title = title
            self.width = width
            self.height = height
            self.isSecure = isSecure
        }
    }

    /// Reject sub-`minSize` windows (offscreen helpers, 1×1 indicators) — a real prompt is well above
    /// this. The threshold, the secure/system allowlists, and the classify rules all live in the Rust
    /// core (`aislopdesk_core::system_dialog_detector`, the single source of truth); this reads it once.
    public static let minSize = RustVideoHostFFI.systemDialogMinSize()

    /// Classify one window, or `nil` if it is not a surfaced system dialog. Delegates to the Rust core
    /// over the C-ABI (`RustVideoHostFFI.systemDialogClassify`); this shell only carries the value types.
    public static func classify(_ w: WindowSnapshot, minSize: Int = minSize) -> Dialog? {
        guard let d = RustVideoHostFFI.systemDialogClassify(
            windowID: w.windowID,
            ownerName: w.ownerName,
            bundleID: w.bundleID,
            isOnScreen: w.isOnScreen,
            title: w.title,
            frame: w.frame,
            minSize: minSize,
        ) else { return nil }
        return Dialog(
            windowID: d.windowID,
            owner: d.owner,
            title: d.title,
            width: d.width,
            height: d.height,
            isSecure: d.isSecure,
        )
    }

    /// Classify a whole snapshot into the system dialogs to surface (order preserved).
    public static func detect(_ windows: [WindowSnapshot], minSize: Int = minSize) -> [Dialog] {
        windows.compactMap { classify($0, minSize: minSize) }
    }
}
#endif
