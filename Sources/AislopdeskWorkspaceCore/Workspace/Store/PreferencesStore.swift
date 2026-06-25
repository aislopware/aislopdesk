// L0 / G2: de-SwiftUI'd — this store is UserDefaults-backed (no `@AppStorage`) and lives in the
// headless `AislopdeskWorkspaceCore`. The `import SwiftUI` + `#if canImport(SwiftUI)` guard are gone;
// `@MainActor`/`@Observable` come from the Observation framework.
import AislopdeskVideoProtocol
import Foundation
import Observation

// MARK: - PreferencesStore (the one live settings owner)

/// The single live source of truth for the GUI Settings system (W13). A `@MainActor @Observable`
/// store that owns the four W12 `Codable` models — ``VideoPreferences``, ``TerminalPreferences``,
/// ``AgentPreferences``, ``KeybindingPreferences`` — and persists each to `UserDefaults` (the
/// `@AppStorage`-style bridge for client/terminal prefs) PLUS the `video-prefs.json` sidecar (the
/// daemon-at-launch bridge for the video/agent host flags).
///
/// FOUR apply paths (decision #6 / #10):
///   1. **Live client/agent prefs → ``EnvConfig/overlay``.** `sharpen` and the agent gates that the
///      CLIENT process reads are folded into the process-wide overlay so a live setting overrides the
///      compile-time default WITHOUT an env var.
///   2. **Video prefs → the `video-prefs.json` SIDECAR (no live apply).** The ~80 video flags are read
///      at `static let` init and CANNOT live-reload, so a change is written to the sidecar the HOST
///      daemon reads at next launch — the UI marks these **"applies on reconnect."**
///   3. **Terminal prefs → the live terminal reload.** A change rebuilds the libghostty config string
///      (``TerminalConfigBuilder``) and bumps ``TerminalConfigBroadcaster`` so the (Xcode-app-target-
///      only) `GhosttyTerminalView` re-applies it via `ghostty_config_load_string` + a PTY grid resize.
///   4. **Keybinding prefs → the W6 registry overrides.** The store publishes the current
///      ``KeybindingPreferences`` to ``WorkspaceBindingRegistry`` (via
///      ``WorkspaceBindingRegistry/activeOverrides``) so a chord resolves with the user override when one
///      is present — the registry stays the single binding TABLE; this only supplies the overrides.
///
/// BEHAVIOR-PRESERVATION: a fresh install (no persisted prefs) loads the model DEFAULTS — for video /
/// agent that is the all-`nil` model ⇒ an EMPTY ``EnvConfig`` overlay ⇒ no sidecar override ⇒
/// byte-identical to today (the golden corpus is unaffected). Terminal prefs DO have real defaults
/// (they are render prefs), but the libghostty apply is compile-only and the headless build / golden
/// never sees it.
@preconcurrency
@MainActor
@Observable
public final class PreferencesStore {
    // MARK: Persisted models (the live source the UI binds)

    /// Live, client-side terminal-render prefs (font / theme / cursor / scrollback). A `didSet` reloads.
    public var terminal: TerminalPreferences {
        didSet { if terminal != oldValue { persistTerminal()
            applyTerminal()
        } }
    }

    /// The video / FEC / pacer / capture host flags. A `didSet` writes the sidecar + folds the
    /// client-readable subset into the overlay. "Applies on reconnect" for the host-read flags.
    public var video: VideoPreferences {
        didSet { if video != oldValue { persistVideo()
            applyVideoAndAgent()
        } }
    }

    /// Agent (Claude) detection gates (foreground watch / hooks). A `didSet` writes the sidecar.
    public var agent: AgentPreferences {
        didSet { if agent != oldValue { persistAgent()
            applyVideoAndAgent()
        } }
    }

    /// User keybinding overrides (`bindingID → chord`). A `didSet` republishes them to the W6 registry.
    public var keybindings: KeybindingPreferences {
        didSet { if keybindings != oldValue { persistKeybindings()
            applyKeybindings()
        } }
    }

    /// CLIENT-chrome appearance (otty theme + density). A `didSet` persists + applies. CRITICAL: this is
    /// pure client chrome — it is NEVER folded into ``EnvConfig/overlay`` nor written to the sidecar (so
    /// the golden corpus is untouched); it repoints the runtime ``ThemeStore`` (via ``AppearanceApplier``)
    /// and writes ``SettingsKey/density`` only. Default (all-`nil`) ⇒ no behaviour change.
    public var appearance: AppearancePreferences {
        didSet { if appearance != oldValue { persistAppearance()
            applyAppearance()
        } }
    }

