import Foundation

/// Cursor side-channel message (doc 17 §3.3): the host strips the cursor from the
/// video (`showsCursor=false`) and instead streams its position + shape over a
/// SEPARATE small UDP socket so pointer latency = RTT, decoupled from encode/decode.
///
/// The message is deliberately tiny (the spec requires **< 64 bytes**): it carries
/// the cursor position in **host-window space** (points), a `shapeID` referencing a
/// shape the client has cached, and the shape's hotspot. Shape *bitmaps* are sent
/// rarely (only when a new `shapeID` appears) over a side path — this hot message
/// stays position-only-sized so it can fire at ~120 Hz.
///
/// Wire layout (big-endian), `< 64` bytes:
/// ```
/// off 0: UInt8   type (=1 cursorUpdate)
/// off 1: UInt16  shapeID
/// off 3: UInt8   visible (0/1)
/// off 4: Float64 x        (host-window-space point)
/// off12: Float64 y
/// off20: Float64 hotspotX
/// off28: Float64 hotspotY
/// ```
/// = **36 bytes** — comfortably under the 64-byte budget.
public struct CursorUpdate: Equatable, Sendable {
    /// Host-window-space position of the cursor (points).
    public var position: VideoPoint
    /// Identifier of the cursor shape (client caches the bitmap by this id).
    public var shapeID: UInt16
    /// The shape's hotspot offset (points), so the client composites it correctly.
    public var hotspot: VideoPoint
    /// Whether the cursor is currently visible over the window.
    public var visible: Bool

    public init(position: VideoPoint, shapeID: UInt16, hotspot: VideoPoint, visible: Bool = true) {
        self.position = position
        self.shapeID = shapeID
        self.hotspot = hotspot
        self.visible = visible
    }

    /// On-wire message type byte for a cursor update.
    public static let messageType: UInt8 = 1
    /// Encoded size in bytes (fixed).
    public static let encodedSize = 36

    /// Encodes the update via the Rust `aislopdesk-core` cursor codec — the single source of truth
    /// shared with the Android client (the wire format is pinned by golden vectors). A 36-byte
    /// fixed message, so Rust is faster than building `Data`.
    public func encode() -> Data {
        RustVideoFFI.encode(self)
    }

    /// Decodes via the Rust cursor codec — the single source of truth (the wire format is pinned by
    /// golden vectors). Non-finite coordinates are rejected as `.malformed`: a NaN off the wire
    /// would otherwise propagate through the client's aspect-fit math into a `CALayer` frame and
    /// crash with `CALayerInvalidGeometry`.
    public static func decode(_ data: Data) throws -> Self {
        try RustVideoFFI.decodeCursor(data)
    }
}
