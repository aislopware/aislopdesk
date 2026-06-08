#if os(macOS)
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import OSLog

/// Errors raised by the video encoder.
public enum VideoEncoderError: Error {
    case sessionCreateFailed(OSStatus)
    case notHardwareBacked
    case encodeFailed(OSStatus)
    /// A LATENCY-CRITICAL property failed to set. Carries the property key + the
    /// `OSStatus` so the caller can see exactly which proven low-latency setting did
    /// not apply (a silent failure here corrupts the measured doc-18 config).
    case propertyFailed(key: String, status: OSStatus)
}

/// The single-session HEVC encoder (doc 18 §E — **MEASURED + SOLVED**), built to the
/// EXACT configs validated in `docs/research/spikes/vtbench/encode-decode-bench.swift`.
///
/// ⚠️ **HANG-SAFETY:** `VTCompressionSessionCreate` + encode HW-accelerated HANG
/// without a window-server + Screen-Recording TCC session (RESULTS.md). This type is
/// COMPILED and code-reviewed but is NEVER instantiated in a test — only in a real
/// GUI host app.
///
/// - **Live session** = low-latency-RC (MEASURED p50 7.5ms vs constant-quality
///   24ms → live MUST be low-latency-RC). Specification keys
///   `EnableLowLatencyRateControl=true` + `RequireHardwareAcceleratedVideoEncoder=
///   true`; property keys `RealTime=true`, `ExpectedFrameRate=30`,
///   `PrioritizeEncodingSpeedOverQuality=true`, `AllowFrameReordering=false`,
///   `MaxKeyFrameInterval=INT_MAX`, `AverageBitRate` + `DataRateLimits=[12_000_000/8,
///   1.0]` (12 Mbps hard cap, **/8 not /4**), `SpatialAdaptiveQPLevel=Disable` (BEST-EFFORT —
///   `kVTPropertyNotSupportedErr`/-12900 on encoders without the key; not latency-critical).
///   ProfileLevel OMITTED. HEVC Main 8-bit 4:2:0.
/// - **Crisp static refresh** (Design A, 2026-06-08) = NOT a second session. When the window
///   goes static the heartbeat timer re-encodes the cached frame on this SAME live session with a
///   momentarily-dropped QP ceiling + widened rate cap (``encodeLiveCrispKeyframe``), then restores
///   the live config — near-lossless text with NO parameter-set change (no client decoder rebuild)
///   and the crisp IDR seeds the next live delta. (Replaced the old dead all-intra "Session B",
///   which double-occupied the HW encoder block and forced a cross-session reference break.)
///
/// Quirks honoured (RESULTS.md / doc 18 §E,§G):
/// - Do NOT query `UsingHardwareAcceleratedVideoEncoder` while low-latency is on
///   (returns -12900). HW support is gated at creation by
///   `RequireHardwareAcceleratedVideoEncoder=true` instead.
/// - Recreate the session on resize.
/// - Retry create on -12905 (XPC race) with 50-100ms backoff.
public final class VideoEncoder: @unchecked Sendable {
    /// 12 Mbps hard bitrate cap (doc 18 §E). DataRateLimits is `[maxBytes, seconds]`
    /// → `[12_000_000 / 8, 1.0]` = 1.5 MB per 1 s. **/8 (bits→bytes), not /4.**
    public static let bitrateBitsPerSecond = 12_000_000
    public static let dataRateMaxBytes = bitrateBitsPerSecond / 8 // 1_500_000
    /// -12905 (XPC) create-race retry backoff, 50-100ms (doc 18 §G).
    public static let createRetryBackoffNanos: UInt64 = 75_000_000
    /// §A1 (doc 26 §A) worst-case quantizer CEILING for the live session. HEVC QP range is
    /// 1 (lossless) … 51 (coarsest). VideoToolbox RAISES QP up to this ceiling to keep a frame under
    /// the hard `DataRateLimits` cap, and DROPS the frame if even at this ceiling it cannot fit — so
    /// this ceiling is the dial between "coarsen" and "drop" under bitrate pressure.
    ///
    /// 2026-06-08 (scroll-smoothness): raised 32 → 40. A dropped frame IS visible stutter, and with
    /// the 2× HiDPI display (feature #1) a heavy scroll frame routinely could not fit at QP 32 → it
    /// was dropped → the user's "scroll/content-change not smooth" report. 40 lets such a frame
    /// coarsen-and-ship instead of dropping; the CRISP static refresh (``encodeLiveCrispKeyframe``)
    /// restores razor-sharp text the instant motion stops, so trading a hair of MOTION sharpness for
    /// never dropping a motion frame is pure win for smoothness. Pure upside vs 32: only frames that
    /// WOULD have been dropped are affected — a frame that already fit at ≤32 is byte-identical.
    /// Paired with the now resolution-aware bitrate (``LiveBitratePolicy``) the ceiling rarely even
    /// binds. A/B without a rebuild via `RWORK_MAX_QP`. Best-effort: -12900/unsupported → tolerated.
    /// NOTE (2026-06-08): the "hover blurs the pane" bug was NOT this — HW A/B showed keyframes
    /// stayed a constant ~52 KB at both 12 and 40 Mbps and a 32→22 ceiling drop did not fix it;
    /// the real cause was SCK bounding-rect expansion from Chrome's tooltip child window (see
    /// WindowCapturer.makeConfiguration `includeChildWindows = false`).
    public static let maxAllowedFrameQP: Int = {
        if let s = ProcessInfo.processInfo.environment["RWORK_MAX_QP"], let v = Int(s), v >= 1, v <= 51 { return v }
        return 40
    }()

