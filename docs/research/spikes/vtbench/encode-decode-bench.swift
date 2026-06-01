import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

func nowMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000.0 }

func pct(_ xs: [Double], _ p: Double) -> Double {
    if xs.isEmpty { return 0 }
    let s = xs.sorted()
    let idx = min(s.count - 1, max(0, Int((p/100.0) * Double(s.count - 1).rounded())))
    return s[Int((p/100.0) * Double(s.count - 1))]
}

func makePixelBuffer(_ w: Int, _ h: Int, seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
    ]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let ptr = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(b)
    // text-like high-frequency pattern (worst case for encode) + per-frame change
    for y in 0..<h {
        for x in 0..<w {
            let o = y*bpr + x*4
            let on = ((x/2 + seed) % 7 == 0) || ((y/3) % 11 == 0)
            let v: UInt8 = on ? 235 : 16
            ptr[o] = v; ptr[o+1] = v; ptr[o+2] = v; ptr[o+3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

func hwGate() -> CFDictionary {
    return [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
}

func usingHW(_ s: VTCompressionSession) -> String {
    var v: CFTypeRef?
    let st = VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &v)
    if st != noErr { return "query-err(\(st))" }
    if let b = v as? Bool { return b ? "HW" : "SW" }
    return "?"
}

// ---------- TEST G: concurrent hardware HEVC encoders ----------
func testConcurrent(_ w: Int, _ h: Int, _ label: String) {
    var sessions: [VTCompressionSession] = []
    var n = 0
    while n < 48 {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: hwGate(),
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let sess = s else {
            print("  [\(label)] create FAILED at session #\(n+1): status=\(st)")
            break
        }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let pst = VTCompressionSessionPrepareToEncodeFrames(sess)
        // force HW allocation with one real encode
        let pb = makePixelBuffer(w, h, seed: n)
        var encOk = false
        let est = VTCompressionSessionEncodeFrame(sess, imageBuffer: pb,
            presentationTimeStamp: CMTime(value: Int64(n), timescale: 30), duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            if status == noErr, sb != nil { encOk = true }
        }
        VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid)
        let hw = usingHW(sess)
        if est != noErr || pst != noErr || hw != "HW" {
            print("  [\(label)] session #\(n+1): prepare=\(pst) encode=\(est) backing=\(hw) -> CEILING (not HW or failed)")
            VTCompressionSessionInvalidate(sess)
            break
        }
        sessions.append(sess)
        n += 1
    }
    print("  [\(label)] => \(n) concurrent HW HEVC sessions held simultaneously (all HW-backed)")
    for s in sessions { VTCompressionSessionInvalidate(s) }
}

// ---------- encode one stream, measure encode latency, return sample buffers ----------
func encodeStream(_ w: Int, _ h: Int, frames: Int, lowLatency: Bool) -> (encMs: [Double], buffers: [CMSampleBuffer], hw: String) {
    let spec: CFDictionary = {
        var d: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { d[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        return d as CFDictionary
    }()
    var s: VTCompressionSession?
    let cst = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
        codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard cst == noErr, let sess = s else {
        print("  encode session create failed: \(cst)"); return ([], [], "create-fail(\(cst))")
    }
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
    if lowLatency {
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
    } else {
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_Quality, value: 0.65 as CFNumber)
    }
    VTCompressionSessionPrepareToEncodeFrames(sess)
    let hw = usingHW(sess)
    var encMs: [Double] = []
    var buffers: [CMSampleBuffer] = []
    let group = DispatchSemaphore(value: 0)
    for i in 0..<frames {
        let pb = makePixelBuffer(w, h, seed: i)
        let t0 = nowMs()
        VTCompressionSessionEncodeFrame(sess, imageBuffer: pb,
            presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            if status == noErr, let sb = sb {
                encMs.append(nowMs() - t0)
                buffers.append(sb)
            }
            group.signal()
        }
        group.wait() // serialize: one-in-one-out, measures single-frame encode latency
    }
    VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(sess)
    return (encMs, buffers, hw)
}

// ---------- count NALUs in one sample buffer (macOS 26 multi-NALU check) ----------
func naluCount(_ sb: CMSampleBuffer) -> Int {
    guard let bb = CMSampleBufferGetDataBuffer(sb) else { return -1 }
    var len = 0; var dp: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &dp)
    guard let p = dp else { return -1 }
    let bytes = UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self)
    var off = 0; var count = 0
    // AVCC/HVCC style: 4-byte big-endian length prefix per NALU
    while off + 4 <= len {
        let l = (Int(bytes[off]) << 24) | (Int(bytes[off+1]) << 16) | (Int(bytes[off+2]) << 8) | Int(bytes[off+3])
        if l <= 0 || off + 4 + l > len { break }
        count += 1; off += 4 + l
    }
    return count
}

// ---------- TEST F: decode latency ----------
func testDecode(_ buffers: [CMSampleBuffer], _ w: Int, _ h: Int) {
    guard let first = buffers.first, let fmt = CMSampleBufferGetFormatDescription(first) else {
        print("  no buffers to decode"); return
    }
    let imgAttrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]
    var spec: [CFString: Any] = [:]
    if #available(macOS 10.13, *) {
        spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
    }
    var ds: VTDecompressionSession?
    let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt,
        decoderSpecification: spec as CFDictionary, imageBufferAttributes: imgAttrs as CFDictionary,
        outputCallback: nil, decompressionSessionOut: &ds)
    guard st == noErr, let sess = ds else { print("  decode session create failed: \(st)"); return }
    var hw: CFTypeRef?
    VTSessionCopyProperty(sess, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
    let hwStr = (hw as? Bool) == true ? "HW" : "SW/unknown"
    var decMs: [Double] = []
    let sem = DispatchSemaphore(value: 0)
    for sb in buffers {
        let t0 = nowMs()
        // flags = [] => synchronous, single-frame (no async, no temporal queueing)
        VTDecompressionSessionDecodeFrame(sess, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, img, _, _ in
            if status == noErr, img != nil { decMs.append(nowMs() - t0) }
            sem.signal()
        }
        sem.wait()
    }
    VTDecompressionSessionInvalidate(sess)
    print("  decode backing: \(hwStr) | frames=\(decMs.count) | p50=\(String(format:"%.2f",pct(decMs,50)))ms p99=\(String(format:"%.2f",pct(decMs,99)))ms max=\(String(format:"%.2f",decMs.max() ?? 0))ms")
    print("  DECISION (30fps frame=33.3ms): p99 \(pct(decMs,99) < 33.3 ? "< 1 frame => PASS" : "> 1 frame => investigate")")
}

