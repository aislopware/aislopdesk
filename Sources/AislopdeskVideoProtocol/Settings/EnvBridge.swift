import Foundation

/// The bridge between the settings MODELS and the `AISLOPDESK_*` flags they override (W12).
///
/// Two directions, both pure:
///  1. ``toEnv()`` — a settings model → its `[String: String]` env-overlay (keyed 1:1 to `AISLOPDESK_*`),
///     ready to fold into ``EnvConfig/overlay``. An UNSET field emits NO entry, so a default-constructed
///     model yields an EMPTY overlay ⇒ byte-identical to today's compile-time defaults (W12 invariant).
///  2. The `video-prefs.json` SIDECAR — host-daemon prefs (video + agent) serialised to a file the
///     daemon reads at launch (``loadSidecar(at:into:)``) and folds into ``EnvConfig/overlay`` BEFORE any
///     consumer's `static let` is forced (decision #10: no live reload — "applies on reconnect").
///
/// SYMMETRIC keys (``symmetricKeys``) must be set IDENTICALLY on host AND client (`AISLOPDESK_FEC_M` /
/// `_FEC_K`, the mux window) or the two ends disagree — the UI surfaces a "set on both ends" warning.
public enum EnvBridge {
    /// Keys that MUST match on host and client (CLAUDE.md "set identically on host and client"). The
    /// Settings UI flags these "set on both ends."
    public static let symmetricKeys: Set<String> = [
        "AISLOPDESK_FEC_M", "AISLOPDESK_FEC_K", "AISLOPDESK_MUX_WINDOW",
    ]

    // MARK: VideoPreferences → env

    /// Map a ``VideoPreferences`` to its `AISLOPDESK_*` overlay. Booleans use the SAME literal a user
    /// would type at the read site so the polarity is preserved exactly:
    ///   • `virtualDisplay` → `AISLOPDESK_VD` (`!= "0"` default-ON): emit `"0"` only when OFF.
    ///   • `qpDecouple`     → `AISLOPDESK_QP_DECOUPLE`: this site is default-ON (`!= "0"`) too.
    /// An UNSET (`nil`) field emits nothing.
    public static func toEnv(_ prefs: VideoPreferences) -> [String: String] {
        var env: [String: String] = [:]
        if let v = prefs.qpSharp { env["AISLOPDESK_QP_SHARP"] = String(v) }
        if let v = prefs.qpCoarse { env["AISLOPDESK_QP_COARSE"] = String(v) }
        if let v = prefs.qpDecouple { env["AISLOPDESK_QP_DECOUPLE"] = v ? "1" : "0" }
        if let v = prefs.fecM { env["AISLOPDESK_FEC_M"] = String(v) }
        if let v = prefs.fecK { env["AISLOPDESK_FEC_K"] = String(v) }
        if let v = prefs.pacer { env["AISLOPDESK_PACER"] = v.rawValue }
        if let v = prefs.playoutMs { env["AISLOPDESK_PLAYOUT_MS"] = formatDouble(v) }
        if let v = prefs.captureScale { env["AISLOPDESK_CAPTURE_SCALE"] = formatDouble(v) }
        if let v = prefs.displayCapture { env["AISLOPDESK_DISPLAY_CAPTURE"] = v.rawValue }
        if let v = prefs.virtualDisplay { env["AISLOPDESK_VD"] = v ? "1" : "0" }
        if let v = prefs.sharpen { env["AISLOPDESK_SHARPEN"] = formatDouble(v) }
        return env
    }

    // MARK: AgentPreferences → env

    /// Map an ``AgentPreferences`` to its `AISLOPDESK_*` overlay. Both flags are default-OFF (`== "1"`)
    /// host gates, so an explicit ON writes `"1"`, an explicit OFF writes `"0"`; unset emits nothing.
    public static func toEnv(_ prefs: AgentPreferences) -> [String: String] {
        var env: [String: String] = [:]
        if let v = prefs.agentDetect { env["AISLOPDESK_AGENT_DETECT"] = v ? "1" : "0" }
        if let v = prefs.agentHooks { env["AISLOPDESK_AGENT_HOOKS"] = v ? "1" : "0" }
        return env
    }

    /// Format a `Double` env value without a spurious exponent / trailing noise. Integral values print
    /// without a decimal point (`60.0` → `"60"`), matching what a user types and what `Double(_:)` /
    /// `Int(_:)` parse back at the read site.
    static func formatDouble(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e15 {
            return String(Int(v))
        }
        return String(v)
    }

    // MARK: video-prefs.json sidecar (host daemon)

    /// What the host daemon serialises to / reads from `video-prefs.json`: the launch-time prefs
    /// (video + agent) the daemon cannot live-reload. Versioned for forward tolerance.
    public struct VideoSidecar: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var video: VideoPreferences
        public var agent: AgentPreferences

        public init(video: VideoPreferences = .init(), agent: AgentPreferences = .init(), schemaVersion: Int = 1) {
            self.schemaVersion = schemaVersion
            self.video = video
            self.agent = agent
        }

        /// The combined `AISLOPDESK_*` overlay this sidecar contributes (video ∪ agent).
        public func toEnv() -> [String: String] {
            EnvBridge.toEnv(video).merging(EnvBridge.toEnv(agent)) { _, new in new }
        }
    }

    /// The default sidecar location under Application Support: `<AppSupport>/Aislopdesk/video-prefs.json`.
    /// `nil` only if the OS won't vend an Application-Support URL (never on macOS).
    public static func defaultSidecarURL(fileManager: FileManager = .default) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Aislopdesk", isDirectory: true)
            .appendingPathComponent("video-prefs.json", isDirectory: false)
    }

    /// Serialise the sidecar to `url` (creating the parent dir). Pretty-printed, stable key order.
    public static func writeSidecar(_ sidecar: VideoSidecar, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    /// Decode the sidecar at `url`. Returns `nil` (validate-then-drop) when the file is missing or the
    /// JSON is malformed — a corrupt prefs file MUST NOT brick the daemon; it falls back to env/defaults.
    public static func readSidecar(at url: URL) -> VideoSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VideoSidecar.self, from: data)
    }

    /// Daemon launch hook: read the sidecar (if present + valid) and fold its overlay into
    /// `EnvConfig.overlay`, WITHOUT clobbering an entry already there (a real `AISLOPDESK_*` env var,
    /// or an earlier overlay write, wins — the sidecar only fills gaps so a deliberate env override is
    /// honoured). Returns the keys it actually applied (for a launch-time debug line). Call this in
    /// `main()` BEFORE the video pipeline / any consumer `static let` is touched.
    @discardableResult
    public static func loadSidecar(at url: URL, into overlay: inout [String: String]) -> [String] {
        guard let sidecar = readSidecar(at: url) else { return [] }
        let env = ProcessInfo.processInfo.environment
        var applied: [String] = []
        for (key, value) in sidecar.toEnv() {
            // A real env var, or an existing overlay entry, always wins over the sidecar.
            if env[key] != nil || overlay[key] != nil { continue }
            overlay[key] = value
            applied.append(key)
        }
        return applied
    }

    /// Convenience: fold the default-location sidecar into the process-wide ``EnvConfig/overlay``.
    /// The one-liner a daemon `main()` calls.
    @discardableResult
    public static func loadDefaultSidecarIntoEnvConfig(fileManager: FileManager = .default) -> [String] {
        guard let url = defaultSidecarURL(fileManager: fileManager) else { return [] }
        return loadSidecar(at: url, into: &EnvConfig.overlay)
    }
}