    /// CRISP STATIC REFRESH (doc 17 §3.4 — Design A, single-session QP-bump, 2026-06-08).
    /// When the window goes static the heartbeat timer re-encodes the cached frame as a
    /// near-lossless intra refresh ON THE LIVE SESSION (not a second session): we momentarily
    /// drop the QP ceiling + widen the rate cap for exactly that one forced IDR, then restore the
    /// proven low-latency config. Because it is the SAME session the VPS/SPS/PPS are unchanged, so
    /// the client does NOT rebuild its decoder (no stall), and the crisp IDR becomes the reference
    /// for the next live delta — so motion resumes seamlessly with no cross-session reference gap.
    /// HEVC QP 1(lossless)…51(coarsest); ~18 is visually transparent for text while far smaller
    /// than QP 14. Override for A/B via `RWORK_CRISP_QP` (no rebuild). Best-effort: if the encoder
    /// rejects a mid-session `MaxAllowedFrameQP` change (-12900) the refresh degrades to a normal
    /// keyframe (observable — the `crisp=…` host log shows it stayed ~live-keyframe-sized).
    public static let crispMaxQP: Int = {
        if let s = ProcessInfo.processInfo.environment["RWORK_CRISP_QP"], let v = Int(s), v >= 1, v <= 51 { return v }
        return 18
    }()
    /// Widened `DataRateLimits` byte budget for the one-second window around a crisp IDR (64 Mbit),
    /// so the hard rate cap does not DROP the (much larger) near-lossless intra frame. The live cap
    /// (`dataRateMaxBytes`, 1.5 MB) is restored immediately after. Generous enough for a 2× HiDPI
    /// intra frame (feature #1) without ever clamping it.
    public static let crispDataRateMaxBytes = 8_000_000

