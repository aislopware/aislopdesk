import Foundation

/// A frame that has been fully reassembled and is ready to feed the decoder.
public struct ReassembledFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var keyframe: Bool
    public var crisp: Bool
    /// The AVCC byte buffer (length-prefixed NAL units) — exactly the bytes the
    /// host packetized, restored either directly or via FEC recovery.
    public var avcc: Data
    /// True when a data hole existed and FEC parity filled it to complete this frame (the
    /// `fecRecovered` telemetry numerator). False for a frame that arrived whole. Defaulted so
    /// existing constructors stay valid.
    public var recoveredViaFEC: Bool
    /// WF-8: this is a Long-Term-Reference frame (the fragments carried
    /// ``FrameFragmentHeader/Flags/isLTR``, bit 6). On a SUCCESSFUL decode the client replies
    /// `RecoveryMessage.ack(frameID)` so the host learns the client holds this LTR (the ACKED-ONLY
    /// recovery invariant). Defaulted false for source-compat; false on every pre-WF-8 / LTR-off frame.
    public var isLTR: Bool
    /// Bit 7 — this frame was encoded via `ForceLTRRefresh` (references ONLY client-acked LTRs),
    /// the decode gate's non-keyframe re-anchor admission (see FrameFragmentHeader.Flags.ackedAnchored).
    public var ackedAnchored: Bool

    public init(
        frameID: UInt32,
        keyframe: Bool,
        crisp: Bool,
        avcc: Data,
        recoveredViaFEC: Bool = false,
        isLTR: Bool = false,
        ackedAnchored: Bool = false,
    ) {
        self.frameID = frameID
        self.keyframe = keyframe
        self.crisp = crisp
        self.avcc = avcc
        self.recoveredViaFEC = recoveredViaFEC
        self.isLTR = isLTR
        self.ackedAnchored = ackedAnchored
    }
}

/// The outcome of feeding one datagram to the reassembler.
public enum ReassemblyResult: Equatable, Sendable {
    /// More fragments are still needed for this frame; nothing to emit yet.
    case incomplete
    /// The frame is complete and reassembled (possibly via FEC recovery).
    case completed(ReassembledFrame)
    /// The frame was abandoned: a fragment is missing and FEC could not recover it,
    /// so the caller must drop the frame and signal recovery (LTR RFI, then IDR
    /// fallback). `frameID` is the lost frame.
    case dropped(frameID: UInt32)
    /// The datagram belonged to a frame already completed or dropped — ignored.
    case stale
}

/// Reassembles fragmented frames by `frameID`, detects loss, and applies FEC.
///
/// Loss model (doc 17 §3.6): the stream is plain UDP, so fragments may be lost or
/// reordered. A frame is only declared lost (`.dropped`) once we know we cannot
/// complete it — i.e. a NEWER frame's fragments arrive while this one is still
/// missing data that FEC cannot fill. That edge is what triggers request-recovery.
///
/// The reassembly ALGORITHM (fragment buffering, the data/parity boundary inversion, FEC recovery,
/// and the hopeless-frame loss sweep) lives in the Rust core
/// (`aislopdesk_core::reassembler::FrameReassembler`, the SINGLE SOURCE OF TRUTH shared with the
/// Android client over the `aisd_reassembler_*` C ABI). This class is a thin owner of the opaque
/// core handle, reached via ``RustVideoFFI``. With `m == 1` (the production wire) it is
/// byte-identical to the legacy native Swift reassembler the golden vectors anchored; the native
/// buffering / inversion / FEC-apply / sweep is DELETED.
///
/// It is a `final class` (not the former value struct) so it can OWN the handle and free it in
/// `deinit`. Not `Sendable` by design: it owns mutable per-frame state and lives inside the single
/// client receive loop (one reassembler per video stream).
public final class FrameReassembler {
    /// The owned Rust reassembler handle (`AisdReassembler *`). Freed in `deinit`.
    private let handle: OpaquePointer

