//! `live_bitrate_policy` + `adaptive_playout`: pure, scalar bitrate / playout-delay policies
//! (called ~per resolution change or once per playout step, never per frame).

use aislopdesk_core::adaptive_playout;
use aislopdesk_core::live_bitrate_policy;

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, never below `floor` or the minimum. Wraps
/// [`live_bitrate_policy::target_bitrate`].
///
/// The caller resolves the `bits_per_pixel` density (e.g. from `AISLOPDESK_BPP`) and passes it
/// in, so the core stays environment-free and the result is deterministic.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    live_bitrate_policy::target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel)
}

/// One hysteretic step of the adaptive playout-delay policy (milliseconds).
///
/// For the client's deadline presentation pacer. Maps the live measured `jitter_seconds` to a
/// target buffer `clamp(k·jitter + base, [floor, ceil])` and steps `prev_playout_ms` toward it —
/// grow-fast, shrink-slow (at most `shrink_step_ms` down per call) to avoid a latency ratchet. The
/// caller holds `prev_playout_ms` between calls and resolves the env knobs, so the core stays
/// deterministic. Wraps [`adaptive_playout::step_seconds`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_adaptive_playout_step_ms(
    jitter_seconds: f64,
    prev_playout_ms: f64,
    shrink_step_ms: f64,
    k: f64,
    base_ms: f64,
    floor_ms: f64,
    ceil_ms: f64,
) -> f64 {
    let config = adaptive_playout::Config::from_ms(k, base_ms, floor_ms, ceil_ms);
    let next = adaptive_playout::step_seconds(
        jitter_seconds,
        prev_playout_ms / 1000.0,
        shrink_step_ms / 1000.0,
        &config,
    );
    next * 1000.0
}

/// The absolute minimum live bitrate (bits/sec) — a tiny window never starves the encoder.
/// Wraps [`live_bitrate_policy::MINIMUM_BITRATE`].
#[must_use]
#[unsafe(no_mangle)]
pub const extern "C" fn aisd_live_bitrate_minimum() -> i64 {
    live_bitrate_policy::MINIMUM_BITRATE
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use aislopdesk_core::live_bitrate_policy;

    const BPP: f64 = live_bitrate_policy::DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn adaptive_playout_step_matches_core() {
        // Defaults k=0.8 base=4 floor=4 ceil=35 (ms). Cold start at floor, 12ms jitter → 13.6ms (grow).
        let grown = aisd_adaptive_playout_step_ms(0.012, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((grown - 13.6).abs() < 1e-9);
        // Clean link (2ms) from a high prev → shrink by at most the 2ms step, not straight down.
        let shrunk = aisd_adaptive_playout_step_ms(0.002, 28.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((shrunk - 26.0).abs() < 1e-9);
        // Pathological 40ms jitter clamps at the 35ms ceiling.
        let capped = aisd_adaptive_playout_step_ms(0.040, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((capped - 35.0).abs() < 1e-9);
    }

    #[test]
    fn live_bitrate_target_matches_core() {
        assert_eq!(
            aisd_live_bitrate_target(1920, 1080, 60, 12_000_000, BPP),
            18_662_400
        );
        assert_eq!(
            aisd_live_bitrate_target(2816, 1778, 60, 12_000_000, BPP),
            45_061_632
        );
        assert_eq!(
            aisd_live_bitrate_target(320, 240, 60, 12_000_000, BPP),
            12_000_000
        );
        assert_eq!(
            aisd_live_bitrate_target(64, 64, 60, 0, BPP),
            aisd_live_bitrate_minimum()
        );
        assert_eq!(
            aisd_live_bitrate_target(0, -10, 0, 0, BPP),
            aisd_live_bitrate_minimum()
        );
    }

    #[test]
    fn live_bitrate_minimum_is_one_megabit() {
        assert_eq!(aisd_live_bitrate_minimum(), 1_000_000);
    }
}
