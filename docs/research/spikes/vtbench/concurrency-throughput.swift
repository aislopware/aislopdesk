import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

func nowMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000.0 }
func p99(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[Int(0.99 * Double(xs.count - 1))] }
func p50(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[Int(0.50 * Double(xs.count - 1))] }

func makePB(_ w: Int, _ h: Int, _ seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let b = pb!; CVPixelBufferLockBaseAddress(b, [])
    let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w { let o = y*bpr+x*4
        let on = ((x/2+seed)%7==0)||((y/3)%11==0); let v: UInt8 = on ? 235:16
        p[o]=v;p[o+1]=v;p[o+2]=v;p[o+3]=255 } }
    CVPixelBufferUnlockBaseAddress(b, []); return b
}

func mkSession(_ w: Int, _ h: Int) -> VTCompressionSession? {
    var s: VTCompressionSession?
    let spec: CFDictionary = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    let st = VTCompressionSessionCreate(allocator:nil, width:Int32(w), height:Int32(h),
        codecType:kCMVideoCodecType_HEVC, encoderSpecification:spec, imageBufferAttributes:nil,
        compressedDataAllocator:nil, outputCallback:nil, refcon:nil, compressionSessionOut:&s)
    guard st == noErr, let sess = s else { return nil }
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
    VTCompressionSessionPrepareToEncodeFrames(sess)
    return sess
}

// K sessions, each on its own thread, encode `frames` back-to-back as fast as possible.
// Report aggregate fps and per-frame p50/p99 encode latency under concurrency.
func throughput(_ K: Int, _ w: Int, _ h: Int, frames: Int) {
    var sessions: [VTCompressionSession] = []
    for _ in 0..<K { if let s = mkSession(w,h) { sessions.append(s) } }
    guard sessions.count == K else { print("  K=\(K): only \(sessions.count) sessions created"); return }
    let lat = NSLock(); var allLat: [Double] = []
    let g = DispatchGroup()
    let pbs = (0..<8).map { makePB(w,h,$0) }  // reuse a small pool
    let tStart = nowMs()
    for k in 0..<K {
        g.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let sess = sessions[k]
            let sem = DispatchSemaphore(value: 0)
            var local: [Double] = []
            for i in 0..<frames {
                let pb = pbs[i % pbs.count]
                let t0 = nowMs()
                VTCompressionSessionEncodeFrame(sess, imageBuffer: pb,
                    presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: .invalid,
                    frameProperties: nil, infoFlagsOut: nil) { st,_,sb in
                    if st == noErr, sb != nil { local.append(nowMs()-t0) }
                    sem.signal()
                }
                sem.wait()
            }
            lat.lock(); allLat.append(contentsOf: local); lat.unlock()
            g.leave()
        }
    }
    g.wait()
    let elapsed = (nowMs() - tStart) / 1000.0
    let totalFrames = allLat.count
    let aggFps = Double(totalFrames) / elapsed
    print("  K=\(K) streams \(w)x\(h): agg \(String(format:"%.0f",aggFps)) fps total | per-stream \(String(format:"%.0f",aggFps/Double(K))) fps | encode p50=\(String(format:"%.1f",p50(allLat)))ms p99=\(String(format:"%.1f",p99(allLat)))ms | sustains 30fps/stream? \(aggFps/Double(K) >= 30 ? "YES" : "NO")")
    for s in sessions { VTCompressionSessionInvalidate(s) }
}

print("=== Sustained concurrent HEVC encode throughput (M1 Max) — real 'max simultaneous windows' ===")
print("(each stream encodes back-to-back; per-stream>=30fps => that many windows stream live at 30fps)")
for K in [1,2,4,6,8,12] { throughput(K, 1920, 1080, frames: 120) }
print("\n--- error code names ---")
print("  -12900 = kVTPropertyNotSupportedErr ; -12902 = kVTParameterErr ; -12903 = kVTInvalidSessionErr/resource")
