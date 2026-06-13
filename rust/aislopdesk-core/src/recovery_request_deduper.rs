//! Host-side dedup window for recovery-request datagrams — a port of Swift
//! `RecoveryRequestDeduper`.
//!
//! The client sends each logical `request_ltr_refresh` / `request_idr` as N byte-identical
//! copies spaced a few ms apart (see [`RecoveryRequestRedundancy`](crate::recovery_policy));
//! this collapses those copies back to ONE host action. Same-frame duplicates dedup via the
//! capturer's latch, but copies STRADDLING a capture-frame boundary re-latch after the drain —
//! on the LTR path (no cooldown) that would encode a SECOND refresh P-frame. Dedup here is
//! therefore required for the LTR path and belt-and-braces for the IDR path.
//!
//! KEY = the FULL raw datagram bytes (type byte + entire body). Byte-equality means zero coupling
//! to the wire layout. A ring (not a single slot) so interleaved bursts (copies for lost frame N
//! interleaving with copies for frame N+1 — different bytes) both dedup correctly. A duplicate
//! does NOT refresh the original's timestamp: a legitimately identical re-request ages back to
//! admissible one `window_seconds` after the FIRST sighting, never starved by its own copies.
//!
//! Pure value type, no wall clock (the caller injects `now` in seconds).

/// Duplicates of an admitted payload are dropped for this long after the FIRST sighting.
pub const DEFAULT_WINDOW_SECONDS: f64 = 0.025;

/// Max remembered payloads (a linear scan is fine at this size).
pub const DEFAULT_CAPACITY: usize = 16;

/// A byte-equality dedup ring over recently-admitted recovery datagrams.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryRequestDeduper {
    window_seconds: f64,
    capacity: usize,
    /// Accepted payloads still inside the window, oldest first.
    entries: Vec<(Vec<u8>, f64)>,
}

impl Default for RecoveryRequestDeduper {
    /// The shipped defaults: a 25 ms window, 16-entry ring.
    fn default() -> Self {
        Self::new(DEFAULT_WINDOW_SECONDS, DEFAULT_CAPACITY)
    }
}

impl RecoveryRequestDeduper {
    /// Builds a deduper.
    ///
    /// `window_seconds` is sized ≥ 2× the max client copy spread and < every legitimate
    /// re-request spacing; `0` ⇒ always admit (kill switch). `capacity` is floored to 1.
    #[must_use]
    pub fn new(window_seconds: f64, capacity: usize) -> Self {
        Self {
            window_seconds,
            capacity: capacity.max(1),
            entries: Vec::new(),
        }
    }