    /// Raw `AISLOPDESK_*` overrides for power users (the Advanced panel). A sparse `[key: value]` that is
    /// folded LAST into the ``EnvConfig`` overlay so an explicit raw override wins over the typed prefs.
    /// Persisted separately; an empty map (the default) contributes nothing (behavior-preserving).
    public var rawOverrides: [String: String] {
        didSet { if rawOverrides != oldValue { persistRawOverrides()
            applyVideoAndAgent()
        } }
    }

    // MARK: Dependencies (injectable for tests)

    private let defaults: UserDefaults
    private let sidecarURL: URL?

    // MARK: UserDefaults keys

    enum Key {
        static let terminal = "settings.terminal.v1"
        static let video = "settings.video.v1"
        static let agent = "settings.agent.v1"
        static let keybindings = "settings.keybindings.v1"
        static let appearance = "settings.appearance.v1"
        static let rawOverrides = "settings.rawOverrides.v1"
        static let blockBookmarks = "settings.blockBookmarks.v1"
        /// L4 / W4: the dismissed agent-notification suggestion chips, keyed by agent display-name. A
        /// plain `[agentName: true]` JSON map so a dismissed "Enable Claude Code notifications" pill
        /// stays dismissed across launches (Warp persists this in `AISSettings` keyed by agent+host).
        static let notificationChipDismissed = "settings.agentNotificationDismissed.v1"
        /// L4 / W4: agents for which the user has ENABLED rich notifications (clicked the green pill). No
        /// host wire exists for the OSC/notification-enable path today, so this records intent + drives
        /// the chip's "already enabled ⇒ hide" behaviour. `[agentName: true]`.
        static let notificationChipEnabled = "settings.agentNotificationEnabled.v1"
    }

    // MARK: Init / load

    /// Loads the persisted prefs (or the model defaults on a fresh install) and applies them. The
    /// `sidecarURL` defaults to the shared `video-prefs.json` location; tests inject a temp URL (or
    /// `nil` to skip the sidecar write). `applyOnInit` runs the apply paths once after load (default
    /// ON; a test that only wants round-trip can pass `false` to avoid mutating the process overlay).
    public init(
        defaults: UserDefaults = .standard,
        sidecarURL: URL? = EnvBridge.defaultSidecarURL(),
        applyOnInit: Bool = true,
    ) {
        self.defaults = defaults
        self.sidecarURL = sidecarURL
        terminal = Self.decode(TerminalPreferences.self, defaults, Key.terminal) ?? TerminalPreferences()
        video = Self.decode(VideoPreferences.self, defaults, Key.video) ?? VideoPreferences()
        agent = Self.decode(AgentPreferences.self, defaults, Key.agent) ?? AgentPreferences()
        keybindings = Self.decode(KeybindingPreferences.self, defaults, Key.keybindings) ?? KeybindingPreferences()
        appearance = Self.decode(AppearancePreferences.self, defaults, Key.appearance) ?? AppearancePreferences()
        rawOverrides = (defaults.dictionary(forKey: Key.rawOverrides) as? [String: String]) ?? [:]
        if applyOnInit {
            applyTerminal()
            applyVideoAndAgent()
            applyKeybindings()
            applyAppearance()
        }
    }

    // MARK: Persist (model → UserDefaults)

    private func persistTerminal() { Self.encode(terminal, defaults, Key.terminal) }
    private func persistVideo() { Self.encode(video, defaults, Key.video) }
    private func persistAgent() { Self.encode(agent, defaults, Key.agent) }
    private func persistKeybindings() { Self.encode(keybindings, defaults, Key.keybindings) }
    private func persistAppearance() { Self.encode(appearance, defaults, Key.appearance) }
    private func persistRawOverrides() { defaults.set(rawOverrides, forKey: Key.rawOverrides) }

