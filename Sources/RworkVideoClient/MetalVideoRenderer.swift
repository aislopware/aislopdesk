#if canImport(Metal) && canImport(QuartzCore)
import Foundation
import Metal
import CoreVideo
import QuartzCore
import OSLog
import simd

/// Zero-copy NV12 → RGB Metal renderer for decoded frames (doc 04, doc 17 §3.7).
///
/// ⚠️ **GUI-ONLY:** needs a real Metal device + a layer on screen. COMPILED +
/// reviewed; not driven from tests.
///
/// Design (cited):
/// - `CVMetalTextureCache` maps the decoded NV12 `CVPixelBuffer` to Metal textures
///   **zero-copy** (plane 0 = luma R8, plane 1 = chroma RG8) — a YCbCr→RGB fragment
///   shader converts on the GPU (doc 04 / doc 17 §3.7).
/// - Presents to a `CAMetalLayer` with `maximumDrawableCount = 2` (latency ~1 vsync,
///   doc 04 line 117).
/// - Driven from **VSync (`CADisplayLink`)**, NOT decode-completion — see
///   ``FramePacer``. On an empty queue it shows the last decoded frame; late frames
///   are skipped (doc 17 §3.7).
/// - Does NOT use `AVSampleBufferDisplayLayer` (adds >=1 frame buffering — doc 18 §F).
///
/// `@MainActor`-isolated: it owns + presents to a `CAMetalLayer`, which is main-thread
/// state. The frame pacer renders through a main-actor hop each vsync.
@MainActor
public final class MetalVideoRenderer {
    private let log = Logger(subsystem: "rwork.video.client", category: "MetalVideoRenderer")
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// The layer presented to. Configured for low-latency presentation.
    public let metalLayer: CAMetalLayer

    public init?(metalLayer: CAMetalLayer) {
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.metalLayer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2 // ~1 vsync latency (doc 04)

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "rwork_video_vertex"),
              let fragmentFunction = library.makeFunction(name: "rwork_video_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipelineState = pipelineState

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Draws one NV12 `CVPixelBuffer`. Called at vsync by ``FramePacer`` with the
    /// most recent decoded frame (show-last-frame on empty queue, skip-late upstream).
    public func render(_ pixelBuffer: CVPixelBuffer) {
        guard let textureCache,
              let drawable = metalLayer.nextDrawable() else { return } // nil → skip this vsync

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Keep the CVMetalTexture WRAPPERS (not just the MTLTextures) alive: the
        // MTLTexture does not retain its parent CVMetalTexture, and the texture's backing
        // IOSurface is owned by the wrapper + the cache. The GPU samples these textures
        // ASYNCHRONOUSLY (after `commit()`), so releasing the wrappers at function return
        // is a use-after-free → green/garbage frames or a GPU fault (classic
        // CVMetalTextureCache pitfall). We hold both wrappers until the command buffer
        // completes (see `addCompletedHandler` below).
        guard let lumaCV = makeTexture(pixelBuffer, cache: textureCache, planeIndex: 0, pixelFormat: .r8Unorm, width: width, height: height),
              let chromaCV = makeTexture(pixelBuffer, cache: textureCache, planeIndex: 1, pixelFormat: .rg8Unorm, width: width / 2, height: height / 2),
              let lumaTexture = CVMetalTextureGetTexture(lumaCV),
              let chromaTexture = CVMetalTextureGetTexture(chromaCV) else {
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        // Pin both CVMetalTexture wrappers (+ the pixel buffer) until the GPU is done
        // reading them. The completed handler runs on a private Metal thread; capturing
        // the wrappers there keeps their IOSurfaces valid for the whole async read. The
        // CV handles are not `Sendable`, so we ferry them in an unchecked-Sendable box —
        // the handler only RETAINS them (never reads), so crossing the boundary is safe.
        let pinned = TexturePin(luma: lumaCV, chroma: chromaCV, pixelBuffer: pixelBuffer)
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(pinned) {}
        }
        commandBuffer.commit()

        // Release this frame's recycled texture mappings so the cache's internal
        // registry does not grow unbounded across frames (the wrappers above keep the
        // in-flight surfaces alive regardless of the flush).
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, planeIndex: Int, pixelFormat: MTLPixelFormat, width: Int, height: Int) -> CVMetalTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            pixelFormat, width, height, planeIndex, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return cvTexture
    }

    /// Keeps a frame's CVMetalTexture wrappers + source pixel buffer alive across the
    /// asynchronous GPU read (held by the command buffer's completion handler). The
    /// handler only retains these immutable CoreVideo handles — never reads or mutates
    /// them — so ferrying them into the `@Sendable` handler is the documented escape
    /// hatch for immutable CV handles under strict concurrency.
    private struct TexturePin: @unchecked Sendable {
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
        let pixelBuffer: CVPixelBuffer
    }

    /// Inline Metal shader: full-screen triangle-strip quad + BT.709 NV12 YCbCr→RGB
    /// conversion (video-range). Kept inline so the target needs no `.metal` resource.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };

    vertex VertexOut rwork_video_vertex(uint vid [[vertex_id]]) {
        // Full-screen quad as a triangle strip.
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]       = { float2(0, 1),  float2(1, 1), float2(0, 0),  float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 rwork_video_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> lumaTex [[texture(0)]],
                                         texture2d<float> chromaTex [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = lumaTex.sample(s, in.uv).r;
        float2 cbcr = chromaTex.sample(s, in.uv).rg;
        // BT.709 video-range YCbCr -> RGB.
        float yy = (y - 16.0/255.0) * (255.0/219.0);
        float cb = cbcr.x - 128.0/255.0;
        float cr = cbcr.y - 128.0/255.0;
        float r = yy + 1.5748 * cr;
        float g = yy - 0.1873 * cb - 0.4681 * cr;
        float b = yy + 1.8556 * cb;
        return float4(r, g, b, 1.0);
    }
    """
}
#endif
