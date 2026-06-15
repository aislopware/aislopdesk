import Foundation

/// Component 5 (recovery-redundancy, 2026-06-11): host-side dedup window for recovery-request
/// datagrams. The client now sends each logical `requestLTRRefresh` / `requestIDR` as N
/// byte-identical copies spaced ~3 ms apart (``AislopdeskVideoProtocol/RecoveryRequestRedundancy``);
/// this collapses those copies back to ONE host action.
///
/// WHY the host needs it (and the capturer latch alone is not enough): same-frame duplicates
/// dedup via the capturer's Bool latch, but copies STRADDLING a capture-frame boundary re-latch
/// AFTER the drain — on the LTR path (no cooldown exists there) that encodes a SECOND
/// `ForceLTRRefresh` P-frame and resets `framesSinceAnchor`. Even a 6 ms copy spread straddles the
/// 16.7 ms @60fps boundary often, so dedup here is REQUIRED for the LTR path and
/// belt-and-braces for the IDR path (whose `RecoveryIDRPolicy` admission absorbs duplicates too).
///
/// KEY = the FULL raw datagram bytes (type byte + entire body): byte-equality means zero coupling
/// to the wire layout — the client encodes ONCE per logical request and re-sends the identical
/// `Data`. A duplicate does NOT refresh the original's timestamp: a legitimately identical
/// re-request ages back to admissible one `windowSeconds` after the FIRST sighting.
///
/// The dedup ALGORITHM (the prune-window + byte-compare ring) lives in the Rust core
/// (`aislopdesk_core::recovery_request_deduper`, the single source of truth); this class is a thin
/// owner of the opaque core handle, reached over the C-ABI via ``RustVideoHostFFI``. It is a
/// `final class` (not the former value struct) so it can own the handle and free it in `deinit`.
///
/// `@unchecked Sendable`: the handle is not thread-safe, but every use is single-owner — the host
/// session holds it as an actor-isolated property and the loopback validator / tests drive it from
/// a single thread, so no two threads ever touch the handle concurrently.
public final class RecoveryRequestDeduper: @unchecked Sendable {
    private let handle: OpaquePointer

    /// - Parameters:
    ///   - windowSeconds: duplicates of an admitted payload are dropped for this long after its
    ///     FIRST sighting. Sized ≥ 2× the max client copy spread + reorder skew and < every
    ///     legitimate re-request spacing. `0` ⇒ always admit (kill switch).
    ///   - capacity: max remembered payloads (floored to 1 by the core).
    public init(windowSeconds: TimeInterval = 0.025, capacity: Int = 16) {
        handle = RustVideoHostFFI.recoveryDeduperNew(windowSeconds: windowSeconds, capacity: capacity)
    }

    deinit {
        RustVideoHostFFI.recoveryDeduperFree(handle)
    }

    /// `true` = first sighting within the window (caller should process); `false` = duplicate
    /// (caller should drop). Delegates to the Rust core over the C-ABI.
    public func admit(_ datagram: Data, now: TimeInterval) -> Bool {
        RustVideoHostFFI.recoveryDeduperAdmit(handle, datagram: datagram, now: now)
    }
}
