import CAislopdeskFFI

/// PRE-EMPTIVE drop-until-anchor decode admission (decode-fail cascade fix, 2026-06-12).
///
/// WHY: a delta that (transitively) references an unrecoverably-lost frame cannot decode — VT
/// throws -12909 (HW-measured, 9/9 in the self-heal probe). The client used to learn that the
/// hard way, PER FRAME: every post-loss delta was submitted, failed, tore down the
/// `VTDecompressionSession` (`invalidateSession`), and fired its own `requestIDR` — measured live
/// (139s parity session): 9 wire losses amplified into 23 decode-fails + 63 IDR re-requests. The
/// session teardown is the expensive part: it wipes the decoder's reference state (killing the
/// LTR recovery path's anchor) and forces a full reconfigure on the next keyframe.
///
/// THE GATE: once the reference chain is known-broken (`noteLoss`), deltas stop reaching VT at
/// all. Only ANCHOR CANDIDATES are submitted:
///  - a KEYFRAME (references nothing), or
///  - an ACKED-ANCHORED frame (wire bit 7 — a `ForceLTRRefresh` product: the host's recovery /
///    self-heal cadence refresh, forced against an LTR this client ACKED, i.e. one it provably
///    decoded BEFORE the loss; still held in the un-torn-down session's DPB precisely because
///    the gate kept garbage out of VT), or
///  - a delta OLDER than the oldest loss of the episode (its references predate the break).
/// NOTE bit 6 (`isLTR`) is NOT an anchor: VT surfaces an ack token on virtually EVERY frame once
/// LTR is enabled (measured live 2026-06-12: 7865/7874 frames) — bit 6 means "ack me on decode",
/// not "decodable past a loss". The first gate deploy admitted bit 6 and ate exactly one VT
/// failure per loss episode through ordinary chain deltas.
///
/// TWO BROKEN MODES — the anchor set differs:
///  - ``Mode/brokenChain``: the decoder session is alive (references survive) → keyframe OR LTR.
///  - ``Mode/needKeyframe``: the session itself is gone (`invalidateSession` after a hard failure,
///    or no IDR has ever configured it) → ONLY a keyframe can re-anchor.
///
/// LIVENESS stays with the caller: the escalation episode is armed by the loss-detection path
/// before the first drop, and the session re-runs its `shouldEscalateToIDR` check on every gated
/// drop — so a lost recovery frame still escalates to a forced IDR at the 2·RTT / escalation-floor
/// cadence, now WITHOUT a per-frame request storm.
///
/// Wrap-aware (the reassembler's sequence-space discipline) — no clock, no transport — headlessly
/// unit-testable.
///
/// The decision ALGORITHM (the drop-until-anchor state machine) lives in the Rust core
/// (`aislopdesk_core::decode_gate`, the SINGLE SOURCE OF TRUTH shared with Android over the C ABI);
/// this class is a thin owner of the opaque core handle, reached via ``RustVideoClientFFI``. It is a
/// `final class` (not the former value struct) so it can own the handle and free it in `deinit`.
/// `@unchecked Sendable` is sound because the single owner (`AislopdeskVideoClientSession`) only
/// touches it on its actor (and the tests from one thread), so no two threads race the handle.
public final class DecodeGate: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        /// Chain intact — everything submits.
        case open
        /// ≥1 unrecoverable loss since the last anchor; the decoder session is still alive.
        case brokenChain
        /// The decoder session is invalid (hard failure / never configured) — keyframe only.
        case needKeyframe
    }

    public enum Verdict: Sendable, Equatable {
        case submit
        case drop
    }

    private let handle: OpaquePointer

    /// The current admission mode, read from the Rust core.
    public var mode: Mode {
        switch RustVideoClientFFI.decodeGateMode(handle) {
        case AISD_DECODE_GATE_MODE_BROKEN_CHAIN: .brokenChain
        case AISD_DECODE_GATE_MODE_NEED_KEYFRAME: .needKeyframe
        default: .open
        }
    }

    /// OLDEST lost frameID of the episode — the chain is intact strictly BEFORE this id, so an
    /// older in-flight delta may still submit (its references predate the break).
    public var minLostFrameID: UInt32? { RustVideoClientFFI.decodeGateMinLostFrameID(handle) }
    /// NEWEST lost frameID of the episode — an anchor must decode strictly PAST this id to prove
    /// the chain re-anchored (same keep-newest discipline as `LTREscalationTracker.maxLostFrameID`).
    public var maxLostFrameID: UInt32? { RustVideoClientFFI.decodeGateMaxLostFrameID(handle) }

    public init() {
        handle = RustVideoClientFFI.decodeGateNew()
    }

    deinit {
        RustVideoClientFFI.decodeGateFree(handle)
    }

    /// One unrecoverably-lost frame (the reassembler's `.dropped` / drain path). Opens the episode;
    /// `needKeyframe` is strictly stronger and is never downgraded by a mere loss. Delegates to the
    /// Rust core.
    public func noteLoss(frameID: UInt32) {
        RustVideoClientFFI.decodeGateNoteLoss(handle, frameID: frameID)
    }

    /// A hard decode failure tore the session down (`invalidateSession`) — only an IDR helps now.
    /// Delegates to the Rust core.
    public func noteHardDecodeFailure() {
        RustVideoClientFFI.decodeGateNoteHardDecodeFailure(handle)
    }

    /// The decoder reported `awaitingKeyframe` (no session/parameter sets yet) — same anchor set.
    /// Delegates to the Rust core.
    public func noteAwaitingKeyframe() {
        RustVideoClientFFI.decodeGateNoteAwaitingKeyframe(handle)
    }

    /// Admission decision for one reassembled frame. Pure — never mutates; the caller acts.
    /// Delegates to the Rust core.
    public func verdict(frameID: UInt32, keyframe: Bool, ackedAnchored: Bool) -> Verdict {
        switch RustVideoClientFFI.decodeGateVerdict(
            handle, frameID: frameID, keyframe: keyframe, ackedAnchored: ackedAnchored,
        ) {
        case AISD_DECODE_GATE_VERDICT_DROP: .drop
        default: .submit
        }
    }

    /// Folds one SUCCESSFUL decode. A keyframe re-opens the gate unless a loss NEWER than it is
    /// already on record (the chain past the keyframe is still broken — stay `brokenChain` so the
    /// next refresh/IDR can finish the job). A non-keyframe success newer than every loss is the
    /// healed LTR anchor (mirrors `LTREscalationTracker.frameDecoded`). Delegates to the Rust core.
    public func noteDecodeSucceeded(frameID: UInt32, keyframe: Bool) {
        RustVideoClientFFI.decodeGateNoteDecodeSucceeded(handle, frameID: frameID, keyframe: keyframe)
    }
}
