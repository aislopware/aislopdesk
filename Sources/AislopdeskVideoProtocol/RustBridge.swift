import CAislopdeskFFI
import Foundation

/// Swift-side bridge from `AislopdeskVideoProtocol` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the video wire codecs is contained here; the codec types
/// call these typed wrappers so their public APIs are unchanged (the strangler swap). The
/// Rust core is a byte-/bit-exact port of these Swift codecs (proven by golden vectors and
/// re-proven through these wrappers by the `Rust*ParityTests`), so they are drop-in
/// replacements — one source of truth shared with the Android client.
///
/// Memory contract (mirrors `aislopdesk_ffi.h`): buffers passed *in* are borrowed for the
/// call only; any `AisdBytes` the library returns owns a Rust allocation and is released with
/// `aisd_bytes_free` before the wrapper returns.
enum RustVideoFFI {
    /// Encodes a cursor update (fixed 36 bytes) via the Rust codec. Falls back to the native
    /// encoder on the (unreachable) FFI failure.
    static func encode(_ update: CursorUpdate) -> Data {
        var out = AisdBytes()
        let status = aisd_cursor_update_encode(
            update.shapeID,
            update.visible ? 1 : 0,
            update.position.x,
            update.position.y,
            update.hotspot.x,
            update.hotspot.y,
            &out
        )
        guard status == AISD_OK, let ptr = out.ptr, out.len > 0 else {
            return update.encodeNative()
        }
        defer { aisd_bytes_free(out) }
        return Data(bytes: ptr, count: out.len)
    }

    /// Decodes a cursor update via the Rust codec, throwing the same ``VideoProtocolError``
    /// cases as the native decoder (`.malformed` for wrong type / non-finite, `.truncated`
    /// for a short body).
    static func decodeCursor(_ data: Data) throws -> CursorUpdate {
        var out = AisdCursorUpdate(shape_id: 0, visible: 0, x: 0, y: 0, hotspot_x: 0, hotspot_y: 0)
        let status: AisdStatus = data.withUnsafeBytes { raw in
            aisd_cursor_update_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            return CursorUpdate(
                position: VideoPoint(x: out.x, y: out.y),
                shapeID: out.shape_id,
                hotspot: VideoPoint(x: out.hotspot_x, y: out.hotspot_y),
                visible: out.visible != 0
            )
        case AISD_ERR_MALFORMED:
            throw VideoProtocolError.malformed("rust: malformed cursor update")
        default:
            throw VideoProtocolError.truncated
        }
    }
}