    // MARK: Compact recovery/heartbeat IDR (motion-smoothness, 2026-06-08)
    //
    // At 2× HiDPI (feature #1) a full intra frame is ~100 KB. A RECOVERY IDR (client requested it
    // after losing fragments) sent as one ~100 KB UDP burst routinely loses fragments of ITSELF →
    // the client still can't decode → it re-requests → another ~100 KB IDR. F1's cooldown caps that
    // loop at one-per-500 ms, so on a lossy link the IDRs fire in PAIRS 0.5 s apart — each a wire
    // burst that delays the next delta frame = a periodic motion HITCH ("giật"). A recovery/heartbeat
    // IDR does NOT need to be pretty (motion masks coarseness; the static-timer CRISP refresh restores
    // razor-sharp text the instant the screen goes quiet) — it needs to SURVIVE. So it is bracketed
    // the OPPOSITE way to crisp: QP ceiling RAISED + rate-control target LOWERED, shrinking the IDR to
    // ~30–50 KB ⇒ ~⅓ the fragments ⇒ it fits inside the single-loss XOR FEC's burst-recovery budget ⇒
    // the loop breaks. Both knobs A/B-tunable without a rebuild. Best-effort sets (`set`): an encoder
    // that rejects the mid-session change ships a normal-size IDR (observable — the keyframe byte size
    // in the host log stays ~100 KB instead of dropping to ~40 KB).
    //
    /// QP ceiling for a compact IDR — coarser than the live ceiling (`maxAllowedFrameQP`) so the
    /// encoder can shrink the forced IDR by coarsening instead of dropping it. A/B via `RWORK_COMPACT_QP`.
    public static let compactMaxQP: Int = {
        if let s = ProcessInfo.processInfo.environment["RWORK_COMPACT_QP"], let v = Int(s), v >= 1, v <= 51 { return v }
        return 46
    }()
    /// Rate-control target (bits/sec) applied for EXACTLY the compact IDR — far below the live
    /// `bitrate` so the controller budgets the forced IDR small; restored to `bitrate` immediately
    /// after. A/B via `RWORK_COMPACT_KBPS` (kbit/s; 500…100000).
    public static let compactBitrate: Int = {
        if let s = ProcessInfo.processInfo.environment["RWORK_COMPACT_KBPS"], let v = Int(s), v >= 500, v <= 100_000 { return v * 1000 }
        return 8_000_000
    }()

    /// Which session produced an output (carried to the packetizer's crisp flag).
    /// `.crisp` now means "a QP-bumped near-lossless keyframe from the LIVE session" (Design A) —
    /// purely informational on the wire (the client treats every keyframe identically). Kept so the
    /// `crisp=…` host log marks the refresh frames and their byte size verifies the QP-bump took.
    public enum Mode: Sendable { case live, crisp }

    /// Emitted for each finished encode: the AVCC bytes, keyframe flag, and which
    /// session produced it.
    public typealias OutputHandler = @Sendable (_ avcc: Data, _ keyframe: Bool, _ mode: Mode) -> Void

    private let log = Logger(subsystem: "rwork.video.host", category: "VideoEncoder")
    private let width: Int32
    private let height: Int32
    private let outputHandler: OutputHandler
    /// Live-session target bitrate (bits/sec). The 12 Mbps spike default is great for video,
    /// but SHARP TEXT (screen sharing) needs more bits or HEVC softens glyph edges — so the
    /// host can raise it (e.g. ~40 Mbps over LAN/NetBird) for crisp text.
    private let bitrate: Int
    /// Live-session `ExpectedFrameRate` hint (fps). Default 60 to match the 60fps capture cap; the
    /// encoder uses it to size its rate-control window. Best-effort (a hint, not latency-critical).
    private let fps: Int

    private var liveSession: VTCompressionSession?