    private static func encode(_ value: some Encodable, _ defaults: UserDefaults, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Apply paths

    /// Rebuild the libghostty config string from the live terminal prefs (+ any terminal keybind lines)
    /// and bump the broadcaster so the (Xcode-only) `GhosttyTerminalView` re-applies it live.
    private func applyTerminal() {
        // The active otty THEME pins the terminal CELL bg/fg (flat design) — `resolveTerminalColors` reads
        // the resolved `ThemeStore.active` (GUI only; `nil` headless ⇒ the pref's own colours stand).
        let themeColors = AppearanceApplier.resolveTerminalColors?()
        let config = TerminalConfigBuilder.string(
            for: terminal,
            backgroundOverride: themeColors?.background,
            foregroundOverride: themeColors?.foreground,
        )
        TerminalConfigBroadcaster.shared.publish(config)
    }

    /// Fold the video + agent prefs (and the raw overrides) into the process-wide ``EnvConfig`` overlay
    /// for the CLIENT-readable flags, and write the `video-prefs.json` SIDECAR for the host daemon.
    ///
    /// WITHIN the overlay, precedence is typed-prefs (video ∪ agent) THEN the raw power-user overrides on
    /// top, so an explicit `AISLOPDESK_*` typed by hand in the Settings raw-overrides box wins over the
    /// matching toggle. ACROSS tiers, a real `ProcessInfo` env var STILL wins over the whole overlay
    /// (decision #16, `env → overlay → default`): ``EnvConfig/string(_:)`` checks the real env var FIRST
    /// and only falls back to the overlay, so a deliberate `launchctl`/`--args` env on the CLIENT is never
    /// clobbered by a persisted setting — consistent with the host sidecar's gap-fill.
    private func applyVideoAndAgent() {
        var overlay = EnvBridge.toEnv(video).merging(EnvBridge.toEnv(agent)) { _, new in new }
        for (key, value) in rawOverrides where !key.isEmpty { overlay[key] = value }
        EnvConfig.overlay = overlay
        writeSidecar()
    }

    /// Serialise the video + agent prefs to the `video-prefs.json` sidecar the HOST daemon reads at
    /// launch. A nil `sidecarURL` (tests) skips the write. Failure is swallowed — a prefs write that
    /// can't reach disk must not crash the UI (the typed defaults still hold).
    private func writeSidecar() {
        guard let url = sidecarURL else { return }
        let sidecar = EnvBridge.VideoSidecar(video: video, agent: agent)
        try? EnvBridge.writeSidecar(sidecar, to: url)
    }

    /// Publish the live keybinding overrides to the W6 registry so a chord resolves with the user
    /// override when present (the registry stays the single binding TABLE; this supplies the overrides).
    private func applyKeybindings() {
        WorkspaceBindingRegistry.activeOverrides = keybindings
    }

    /// Apply the CLIENT-chrome appearance: repoint the runtime ``ThemeStore`` (via ``AppearanceApplier`` —
    /// the GUI layer's injected closure; `nil` on headless) and write ``SettingsKey/density`` when set.
    ///
    /// GOLDEN-SAFE BY CONSTRUCTION: appearance NEVER touches ``EnvConfig/overlay`` nor the sidecar — it is
    /// pure client chrome. A `nil` density leaves the key untouched (so a default ``AppearancePreferences``
    /// is a pure no-op, behaviour-preserving). The theme hook is invoked with the (possibly `nil`) choice
    /// so the GUI can fall back to its compile-time default when appearance is reset.
    private func applyAppearance() {
        AppearanceApplier.apply?(appearance.theme)
        // The theme also drives the terminal CELL bg/fg (flat design), so rebuild the terminal config AFTER
        // the theme is repointed — a theme switch then repaints the terminal surface, not just the chrome.
        applyTerminal()
        if let density = appearance.density {
            defaults.set(density, forKey: SettingsKey.density)
        }
    }

    // MARK: Convenience for the UI

    /// Reset EVERY pref to its model default (the "Restore Defaults" affordance). The `didSet`s persist
    /// + re-apply each, so the process returns to behavior-preserving defaults (empty overlay, no
    /// sidecar override) exactly as a fresh install.
    public func resetAll() {
        terminal = TerminalPreferences()
        video = VideoPreferences()
        agent = AgentPreferences()
        keybindings = KeybindingPreferences()
        appearance = AppearancePreferences()
        rawOverrides = [:]
    }

    // MARK: Block bookmarks (WB3 — per-session starred command blocks)

    /// The persisted per-session block bookmarks: `sessionUUID → [block index]`. A separate
    /// `UserDefaults` key (`settings.blockBookmarks.v1`) holding a plain `[String: [UInt32]]` JSON map —
    /// NOT part of the four typed prefs models, and never folded into the env overlay / sidecar (so the
    /// golden corpus is untouched). An absent key (fresh install) reads as empty.
    private func loadBlockBookmarkMap() -> [String: [UInt32]] {
        Self.decode([String: [UInt32]].self, defaults, Key.blockBookmarks) ?? [:]
    }

    /// The bookmarked block indices for `sessionUUID` (empty if none / unknown). The wiring layer seeds a
    /// pane's ``TerminalBlockModel`` from this on attach.
    public func blockBookmarks(for sessionUUID: String) -> [UInt32] {
        loadBlockBookmarkMap()[sessionUUID] ?? []
    }

    /// Persists `indices` as `sessionUUID`'s bookmarks (an EMPTY set removes the key entry, keeping the map
    /// tidy). The wiring layer calls this from the model's `onBookmarksChanged`.
    public func setBlockBookmarks(_ indices: [UInt32], for sessionUUID: String) {
        var map = loadBlockBookmarkMap()
        if indices.isEmpty { map.removeValue(forKey: sessionUUID) } else { map[sessionUUID] = indices }
        Self.encode(map, defaults, Key.blockBookmarks)
    }

    // MARK: Agent notification suggestion chip (L4 / W4 — green "Enable … notifications" pill)

    /// Whether the green suggestion chip for `agent` has been dismissed (the trailing ✕). Persisted so a
    /// dismissed chip does not reappear on the next launch (W4). An unknown agent reads `false`.
    public func isNotificationChipDismissed(for agent: String) -> Bool {
        notificationChipMap(Key.notificationChipDismissed)[agent] ?? false
    }

    /// Persist that the suggestion chip for `agent` was dismissed (✕). Idempotent.
    public func dismissNotificationChip(for agent: String) {
        setNotificationChipFlag(true, for: agent, key: Key.notificationChipDismissed)
    }

    /// Whether the user has ENABLED rich notifications for `agent` (clicked the green pill's main half).
    /// Recorded per-agent (also hides the chip, like a dismissal). The actual delivery is the GLOBAL OSC
    /// notification toggle (`SettingsKey.oscNotifications`, default-ON), which `enableNotifications` turns
    /// back on so the green CTA is a real action.
    public func isNotificationChipEnabled(for agent: String) -> Bool {
        notificationChipMap(Key.notificationChipEnabled)[agent] ?? false
    }

    /// Record that the user enabled notifications for `agent` (clicked the green pill) AND actually enable
    /// delivery by turning the global OSC/notification toggle ON (it is the delivery gate read by the app
    /// sinks). Default-ON already, but a user who turned it OFF and then clicks the green CTA expects it
    /// back ON. Hides the chip via the per-agent flag.
    public func enableNotifications(for agent: String) {
        setNotificationChipFlag(true, for: agent, key: Key.notificationChipEnabled)
        // W4: deliver on the promise — re-enable the global OSC/notification delivery gate.
        defaults.set(true, forKey: SettingsKey.oscNotifications)
    }

    /// Whether the green suggestion chip should be SHOWN for `agent`: not already dismissed and not
    /// already enabled (W4 + Warp's "hide once a plugin connects or the user dismisses it" rule).
    public func shouldShowNotificationChip(for agent: String) -> Bool {
        !isNotificationChipDismissed(for: agent) && !isNotificationChipEnabled(for: agent)
    }

    private func notificationChipMap(_ key: String) -> [String: Bool] {
        Self.decode([String: Bool].self, defaults, key) ?? [:]
    }

    private func setNotificationChipFlag(_ value: Bool, for agent: String, key: String) {
        guard !agent.isEmpty else { return }
        var map = notificationChipMap(key)
        if value { map[agent] = true } else { map.removeValue(forKey: agent) }
        Self.encode(map, defaults, key)
    }

    /// The keybinding conflicts the UI highlights — DISTINCT ids resolving to the same chord (W12
    /// ``KeybindingPreferences/conflicts()``). Only explicit overrides collide here; the registry
    /// defaults are conflict-free by construction (pinned by `TreeCommandRoutingTests`).
    public func keybindingConflicts() -> [String: [String]] { keybindings.conflicts() }
}

// MARK: - TerminalConfigBroadcaster (the live terminal-reload seam)

/// The process-wide bridge that carries the current libghostty config STRING from the
/// ``PreferencesStore`` to the (Xcode-app-target-only) `GhosttyTerminalView`, which re-applies it via
/// `ghostty_config_load_string` and re-measures + resizes the PTY grid.
///
/// It is a tiny `@Observable` holder (not the model) so the gated renderer can `@Observe` it without
/// importing the whole store, and the HEADLESS build keeps a no-op consumer (the placeholder ignores
/// it). The `generation` bumps on each publish so an idempotent re-publish of the SAME string still
/// triggers a reload (e.g. the user toggles a value back and forth).
@preconcurrency
@MainActor
@Observable
public final class TerminalConfigBroadcaster {
    public static let shared = TerminalConfigBroadcaster()

    /// The current libghostty config string (built by ``TerminalConfigBuilder``). Empty until the first
    /// publish (the renderer then keeps libghostty's compiled-in defaults).
    public private(set) var configString = ""
    /// Monotonic publish counter — the renderer keys its "apply on change" off this, so re-publishing the
    /// same string still reloads.
    public private(set) var generation = 0

    public init() {}

    /// Publish a new config string (bumps ``generation`` even if unchanged).
    public func publish(_ config: String) {
        configString = config
        generation &+= 1
    }
}
