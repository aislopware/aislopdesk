import Foundation

/// Window-geometry metadata channel (doc 17 §3.8): a SEPARATE channel carrying a
/// remote GUI window's move / resize / title so the client `NSWindow`/view can
/// reposition *before* the next video frame. Every per-window remoting solution
/// (RDP RemoteApp/RAIL, X11, Xpra) has this.
///
/// Host-side production: AX `kAXWindowMovedNotification` fires at the END of a move;
/// during a drag the host polls `CGWindowListCopyWindowInfo` per frame so the client
/// window never lags (doc 18 §B). This codec is the pure wire form.
public enum WindowGeometryMessage: Equatable, Sendable {
    /// Window moved to a new top-left origin (host CG space, points).
    case move(VideoPoint)
    /// Window resized to a new size (points).
    case resize(VideoSize)
    /// Window moved AND resized in one frame (the common drag-resize case).
    case bounds(VideoRect)
    /// Window title changed (UTF-8).
    case title(String)

    public var messageType: UInt8 {
        switch self {
        case .move: 1
        case .resize: 2
        case .bounds: 3
        case .title: 4
        }
    }

    /// Encodes via the Rust `aislopdesk-core` window-geometry codec — the single source of truth
    /// shared with the Android client (the wire format is pinned by golden vectors).
    public func encode() -> Data {
        RustVideoFFI.encode(self)
    }

    /// Decodes via the Rust window-geometry codec — the single source of truth (the wire format is
    /// pinned by golden vectors). A non-finite coordinate, a non-UTF-8 title, or an unknown type is
    /// rejected as `.malformed`; a short body is `.truncated`.
    public static func decode(_ data: Data) throws -> Self {
        try RustVideoFFI.decodeWindowGeometry(data)
    }
}