// ---------- lossless property probe (E Session B) ----------
func testLossless(_ w: Int, _ h: Int) {
    var s: VTCompressionSession?
    VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
        codecType: kCMVideoCodecType_HEVC, encoderSpecification: hwGate(),
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard let sess = s else { print("  lossless probe: session create failed"); return }
    let q = VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_Quality, value: 1.0 as CFNumber)
    let atc = VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanFalse)
    // probe "Lossless" by raw CFString key (symbol may not be in SDK)
    let lkey = "Lossless" as CFString
    let l = VTSessionSetProperty(sess, key: lkey, value: kCFBooleanTrue)
    print("  Session-B probe: Quality=1.0 status=\(q) | AllowTemporalCompression=false status=\(atc) | Lossless(raw key) status=\(l) (0=accepted)")
    VTCompressionSessionInvalidate(sess)
}

// ================= RUN =================
print("=== VideoToolbox de-risk harness — Apple M1 Max / macOS 26.5 ===\n")

print("TEST G — concurrent hardware HEVC encoders (RequireHardwareAcceleratedVideoEncoder=true):")
testConcurrent(1920, 1080, "1080p")
testConcurrent(2560, 1440, "1440p")

print("\nTEST E/low-latency — HEVC EnableLowLatencyRateControl on M1 Max:")
let (encLL, bufsLL, hwLL) = encodeStream(1920, 1080, frames: 60, lowLatency: true)
print("  low-latency HEVC backing=\(hwLL) | encode p50=\(String(format:"%.2f",pct(encLL,50)))ms p99=\(String(format:"%.2f",pct(encLL,99)))ms (one-in-one-out)")
if let b = bufsLL.dropFirst(3).first { print("  NALUs per CMSampleBuffer (steady-state P-frame) = \(naluCount(b))  [macOS 26 multi-NALU check]") }
if let k = bufsLL.first { print("  NALUs in first frame (IDR, incl param sets) = \(naluCount(k))") }

print("\nTEST (baseline) — HEVC constant-quality 0.65:")
let (encCQ, _, hwCQ) = encodeStream(1920, 1080, frames: 30, lowLatency: false)
print("  constant-quality HEVC backing=\(hwCQ) | encode p50=\(String(format:"%.2f",pct(encCQ,50)))ms p99=\(String(format:"%.2f",pct(encCQ,99)))ms")

print("\nTEST F — HEVC decode latency (decodeFlags=0 synchronous, 1080p):")
testDecode(bufsLL, 1920, 1080)

print("\nTEST E Session-B — lossless/all-intra property availability:")
testLossless(1920, 1080)

print("\n=== done ===")
