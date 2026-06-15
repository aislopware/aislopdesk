import CAislopdeskFFI
import Foundation

/// Swift-side bridge from `AislopdeskVideoClient` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the client module is contained here; the client's controllers
/// (e.g. ``DecodeGate``) call these typed wrappers so their public Swift APIs stay unchanged. The
/// decision ALGORITHMS live in the Rust core (`aislopdesk-core`, the SINGLE SOURCE OF TRUTH shared
/// with Android over the same C ABI); these wrappers are a thin 1:1 mapping onto the `extern "C"`
/// surface, mirroring `RustVideoHostFFI` on the host side. The client module already links
/// `libaislopdesk_ffi.a` transitively through `AislopdeskVideoProtocol`; this just imports the
/// module so the controllers can own the opaque core handles directly.
enum RustVideoClientFFI {
    // MARK: - decode_gate (opaque handle; pre-emptive drop-until-anchor decode admission)

    /// Creates a fresh, open decode gate owned by the Rust core; release with `decodeGateFree`.
    /// Wraps `aisd_decode_gate_new` (never returns null).
    static func decodeGateNew() -> OpaquePointer {
        aisd_decode_gate_new()
    }

    /// Destroys a gate handle. Wraps `aisd_decode_gate_free`.
    static func decodeGateFree(_ handle: OpaquePointer) {
        aisd_decode_gate_free(handle)
    }

    /// The current mode as the raw `AISD_DECODE_GATE_MODE_*` discriminant. Wraps
    /// `aisd_decode_gate_mode`.
    static func decodeGateMode(_ handle: OpaquePointer) -> UInt32 {
        aisd_decode_gate_mode(handle)
    }

    /// The OLDEST lost frame id of the episode, or `nil` when none. Wraps
    /// `aisd_decode_gate_min_lost_frame_id`.
    static func decodeGateMinLostFrameID(_ handle: OpaquePointer) -> UInt32? {
        var out: UInt32 = 0
        return aisd_decode_gate_min_lost_frame_id(handle, &out) != 0 ? out : nil
    }

    /// The NEWEST lost frame id of the episode, or `nil` when none. Wraps
    /// `aisd_decode_gate_max_lost_frame_id`.
    static func decodeGateMaxLostFrameID(_ handle: OpaquePointer) -> UInt32? {
        var out: UInt32 = 0
        return aisd_decode_gate_max_lost_frame_id(handle, &out) != 0 ? out : nil
    }

    /// Folds one unrecoverably-lost frame. Wraps `aisd_decode_gate_note_loss`.
    static func decodeGateNoteLoss(_ handle: OpaquePointer, frameID: UInt32) {
        aisd_decode_gate_note_loss(handle, frameID)
    }

    /// Records a hard decode failure (session torn down). Wraps
    /// `aisd_decode_gate_note_hard_decode_failure`.
    static func decodeGateNoteHardDecodeFailure(_ handle: OpaquePointer) {
        aisd_decode_gate_note_hard_decode_failure(handle)
    }

    /// Records that the decoder is awaiting a keyframe. Wraps
    /// `aisd_decode_gate_note_awaiting_keyframe`.
    static func decodeGateNoteAwaitingKeyframe(_ handle: OpaquePointer) {
        aisd_decode_gate_note_awaiting_keyframe(handle)
    }

    /// The admission decision as the raw `AISD_DECODE_GATE_VERDICT_*` discriminant. PURE (never
    /// mutates). Wraps `aisd_decode_gate_verdict`.
    static func decodeGateVerdict(
        _ handle: OpaquePointer,
        frameID: UInt32,
        keyframe: Bool,
        ackedAnchored: Bool,
    ) -> UInt32 {
        aisd_decode_gate_verdict(handle, frameID, keyframe ? 1 : 0, ackedAnchored ? 1 : 0)
    }

    /// Folds one successful decode. Wraps `aisd_decode_gate_note_decode_succeeded`.
    static func decodeGateNoteDecodeSucceeded(_ handle: OpaquePointer, frameID: UInt32, keyframe: Bool) {
        aisd_decode_gate_note_decode_succeeded(handle, frameID, keyframe ? 1 : 0)
    }

    // MARK: - owd_late_detector (opaque handle; per-frame one-way-delay spike detector)

    /// Creates an OWD spike detector from the resolved config scalars (env is resolved Swift-side;
    /// the core stays env-free). Release with `owdLateDetectorFree`. Wraps
    /// `aisd_owd_late_detector_new` (never returns null).
    static func owdLateDetectorNew(
        bucketMs: Double,
        thresholdFloorMs: Double,
        thresholdIntervalFraction: Double,
        warmupSamples: Int,
    ) -> OpaquePointer {
        aisd_owd_late_detector_new(bucketMs, thresholdFloorMs, thresholdIntervalFraction, warmupSamples)
    }

    /// Destroys a detector handle. Wraps `aisd_owd_late_detector_free`.
    static func owdLateDetectorFree(_ handle: OpaquePointer) {
        aisd_owd_late_detector_free(handle)
    }

    /// Folds one per-frame sample; returns the deviation above threshold (ms) when the sample is a
    /// network-late spike, else `nil`. Wraps `aisd_owd_late_detector_note`.
    static func owdLateDetectorNote(
        _ handle: OpaquePointer,
        arrivalMs: Double,
        sendTs: UInt32,
        intervalMs: Double,
    ) -> Double? {
        var out = 0.0
        return aisd_owd_late_detector_note(handle, arrivalMs, sendTs, intervalMs, &out) != 0 ? out : nil
    }