    /// Upper bound on a frame's declared fragment count (R7 #6 hostile-input). Kept for source
    /// compatibility with callers/tests that referenced it; the live guard is now ENFORCED IN THE
    /// CORE (`FrameReassembler::MAX_FRAGMENTS_PER_FRAME`), which rejects an implausible `fragCount`
    /// before any per-frame buffer is allocated and surfaces it as `.stale` — identical behavior.
    static let maxFragmentsPerFrame = 8192

    /// Builds a reassembler matching the host's FEC. `fec` supplies the per-group data count (`k =
    /// fec.groupSize`) and parity multiplicity (`m = fec.parityCount`); the Rust core builds and
    /// OWNS its own `[k + m, k]` NEON-backed codec from those, so there is no second FEC handle and
    /// no double-FEC. A `nil` `fec` (or an `m == 0` scheme) builds a no-FEC reassembler.
    ///
    /// `fecReorderGrace` is how many frameIDs past the loss frontier a frame stays eligible for FEC
    /// when the ONLY thing missing is parity that could still fill its data holes (the packetizer
    /// emits parity LAST, so on a reordering UDP network frame N's parity commonly arrives just
    /// after frame N+1's data — doc 17 §3.6). Floored at 0 by the core.
    public init(fec: FECScheme? = nil, fecReorderGrace: Int = 2) {
        // A real `FECScheme` always has `groupSize >= 1` and `parityCount >= 1`, so `aisd_reassembler_new`
        // can only return null for an INVALID config — unreachable here. The fallback to a no-FEC
        // reassembler is a total, defensive path (it never wedges; a missing fragment just drops).
        let k = fec?.groupSize ?? 0
        let m = fec?.parityCount ?? 0
        if let h = RustVideoFFI.reassemblerNew(k: k, m: m, fecReorderGrace: fecReorderGrace) {
            handle = h
        } else if let h = RustVideoFFI.reassemblerNew(k: 0, m: 0, fecReorderGrace: fecReorderGrace) {
            handle = h
        } else {
            preconditionFailure("aisd_reassembler_new returned null for a no-FEC config (unreachable)")
        }
    }

    deinit { RustVideoFFI.reassemblerFree(handle) }

    /// Pops the next unrecoverably-lost frameID detected during prior ``ingest(_:)``
    /// calls, or `nil`. The client drains this after each ingest and, for each
    /// frameID, issues a recovery signal (LTR RFI → IDR fallback, doc 17 §3.6). Delegates to the
    /// Rust core's `next_dropped_frame`.
    public func nextDroppedFrame() -> UInt32? {
        RustVideoFFI.reassemblerNextDropped(handle)
    }

    /// Feeds one parsed fragment. Returns the outcome FOR THE INGESTED FRAGMENT'S
    /// frame. Drops of OLDER, now-hopeless frames are surfaced separately via
    /// ``nextDroppedFrame()`` (so completing a newer frame never hides an older loss).
    /// As a convenience, when the ingested fragment is `.incomplete` but its own
    /// frame became hopeless, `.dropped` is returned directly.
    ///
    /// The fragment is re-encoded to its exact wire datagram and handed to the Rust core, which
    /// parses + ingests it (the encode↔decode round-trip is byte-exact, so this is identical to
    /// passing the original datagram). Hostile / degenerate fragments are ignored by the core's
    /// guard exactly as before. Delegates to `aisd_reassembler_ingest`.
    @discardableResult
    public func ingest(_ fragment: FrameFragment) -> ReassemblyResult {
        RustVideoFFI.reassemblerIngest(handle, datagram: fragment.encode())
    }
}

public extension UInt32 {
    /// Signed wrap-aware distance `self - other` interpreted in a 32-bit sequence
    /// space (handles the `frameID`/`streamSeq` wrap at 2^32). Positive ⇒ `self` is
    /// "ahead of" `other`. Public so the host's ``VideoMuxRouter`` can bound its retired
    /// channelID set with the SAME wrap-aware high-water-mark prune (FIX #4).
    func distanceWrapped(from other: UInt32) -> Int {
        Int(Int32(bitPattern: self &- other))
    }
}
