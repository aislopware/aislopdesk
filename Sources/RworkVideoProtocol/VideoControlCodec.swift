import Foundation

/// Session bring-up control messages for the GUI video path (PATH 2). These travel
/// on the **control** datagram type of the video session and establish a session
/// before any video/cursor/geometry/input datagram flows.
///
/// The PATH 2 session is plain UDP (doc 17 §3.6) — there is no TCP handshake like
/// PATH 1's `hello`/`helloAck` (doc 20 §8). Instead a tiny control exchange runs
/// over the same UDP path the media uses:
///
/// 1. Client → host `hello(protocolVersion, requestedWindowID, viewport)` —
///    announces the client, the window it wants to remote, and the client viewport
///    size (so the host can size capture/encode to the client surface).
/// 2. Host → client `helloAck(accepted, streamID, captureWidth, captureHeight,
///    windowBoundsCG)` — confirms (or rejects) and reports the negotiated capture
///    dimensions + the window's current CG-top-left bounds (the client maps input
///    against these until the geometry channel updates them).
/// 3. Either side may send `bye` to tear the session down cleanly.
///
/// `protocolVersion` MUST equal ``RworkVideoProtocol/version`` — the host accepts
/// only the exact version (no fallback, mirroring PATH 1's strict version check,
/// doc 20 §4).
///
/// Wire layout (big-endian), `[UInt8 type][body]`:
/// ```
/// type 1 hello:    UInt16 protocolVersion | UInt32 requestedWindowID
///                  | Float64 viewportW | Float64 viewportH
/// type 2 helloAck: UInt8 accepted(0/1) | UInt32 streamID
///                  | UInt16 captureWidth | UInt16 captureHeight
///                  | Float64 boundsX | boundsY | boundsW | boundsH
/// type 3 bye:      (no body)
/// ```
public enum VideoControlMessage: Equatable, Sendable {
    /// Client → host: open a session for `requestedWindowID`, sized to `viewport`.
    case hello(protocolVersion: UInt16, requestedWindowID: UInt32, viewport: VideoSize)
    /// Host → client: accept/reject + negotiated capture size + the window's current
    /// CG-top-left bounds (the input-mapping origin until geometry updates arrive).
    case helloAck(accepted: Bool, streamID: UInt32, captureWidth: UInt16, captureHeight: UInt16, windowBoundsCG: VideoRect)
    /// Either side: clean session teardown.
    case bye

    public var messageType: UInt8 {
        switch self {
        case .hello: return 1
        case .helloAck: return 2
        case .bye: return 3
        }
    }

    public func encode() -> Data {
        var out = Data()
        out.append(messageType)
        switch self {
        case .hello(let version, let windowID, let viewport):
            out.appendBE(version)
            out.appendBE(windowID)
            out.appendBE(viewport.width)
            out.appendBE(viewport.height)
        case .helloAck(let accepted, let streamID, let w, let h, let bounds):
            out.append(accepted ? 1 : 0)
            out.appendBE(streamID)
            out.appendBE(w)
            out.appendBE(h)
            out.appendBE(bounds.origin.x)
            out.appendBE(bounds.origin.y)
            out.appendBE(bounds.size.width)
            out.appendBE(bounds.size.height)
        case .bye:
            break
        }
        return out
    }

    public static func decode(_ data: Data) throws -> VideoControlMessage {
        var reader = VideoByteReader(data)
        let type = try reader.readUInt8()
        switch type {
        case 1:
            let version = try reader.readUInt16()
            let windowID = try reader.readUInt32()
            let w = try reader.readFloat64()
            let h = try reader.readFloat64()
            return .hello(protocolVersion: version, requestedWindowID: windowID, viewport: VideoSize(width: w, height: h))
        case 2:
            let accepted = try reader.readUInt8() != 0
            let streamID = try reader.readUInt32()
            let cw = try reader.readUInt16()
            let ch = try reader.readUInt16()
            let bx = try reader.readFloat64()
            let by = try reader.readFloat64()
            let bw = try reader.readFloat64()
            let bh = try reader.readFloat64()
            return .helloAck(accepted: accepted, streamID: streamID, captureWidth: cw, captureHeight: ch,
                             windowBoundsCG: VideoRect(x: bx, y: by, width: bw, height: bh))
        case 3:
            return .bye
        default:
            throw VideoProtocolError.malformed("unknown video control message type \(type)")
        }
    }
}
