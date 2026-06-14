//! Keepalive / idle-timeout timing contract — the canonical `KeepaliveTiming` values (the Swift shell mirrors it).
//!
//! UDP has no FIN, so a client that vanishes without a `bye` would leave the host's flow
//! slot pinned. A client keepalive heartbeat + a host idle-timeout reaper reclaim a dead
//! flow. All values are in seconds.

/// Client keepalive cadence (seconds). RFC 7675 §5.1 consent-check default; well under
/// the 30 s NAT-UDP mapping expiry, so it also refreshes the path mapping.
pub const KEEPALIVE_INTERVAL_SECS: f64 = 5.0;

/// Host idle threshold (seconds) before a keepalive-proven flow is declared dead — 6× the
/// interval, tolerating ~5 consecutive keepalive losses before reaping.
pub const IDLE_TIMEOUT_SECS: f64 = 30.0;

/// Host reaper scan cadence (seconds), so worst-case reclaim latency is
/// `IDLE_TIMEOUT_SECS + REAPER_TICK_SECS` ≤ 35 s.
pub const REAPER_TICK_SECS: f64 = 5.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timing_contract_ratios() {
        // idle timeout is 6× the keepalive interval (≥3× minimum-safe ratio).
        assert_eq!(IDLE_TIMEOUT_SECS / KEEPALIVE_INTERVAL_SECS, 6.0);
        assert_eq!(REAPER_TICK_SECS, KEEPALIVE_INTERVAL_SECS);
    }
}