    public init(width: Int, height: Int, bitrate: Int = bitrateBitsPerSecond, fps: Int = 60, outputHandler: @escaping OutputHandler) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = max(1_000_000, bitrate)
        self.fps = max(1, fps)
        self.outputHandler = outputHandler
    }

    deinit {
        if let liveSession { VTCompressionSessionInvalidate(liveSession) }
    }

    // MARK: Session A — live (low-latency-RC)

    /// Creates Session A exactly per the validated spike config. Throws
    /// ``VideoEncoderError/notHardwareBacked`` if HW is unavailable (gated at
    /// creation, not by querying UsingHW while low-latency is on — that returns
    /// -12900). Retries -12905 once with backoff (doc 18 §G).
    public func createLiveSession() throws {
        // Specification keys go in the CREATE dict, not via SetProperty (doc 17 §3.2).
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if status == -12905 { // XPC create race — retry once after backoff (doc 18 §G).
            log.notice("live session create -12905, retrying after backoff")
            usleep(useconds_t(Self.createRetryBackoffNanos / 1000))
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height,
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { throw VideoEncoderError.sessionCreateFailed(status) }

        // Property keys (via VTSessionSetProperty). EXACT spike config. The
        // LATENCY-CRITICAL keys THROW on failure — a silent failure here corrupts the
        // proven low-latency config (doc 18 §E). Best-effort keys are set leniently
        // (logged on failure) since they degrade quality, not the latency contract.
        try setCritical(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber) // best-effort (60 default)
        set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue) // best-effort
        try setCritical(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames — latency-critical
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Int32.max) as CFNumber) // IDR on-demand (best-effort)
        // AverageBitRate + DataRateLimits together ARE the low-latency rate-control
        // contract — both latency-critical.
        try setCritical(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // DataRateLimits = [maxBytes, seconds]; hard cap at the configured bitrate (/8 not /4).
        try setCritical(session, kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1.0] as CFArray)
        // SpatialAdaptiveQPLevel=Disable is a QP-modulation HINT. The spike host advertised it,
        // but it is kVTPropertyNotSupportedErr (-12900) on HEVC encoders that don't implement
        // the key — and low-latency rate control is ALREADY established by
        // EnableLowLatencyRateControl (spec) + AverageBitRate/DataRateLimits. So set it
        // BEST-EFFORT: apply it where supported, tolerate -12900 elsewhere. (Forcing it as
        // critical aborted the WHOLE encoder on such hardware, leaving PATH 2 unable to produce
        // a single frame — observed via check-video.sh's host diagnostics, 2026-06-02.)
        set(session, kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, kVTQPModulationLevel_Disable as CFNumber)
        // §A1 part 2 (doc 26 §A): cap the worst-case quantizer so text never smears under a
        // bitrate-starved frame. With low-latency RC + a 12 Mbps DataRateLimits hard cap, a busy
        // frame can otherwise blow its budget and the encoder coarsens QP → blurry glyph edges.
        // MaxAllowedFrameQP tells the encoder to DROP a frame (or spend an extra IDR) rather than
        // ship a frame above this QP — on a 24–30fps desktop a held-but-sharp frame beats a
        // delivered-but-blurry one. QP ~32 (1=lossless..51=worst) keeps text crisp while leaving
        // motion headroom; tune on hardware.
        // BEST-EFFORT (NOT setCritical): kVTCompressionPropertyKey_MaxAllowedFrameQP is
        // kVTPropertyNotSupportedErr/-12900 on some HEVC encoders — same -12900-prone family as
        // SpatialAdaptiveQPLevel above; forcing it critical would abort the whole encoder on such
        // hardware (the exact regression class the 2026-06-02 fix #1 guards against). The key
        // exists on macOS 26; on older OSes it is simply tolerated as a no-op.
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
        // ProfileLevel OMITTED for the low-latency session (doc 18 §E).
        // NOTE: do NOT query UsingHardwareAcceleratedVideoEncoder here — it returns
        // -12900 with low-latency on; HW is already gated by Require...=true above.

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.liveSession = session
    }

    // MARK: Crisp static refresh (Design A — single-session QP-bump, doc 17 §3.4)

    /// Emits a near-lossless intra refresh ON THE LIVE SESSION without a parameter-set change.
    /// Called by ``WindowCapturer``'s static-IDR timer (frameQueue-serial, and ONLY while the live
    /// path is quiet — so no live frame is encoding concurrently). Mechanism:
    ///   1. `CompleteFrames` drains any in-flight frame so the QP swap doesn't affect a still-live-QP encode.
    ///   2. Drop the QP ceiling (`crispMaxQP`) + widen the rate cap (`crispDataRateMaxBytes`) so the
    ///      forced IDR is near-lossless and not dropped by the hard cap.
    ///   3. Encode the cached frame as a forced keyframe (tagged `.crisp` for the host log).
    ///   4. `CompleteFrames` AGAIN — the VT output callback is async, so this guarantees the crisp
    ///      frame is fully encoded UNDER the relaxed config BEFORE we restore (restoring first would
    ///      let it encode at the live ceiling → soft). This second drain is the gap-closer.
    ///   5. `defer` restores the proven low-latency rate-control config (QP 32 + 1.5 MB cap).
    /// Same VPS/SPS/PPS ⇒ the client does NOT rebuild its decoder; the crisp IDR becomes the
    /// reference for the next live delta ⇒ motion resumes seamlessly. The QP/cap sets are
    /// best-effort: an encoder that rejects a mid-session `MaxAllowedFrameQP` change (-12900) simply
    /// ships a normal keyframe (visible: the `crisp=…` log byte size stays ~live-keyframe-sized).
    public func encodeLiveCrispKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        // 1. Drain prior in-flight frames so they finish under the LIVE config (not the relaxed one).
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        // 2. Relax: drop the QP ceiling + widen the hard rate cap for exactly this one IDR.
        set(session, kVTCompressionPropertyKey_DataRateLimits, [Self.crispDataRateMaxBytes, 1.0] as CFArray)
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.crispMaxQP as CFNumber)
        // 5. Restore the proven live low-latency config no matter how we exit. CRITICAL: restore the
        //    SESSION's cap (`bitrate / 8`, matching the create-site), NOT the static 12 Mbps default —
        //    otherwise the first static refresh on a `--bitrate >12` session would permanently clamp
        //    the live stream to 1.5 MB (~⅓ of e.g. a 40 Mbps config) and never recover.
        defer {
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
            set(session, kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8, 1.0] as CFArray)
        }
        // 3. Encode the forced crisp keyframe.
        try encode(session: session, pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: true, mode: .crisp)
        // 4. Ensure it is fully emitted under the relaxed config before `defer` restores.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Emits a COMPACT forced IDR on the live session for loss-recovery / active-path heartbeat — the
    /// INVERSE of ``encodeLiveCrispKeyframe`` (see the "Compact recovery/heartbeat IDR" note above for
    /// why). Same bracket discipline so it cannot bleed into the live deltas:
    ///   1. `CompleteFrames` drains in-flight frames so they finish under the LIVE config.
    ///   2. RAISE the QP ceiling (`compactMaxQP`) + LOWER the rate-control target (`compactBitrate`)
    ///      so the forced IDR is small enough to survive a UDP burst.
    ///   3. Encode the forced keyframe (tagged `.live` — it is a normal keyframe on the wire, just
    ///      smaller; the host-log byte size is the verification that the bracket took).
    ///   4. `CompleteFrames` AGAIN so the IDR is fully emitted under the relaxed config BEFORE restore.
    ///   5. `defer` restores the proven live config (QP ceiling + `bitrate`). Same VPS/SPS/PPS ⇒ no
    ///      client decoder rebuild. Best-effort sets: a rejected change just ships a normal-size IDR.
    public func encodeCompactKeyframe(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        set(session, kVTCompressionPropertyKey_AverageBitRate, Self.compactBitrate as CFNumber)
        set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.compactMaxQP as CFNumber)
        defer {
            set(session, kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.maxAllowedFrameQP as CFNumber)
            set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        }
        try encode(session: session, pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: true, mode: .live)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    // MARK: Encode

    /// Encodes a live frame on Session A. `forceKeyframe` sets the IDR frame property
    /// (heartbeat / loss recovery). The pixel buffer is the NV12 `CVPixelBuffer`
    /// handed straight from `WindowCapturer` (zero-copy).
    public func encodeLive(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) throws {
        guard let session = liveSession else { throw VideoEncoderError.sessionCreateFailed(-12903) }
        try encode(session: session, pixelBuffer: pixelBuffer, presentationTime: presentationTime, forceKeyframe: forceKeyframe, mode: .live)
    }

    private func encode(session: VTCompressionSession, pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool, mode: Mode) throws {
        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let handler = outputHandler
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            Self.deliver(sampleBuffer: sampleBuffer, mode: mode, handler: handler)
        }
        guard status == noErr else { throw VideoEncoderError.encodeFailed(status) }
    }

    /// Extracts the AVCC bytes + keyframe flag from a finished `CMSampleBuffer` and
    /// forwards them. The block buffer holds length-prefixed NAL units (the client
    /// re-prefixes when it reassembles fragments — see RworkVideoProtocol.NALUnit).
    private static func deliver(sampleBuffer: CMSampleBuffer, mode: Mode, handler: OutputHandler) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }
        var avcc = Data(bytes: dataPointer, count: totalLength)

        // Keyframe? Absence of the not-sync attachment ⇒ keyframe.
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        // CRITICAL: VTCompressionSession keeps the HEVC VPS/SPS/PPS parameter sets in the sample
        // buffer's FORMAT DESCRIPTION, NOT inline in the CMBlockBuffer — so the bytes above are
        // the coded slice ONLY. The client builds its CMVideoFormatDescription from parameter
        // sets it expects to find INLINE ahead of the IDR slice (HEVCParameterSets.extract); with
        // none present it can never decode (`awaitingKeyframe`) and the window stays blank. So on
        // a keyframe we prepend the VPS/SPS/PPS (length-prefixed, same 4-byte AVCC framing) pulled
        // from the format description. (Found via check-video.sh's client decode diagnostics,
        // 2026-06-02 — the prior "host emits parameter sets inline" assumption was wrong.)
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let params = hevcParameterSetsAVCC(from: fmt) {
            avcc = params + avcc
        }
        handler(avcc, keyframe, mode)
    }

    /// Extracts the HEVC VPS/SPS/PPS parameter sets from a `CMVideoFormatDescription` and returns
    /// them as length-prefixed (4-byte big-endian) AVCC NAL units, in index order — ready to
    /// prepend to a keyframe's coded slice so the client can build its decode format description.
    /// Returns `nil` if the description carries no parameter sets.
    private static func hevcParameterSetsAVCC(from formatDescription: CMFormatDescription) -> Data? {
        var count = 0
        let probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr, count > 0 else { return nil }

        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { return nil }
            var lengthBE = UInt32(size).bigEndian
            withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }   // 4-byte AVCC length
            out.append(UnsafeBufferPointer(start: pointer, count: size))
        }
        return out
    }

    /// Re-creates both sessions on a window resize (doc 18 §G — recreate on resize).
    /// The caller passes the new dimensions by constructing a fresh `VideoEncoder`.

    /// Drains BOTH compression sessions, blocking until every in-flight frame's output
    /// callback has fired (`VTCompressionSessionCompleteFrames` with an INVALID timestamp = the
    /// documented "complete ALL pending frames" sentinel). Call this before dropping the OLD
    /// encoder on a resize swap: without it the encoder is invalidated (by `deinit`) while frames
    /// are still queued, silently dropping their already-encoded output (FFmpeg videotoolboxenc
    /// CompleteFrames-before-invalidate pattern). Purely ADDITIVE — does NOT touch the hot
    /// `encodeLive` path. Safe to call once; the sessions are not reused afterward.
    public func completeFrames() {
        if let liveSession { VTCompressionSessionCompleteFrames(liveSession, untilPresentationTimeStamp: .invalid) }
    }

    /// Sets a LATENCY-CRITICAL property and THROWS ``VideoEncoderError/propertyFailed(key:status:)``
    /// if it does not apply. Used for the proven low-latency rate-control keys
    /// (RealTime, AllowFrameReordering, AverageBitRate, DataRateLimits) where a silent
    /// failure corrupts the measured config (doc 18 §E). The encoder must NOT proceed with a
    /// half-applied low-latency config. (SpatialAdaptiveQPLevel is deliberately NOT here — it
    /// is best-effort; some HEVC encoders return -12900 for it and aborting would yield zero
    /// frames.)
    private func setCritical(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            log.error("critical VTSessionSetProperty \(key as String) failed: \(status)")
            throw VideoEncoderError.propertyFailed(key: key as String, status: status)
        }
    }

    /// Sets a best-effort property: a failure degrades quality, not the latency
    /// contract, so it is logged and tolerated (e.g. ExpectedFrameRate). Returns the
    /// status for callers that care.
    @discardableResult
    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> OSStatus {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            log.error("VTSessionSetProperty \(key as String) failed (best-effort, tolerated): \(status)")
        }
        return status
    }
}
#endif