    // MARK: - pacer_depth_policy (opaque handle; adaptive pacer-depth v3)

    /// Flattens a Swift `PacerDepthPolicy.Config` into the C `AisdPacerDepthConfig` (by field name).
    private static func cPacerConfig(_ c: PacerDepthPolicy.Config) -> AisdPacerDepthConfig {
        AisdPacerDepthConfig(
            late_gap_factor: c.lateGapFactor,
            absolute_late_floor_seconds: c.absoluteLateFloorSeconds,
            idle_gap_seconds: c.idleGapSeconds,
            gap_gradient_factor: c.gapGradientFactor,
            dense_min_arrivals: c.denseMinArrivals,
            dense_window_seconds: c.denseWindowSeconds,
            late_slack_fraction: c.lateSlackFraction,
            promote_late_count: c.promoteLateCount,
            promote_window_seconds: c.promoteWindowSeconds,
            demote_clean_seconds: c.demoteCleanSeconds,
            min_hold_seconds: c.minHoldSeconds,
            demote_tolerance_lates: c.demoteToleranceLates,
            promote_warmup_seconds: c.promoteWarmupSeconds,
            boost_depth: Int64(c.boostDepth),
            interval_ring_size: c.intervalRingSize,
            min_samples_for_estimate: c.minSamplesForEstimate,
            default_interval_seconds: c.defaultIntervalSeconds,
            min_interval_seconds: c.minIntervalSeconds,
            max_interval_seconds: c.maxIntervalSeconds,
        )
    }

    /// Creates a pacer-depth policy owned by the Rust core from the resolved config + adapt flag
    /// (env resolved Swift-side). Release with `pacerDepthPolicyFree`. Wraps
    /// `aisd_pacer_depth_policy_new` (never returns null).
    static func pacerDepthPolicyNew(config: PacerDepthPolicy.Config, adaptEnabled: Bool) -> OpaquePointer {
        aisd_pacer_depth_policy_new(cPacerConfig(config), adaptEnabled ? 1 : 0)
    }

    /// Destroys a policy handle. Wraps `aisd_pacer_depth_policy_free`.
    static func pacerDepthPolicyFree(_ handle: OpaquePointer) {
        aisd_pacer_depth_policy_free(handle)
    }

    /// The recommended presentation depth. Wraps `aisd_pacer_depth_policy_depth`.
    static func pacerDepthPolicyDepth(_ handle: OpaquePointer) -> Int {
        Int(aisd_pacer_depth_policy_depth(handle))
    }

    /// The expected content interval (seconds). Wraps
    /// `aisd_pacer_depth_policy_expected_interval_seconds`.
    static func pacerDepthPolicyExpectedIntervalSeconds(_ handle: OpaquePointer) -> Double {
        aisd_pacer_depth_policy_expected_interval_seconds(handle)
    }

    /// The late boundary (seconds). Wraps `aisd_pacer_depth_policy_late_threshold_seconds`.
    static func pacerDepthPolicyLateThresholdSeconds(_ handle: OpaquePointer) -> Double {
        aisd_pacer_depth_policy_late_threshold_seconds(handle)
    }

    /// Folds one decoded-frame submit. Wraps `aisd_pacer_depth_policy_note_arrival`.
    static func pacerDepthPolicyNoteArrival(_ handle: OpaquePointer, now: Double) {
        aisd_pacer_depth_policy_note_arrival(handle, now)
    }

    /// Folds one content present and returns its gap class. Wraps
    /// `aisd_pacer_depth_policy_note_present`.
    static func pacerDepthPolicyNotePresent(_ handle: OpaquePointer, now: Double) -> PacerDepthPolicy.GapClass {
        switch aisd_pacer_depth_policy_note_present(handle, now) {
        case UInt8(AISD_PACER_GAP_NORMAL): .normal
        case UInt8(AISD_PACER_GAP_LATE): .late
        case UInt8(AISD_PACER_GAP_IDLE): .idle
        default: .first
        }
    }

    /// Folds one NETWORK-late event. Wraps `aisd_pacer_depth_policy_note_network_late`.
    static func pacerDepthPolicyNoteNetworkLate(_ handle: OpaquePointer, now: Double) {
        aisd_pacer_depth_policy_note_network_late(handle, now)
    }

    /// Folds one empty re-show. Wraps `aisd_pacer_depth_policy_note_reshow`.
    static func pacerDepthPolicyNoteReshow(_ handle: OpaquePointer, now: Double) {
        aisd_pacer_depth_policy_note_reshow(handle, now)
    }

    /// Drains (and resets) the windowed counters. Wraps `aisd_pacer_depth_policy_drain_counters`.
    static func pacerDepthPolicyDrainCounters(
        _ handle: OpaquePointer,
    ) -> (lateFrames: UInt32, presentGaps: UInt32) {
        let c = aisd_pacer_depth_policy_drain_counters(handle)
        return (c.late_frames, c.present_gaps)
    }

    /// Sets (or clears, when `seconds == nil`) the FPS-governor interval hint. Wraps
    /// `aisd_pacer_depth_policy_set_interval_hint`.
    static func pacerDepthPolicySetIntervalHint(_ handle: OpaquePointer, seconds: Double?) {
        aisd_pacer_depth_policy_set_interval_hint(handle, seconds ?? 0, seconds != nil ? 1 : 0)
    }
}
