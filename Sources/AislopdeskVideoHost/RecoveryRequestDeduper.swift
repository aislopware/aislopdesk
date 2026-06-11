import Foundation

/// Component 5 (recovery-redundancy, 2026-06-11): host-side dedup window for recovery-request
/// datagrams. The client now sends each logical `requestLTRRefresh` / `requestIDR` as N
/// byte-identical copies spaced ~3 ms apart (``AislopdeskVideoProtocol/RecoveryRequestRedundancy``);
/// this struct collapses those copies back to ONE host action.
///
/// WHY the host needs it (and the capturer latch alone is not enough): same-frame duplicates
/// dedup via the capturer's Bool latch, but copies STRADDLING a capture-frame boundary re-latch
/// AFTER the drain — on the LTR path (no cooldown exists there) that encodes a SECOND
/// `ForceLTRRefresh` P-frame and resets `framesSinceAnchor`. Even a 6 ms copy spread straddles the
/// 16.7 ms @60fps boundary often, so dedup here is REQUIRED for the LTR path and
/// belt-and-braces for the IDR path (whose `RecoveryIDRPolicy` admission absorbs duplicates too).
///
/// KEY = the FULL raw datagram bytes (type byte + entire body, including the component-2
/// `lastDecodedFrameID` context). Byte-equality means zero coupling to the wire layout: the
/// client encodes ONCE per logical request and re-sends the identical `Data`, so any future body
/// change is covered automatically. A ring (not a single slot) so interleaved bursts (copies for
/// lost frame N interleaving with copies for frame N+1 — different bytes) both dedup correctly.
///
/// A duplicate does NOT refresh the original's timestamp: a legitimately identical re-request
/// (same lost range, same frontier) ages back to admissible one `windowSeconds` after the FIRST
/// sighting, never starved by its own copies.
///
/// Pure value type, no wall clock (caller injects `now` in seconds) — headlessly unit-testable
/// like ``RecoveryIDRPolicy`` / ``LiveCongestionController``.
public struct RecoveryRequestDeduper: Sendable {
    private let windowSeconds: TimeInterval
    private let capacity: Int
    /// Accepted payloads still inside the window, oldest first.
    private var entries: [(payload: Data, acceptedAt: TimeInterval)] = []

    /// - Parameters:
    ///   - windowSeconds: duplicates of an admitted payload are dropped for this long after its
    ///     FIRST sighting. Sized ≥ 2× the max client copy spread ((copies−1)·spacing = 12 ms at
    ///     copies=5, spacing 3 ms) + reorder skew and < every legitimate re-request spacing
    ///     (lossy escalation floor 30 ms; normal 2·RTT ≥ ~100 ms). `0` ⇒ always admit (kill switch).
    ///   - capacity: max remembered payloads (≤17-byte payloads × 16 entries — trivial memory;
    ///     linear scan is fine at this size).
    public init(windowSeconds: TimeInterval = 0.025, capacity: Int = 16) {
        self.windowSeconds = windowSeconds
        self.capacity = max(1, capacity)
    }

    /// `true` = first sighting within the window (caller should process); `false` = duplicate
    /// (caller should drop). Prunes expired entries, then byte-compares against the survivors.
    public mutating func admit(_ datagram: Data, now: TimeInterval) -> Bool {
        guard windowSeconds > 0 else { return true }
        entries.removeAll { now - $0.acceptedAt > windowSeconds }
        if entries.contains(where: { $0.payload == datagram }) { return false }
        if entries.count >= capacity { entries.removeFirst(entries.count - capacity + 1) }
        entries.append((payload: datagram, acceptedAt: now))
        return true
    }
}
