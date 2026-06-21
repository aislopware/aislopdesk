import Foundation

/// User-facing subset of the ~80 video/host `AISLOPDESK_*` flags (decision #6 / #10), grouped into a
/// `Codable` model. These flags are read at `static let` init from the environment and CANNOT
/// live-reload — so the model is serialised to a `video-prefs.json` SIDECAR that the host daemon reads
/// at launch and folds into ``EnvConfig/overlay`` BEFORE any consumer's `static let` is forced (W12).
/// The Settings UI (W13) marks every field **"applies on reconnect / restart."**
///
/// Pure value type, no SwiftUI / `@AppStorage` — it persists via the sidecar (host) and round-trips
/// through `EnvBridge.toEnv()`. The model is the source of truth; `EnvBridge` maps each field 1:1 to
/// the `AISLOPDESK_*` key it overrides.
///
/// SYMMETRY: a few keys must be set IDENTICALLY on host AND client or the two ends disagree
/// (`AISLOPDESK_FEC_M` / `_FEC_K`, the mux window). Those fields are flagged in ``EnvBridge`` and the
/// UI surfaces a "set on both ends" warning.
///
/// DEFAULT = "unset": every field is `nil` by default, so a freshly-constructed `VideoPreferences`
/// produces an EMPTY env overlay (``EnvBridge/toEnv()`` emits nothing) — byte-identical to today's
/// compile-time-default behaviour. A field becomes an overlay entry only once the user sets it.
public struct VideoPreferences: Codable, Sendable, Equatable {
    // MARK: Quality (QP)

    /// Sharpest (lowest) constant QP on a clean link → `AISLOPDESK_QP_SHARP` (1…51, default 26).
    public var qpSharp: Int?
    /// Coarsest (highest) QP under congestion → `AISLOPDESK_QP_COARSE` (1…51, default 40).
    public var qpCoarse: Int?
    /// Min/Max QP decouple (skip-coding keeps a static sidebar crisp) → `AISLOPDESK_QP_DECOUPLE`.
    public var qpDecouple: Bool?

    // MARK: FEC (SYMMETRIC — set on both ends)

    /// Reed–Solomon parity count `m` → `AISLOPDESK_FEC_M` (`m >= 2` activates multi-loss RS). SYMMETRIC.
    public var fecM: Int?
    /// RS group size `k` → `AISLOPDESK_FEC_K`. Only consulted when `fecM >= 2`. SYMMETRIC.
    public var fecK: Int?

    // MARK: Pacer / playout

    /// Presentation pacer mode → `AISLOPDESK_PACER`. `deadline` = the smoothness-tuned buffer; any
    /// other value = present-on-arrival.
    public enum Pacer: String, Codable, Sendable, CaseIterable {
        case deadline
        case arrival
    }

    /// Presentation pacer → `AISLOPDESK_PACER`.
    public var pacer: Pacer?
    /// Fixed playout buffer (ms) → `AISLOPDESK_PLAYOUT_MS` (also flips the client OUT of adaptive playout).
    public var playoutMs: Double?

    // MARK: Capture

    /// Capture-scale override (downscale the 2× VD render to N× capture) → `AISLOPDESK_CAPTURE_SCALE`.
    public var captureScale: Double?
    /// SCStream filter mode → `AISLOPDESK_DISPLAY_CAPTURE` (`window` / `display` / `include`).
    public enum DisplayCapture: String, Codable, Sendable, CaseIterable {
        case window
        case display
        case include
    }

    /// Display-capture filter mode → `AISLOPDESK_DISPLAY_CAPTURE`.
    public var displayCapture: DisplayCapture?
    /// HiDPI 2× virtual display → `AISLOPDESK_VD` (default ON; OFF writes `"0"`).
    public var virtualDisplay: Bool?

    // MARK: Client-side render

    /// Unsharp-mask strength on the luma channel → `AISLOPDESK_SHARPEN` (0 = off). Client-side.
    public var sharpen: Double?

    public init(
        qpSharp: Int? = nil,
        qpCoarse: Int? = nil,
        qpDecouple: Bool? = nil,
        fecM: Int? = nil,
        fecK: Int? = nil,
        pacer: Pacer? = nil,
        playoutMs: Double? = nil,
        captureScale: Double? = nil,
        displayCapture: DisplayCapture? = nil,
        virtualDisplay: Bool? = nil,
        sharpen: Double? = nil,
    ) {
        self.qpSharp = qpSharp
        self.qpCoarse = qpCoarse
        self.qpDecouple = qpDecouple
        self.fecM = fecM
        self.fecK = fecK
        self.pacer = pacer
        self.playoutMs = playoutMs
        self.captureScale = captureScale
        self.displayCapture = displayCapture
        self.virtualDisplay = virtualDisplay
        self.sharpen = sharpen
    }
}
