import CAislopdeskFFI
import Foundation

/// Swift-side bridge to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` (and the unsafe pointer marshaling it requires) is
/// contained in this file; the rest of `AislopdeskProtocol` calls these typed, safe
/// wrappers. The Rust core is a byte-/bit-exact port of the Swift codecs (proven by the
/// `golden_parity` test against the `aislopdesk-corevectors` dumper), so these wrappers are
/// drop-in replacements for the native Swift implementations — the swap exists so the
/// macOS/iOS app and a future Android client run *the identical algorithm bytes*.
///
/// Memory contract (mirrors `aislopdesk_ffi.h`): buffers passed *in* are borrowed for the
/// call only; any `AisdBytes` the library returns owns a Rust allocation and is released
/// with `aisd_bytes_free` / `aisd_wire_message_free` before this wrapper returns.
enum RustFFI {
    /// Wrap-aware signed 32-bit sequence distance `a - b` (positive ⇒ `a` is ahead).
    ///
    /// A trivial, stateless call used as the link smoke for the boundary: if this returns
    /// the right value, the Rust staticlib is linked and the C ABI is callable from Swift.
    static func seqDistance(_ a: UInt32, _ b: UInt32) -> Int32 {
        aisd_seq_distance(a, b)
    }
}