    /// `true` = first sighting within the window (the caller should process); `false` =
    /// duplicate (the caller should drop). Prunes expired entries, then byte-compares against
    /// the survivors.
    pub fn admit(&mut self, datagram: &[u8], now: f64) -> bool {
        if self.window_seconds <= 0.0 {
            return true;
        }
        // Exact complement of Swift's `removeAll { now - acceptedAt > windowSeconds }` (retain =
        // NOT remove). The negated comparison is INTENTIONAL (not `<=`): for a degenerate
        // `now == NaN` it KEEPS every entry exactly as Swift does (`NaN > w` is false ⇒ removeAll
        // keeps), where a bare `<=` would instead drop them all (NaN <= w is false).
        #[allow(clippy::neg_cmp_op_on_partial_ord)]
        self.entries
            .retain(|(_, accepted_at)| !(now - accepted_at > self.window_seconds));
        if self.entries.iter().any(|(payload, _)| payload == datagram) {
            return false;
        }
        let len = self.entries.len();
        if len >= self.capacity {
            // drop-oldest down to capacity-1 so the append lands at exactly `capacity`.
            self.entries.drain(..=len - self.capacity);
        }
        self.entries.push((datagram.to_vec(), now));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::RecoveryMessage;

    fn idr_wire(last_decoded: u32) -> Vec<u8> {
        RecoveryMessage::RequestIdr {
            last_decoded_frame_id: last_decoded,
        }
        .encode()
    }

    fn ltr_wire(from: u32, to: u32, last_decoded: u32) -> Vec<u8> {
        RecoveryMessage::RequestLtrRefresh {
            from_frame_id: from,
            to_frame_id: to,
            last_decoded_frame_id: last_decoded,
        }
        .encode()
    }

    #[test]
    fn redundant_burst_dedups_to_one() {
        let mut d = RecoveryRequestDeduper::default();
        let wire = ltr_wire(50, 50, 49);
        assert!(d.admit(&wire, 100.000));
        assert!(!d.admit(&wire, 100.005));
        assert!(!d.admit(&wire, 100.010));
    }

    #[test]
    fn nan_now_keeps_entries_like_swift() {
        // Degenerate/unreachable, but exact-port fidelity: Swift's `removeAll` keeps every entry
        // when `now == NaN` (`NaN > w` is false), so the duplicate is still seen and dropped. A
        // bare `now - acc <= w` predicate would instead drop all and re-admit.
        let mut d = RecoveryRequestDeduper::default();
        let wire = ltr_wire(50, 50, 49);
        assert!(d.admit(&wire, 100.000));
        assert!(!d.admit(&wire, f64::NAN));
    }

    #[test]
    fn window_expiry_without_timestamp_refresh() {
        let mut d = RecoveryRequestDeduper::new(0.020, DEFAULT_CAPACITY);
        let wire = idr_wire(400);
        assert!(d.admit(&wire, 100.000));
        assert!(!d.admit(&wire, 100.010), "still inside the window");
        assert!(
            !d.admit(&wire, 100.019),
            "a drop must not extend the window"
        );
        assert!(
            d.admit(&wire, 100.025),
            "a legitimate identical re-request ages back to admissible"
        );
    }

    #[test]
    fn distinct_context_both_admitted() {
        let mut d = RecoveryRequestDeduper::default();
        assert!(d.admit(&ltr_wire(50, 50, 49), 100.000));
        assert!(d.admit(&ltr_wire(51, 51, 49), 100.002));
        assert!(d.admit(&idr_wire(49), 100.004));
    }

    #[test]
    fn type_byte_discrimination() {
        let mut d = RecoveryRequestDeduper::default();
        assert!(d.admit(&ltr_wire(50, 50, 49), 100.000));
        assert!(d.admit(&idr_wire(400), 100.001));
    }

    #[test]
    fn capacity_eviction_drop_oldest() {
        let mut d = RecoveryRequestDeduper::new(10.0, 16);
        let first = idr_wire(0);
        assert!(d.admit(&first, 100.0));
        for i in 1..=16u32 {
            assert!(d.admit(&idr_wire(i), 100.0 + f64::from(i) * 0.0001));
        }
        assert!(
            d.admit(&first, 100.01),
            "evicted by capacity ⇒ admitted despite the window"
        );
    }

    #[test]
    fn zero_window_admits_everything() {
        let mut d = RecoveryRequestDeduper::new(0.0, DEFAULT_CAPACITY);
        let wire = ltr_wire(50, 50, 49);
        assert!(d.admit(&wire, 100.000));
        assert!(d.admit(&wire, 100.000));
        assert!(d.admit(&wire, 100.005));
    }

    #[test]
    fn interleaved_bursts_both_dedup_correctly() {
        let mut d = RecoveryRequestDeduper::default();
        let a = ltr_wire(50, 50, 49);
        let b = ltr_wire(51, 51, 49);
        assert!(d.admit(&a, 100.000)); // A
        assert!(d.admit(&b, 100.003)); // B
        assert!(!d.admit(&a, 100.005)); // A'
        assert!(!d.admit(&b, 100.008)); // B'
        assert!(!d.admit(&a, 100.010)); // A"
    }
}
