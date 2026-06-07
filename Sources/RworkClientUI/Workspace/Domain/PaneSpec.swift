import Foundation

// MARK: - Identity

/// Stable identity for a single pane (a leaf in the ``PaneNode`` tree).
///
/// A `PaneID` is the join key between the two halves of the workspace architecture
/// (docs/22 §1.1): the **tree of intent** (this pure value tree) and the **table of liveness**
/// (the `[PaneID: any PaneSessionHandle]` registry in the later `WorkspaceStore`). It is minted
/// once when a leaf is created and is **stable for the lifetime of that pane's session** —
/// split / focus / zoom / resize re-renders never change it, only a true session swap does.
/// That stability is load-bearing: SwiftUI keys each leaf host view with `.id(PaneID)` so a
/// `GhosttySurface` / video pipeline / input `Coordinator` is never reused across panes
/// (docs/22 §7, the `.id(PaneID)` identity hazard).
public struct PaneID: Hashable, Codable, Sendable {
    public let raw: UUID
    /// Mints a fresh identity. The default is the common path (a brand-new pane); pass an
    /// explicit `UUID` only when reconstructing a known identity (e.g. decode, or a test that
    /// pins a value for assertions).
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// Stable identity for a tab (one ``Tab`` owns one ``PaneNode`` tree).
///
/// Mirrors ``PaneID``: minted once, stable across the tab's lifetime, survives the persistence
/// round-trip (docs/22 §6) so focus / active-tab references stay valid after restore.
public struct TabID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

// MARK: - Leaf intent (what a pane IS — never a live object)

/// What a pane *is*. The kind selects which proven per-session stack the live layer will
/// materialize for the leaf (docs/22 §7): a plain remote terminal, a Claude Code terminal with
/// a second read-only inspector channel, or a remote-GUI video window.
///
/// `String`-raw + hand-stable so the persisted JSON discriminator is human-readable and
/// versionable.
public enum PaneKind: String, Codable, Sendable, Equatable {
    /// A remote PTY terminal (PATH 1 byte pipeline).
    case terminal
    /// A Claude Code terminal — a `terminal` plus the read-only structured inspector channel.
    case claudeCode
    /// A remote-GUI video window (PATH 2 UDP media + cursor side-channel).
    case remoteGUI
}

/// Where a terminal / Claude Code pane points: the host + control port of the PATH 1
/// connection. Value-typed and `Codable` so it persists with the tree and is the *intent* the
/// store later hands to `LivePaneSession.make` — the tree never holds the live `RworkClient`.
public struct Endpoint: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Where a remote-GUI (video) pane points. PATH 2 uses two UDP sockets — one for the media
/// (encoded video) stream, one for the cursor side-channel — plus the host-side window identity
/// being mirrored. Persisted with the tree so a restored video pane reopens its form pre-filled,
/// but is **never** auto-connected (UDP is user-initiated, docs/22 §6).
public struct VideoEndpoint: Codable, Sendable, Equatable {
    public var host: String
    /// UDP port carrying the encoded video frames.
    public var mediaPort: UInt16
    /// UDP port carrying the cursor side-channel.
    public var cursorPort: UInt16
    /// The host-side window being mirrored (ScreenCaptureKit window id).
    public var windowID: UInt32
    /// Human-readable window title (shown in pane chrome before the stream is live).
    public var title: String
    public init(host: String, mediaPort: UInt16, cursorPort: UInt16, windowID: UInt32, title: String) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
        self.title = title
    }
}

/// The full value-typed description of a leaf: its kind, its display title, and the (optional)
/// endpoint it points at. Exactly one of ``endpoint`` / ``video`` is populated in practice —
/// `terminal`/`claudeCode` carry an ``Endpoint``, `remoteGUI` carries a ``VideoEndpoint`` — but
/// both are optional so a pane can exist in an "unconfigured" state (form not yet filled) and
/// still round-trip through persistence.
///
/// A `PaneSpec` is pure intent: it is what the pane *should* be, not a handle to anything live.
/// The store reads it to materialize a session; mutating it (e.g. rename, fill in an endpoint)
/// is done through ``PaneNode/updatingSpec(_:_:)`` and triggers a reconcile downstream.
public struct PaneSpec: Codable, Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    /// Set for `terminal` / `claudeCode` panes.
    public var endpoint: Endpoint?
    /// Set for `remoteGUI` panes.
    public var video: VideoEndpoint?

    public init(kind: PaneKind, title: String, endpoint: Endpoint? = nil, video: VideoEndpoint? = nil) {
        self.kind = kind
        self.title = title
        self.endpoint = endpoint
        self.video = video
    }
}

// MARK: - Focus intent

/// A focus-movement intent, resolved geometrically against the solved layout (docs/22 §2.1).
///
/// The four cardinal directions move to the nearest pane in that direction *as the user sees it*
/// (``FocusResolver/neighbor(of:_:in:)`` works on the same rects the layout renders, never on
/// abstract tree position). `next` / `previous` cycle through the pre-order leaf list with wrap
/// (``FocusResolver/cycle(_:from:forward:)``), which is what `⌘]` / `⌘[` and a compact swipe map
/// to.
public enum FocusDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
    /// Cycle forward through the leaves (wraps past the end).
    case next
    /// Cycle backward through the leaves (wraps past the start).
    case previous
}
