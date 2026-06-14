import CAislopdeskFFI
import CoreGraphics
import Foundation

/// Swift-side bridge from `AislopdeskVideoHost` to the Rust `aislopdesk-ffi` C ABI.
///
/// All `import CAislopdeskFFI` for the host module is contained here; the host's policy types
/// call these typed wrappers so their public APIs stay unchanged. The realtime bitrate logic
/// lives in the Rust core (`aislopdesk-core`) and is exposed over the C-ABI boundary; golden
/// vectors assert byte-/bit-exact output, so the macOS/iOS host and a future Android client
/// drive the identical algorithm from one core. Env knobs stay resolved Swift-side and are
/// passed in, keeping the core env-free.
enum RustVideoHostFFI {
    /// Resolution-aware target bitrate (bits/sec). Wraps `aisd_live_bitrate_target`.
    static func liveBitrateTarget(
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Int,
        floor: Int,
        bitsPerPixel: Double,
    ) -> Int {
        Int(
            aisd_live_bitrate_target(
                Int64(pixelWidth), Int64(pixelHeight), Int64(fps), Int64(floor), bitsPerPixel,
            ),
        )
    }

    /// The absolute minimum live bitrate (bits/sec). Wraps `aisd_live_bitrate_minimum`.
    static func liveBitrateMinimum() -> Int {
        Int(aisd_live_bitrate_minimum())
    }

    // MARK: - window_placement (pure, flat-struct; HiDPI VD-park path)

    /// Clamp `windowSize` DOWN to `displayBounds` (never enlarge) and place it at the display's
    /// top-left origin. Wraps `aisd_window_placement`.
    static func windowPlacement(windowSize: CGSize, displayBounds: CGRect)
        -> (origin: CGPoint, size: CGSize, needsResize: Bool)
    {
        let p = aisd_window_placement(
            Double(windowSize.width), Double(windowSize.height), aisdRect(displayBounds),
        )
        return (
            CGPoint(x: p.x, y: p.y),
            CGSize(width: p.width, height: p.height),
            p.needs_resize != 0,
        )
    }

    /// Whether `size` fits inside `bounds` (½-pt tolerance). Wraps `aisd_window_fits`.
    static func windowFits(_ size: CGSize, within bounds: CGRect) -> Bool {
        aisd_window_fits(Double(size.width), Double(size.height), aisdRect(bounds)) != 0
    }

    /// Flattens a `CGRect` into the C-ABI `AisdRect` (x, y, width, height — all `Double`).
    private static func aisdRect(_ r: CGRect) -> AisdRect {
        AisdRect(
            x: Double(r.origin.x),
            y: Double(r.origin.y),
            width: Double(r.size.width),
            height: Double(r.size.height),
        )
    }
}
