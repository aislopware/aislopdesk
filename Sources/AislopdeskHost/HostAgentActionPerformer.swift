#if os(macOS)
import AislopdeskProtocol
import Foundation

/// E13 WI-1 — the THIN macOS shim that actuates the THREE agent-hooks metadata verbs
/// (``MetadataVerb/installAgentHooks`` = 11 / ``MetadataVerb/uninstallAgentHooks`` = 12 /
/// ``MetadataVerb/agentHookStatus`` = 13) on the HOST's own `~/.claude/settings.json`. It is the
/// install/uninstall twin of ``HostPathActionPerformer``: ``MuxChannelSession/serveMetadata`` routes a
/// `metadataRequest` whose verb is 11/12/13 HERE (BEFORE the pure ``MetadataResponseBuilder``, which
/// performs NO side effects and never sees these verbs in production), and forwards every OTHER verb to
/// the builder. Like ``HostPathActionPerformer`` it is **compiled + code-reviewed ONLY** — never
/// instantiated in a unit test (it touches the host's home-directory settings file on disk; the
/// hang/IO-safety rule). The CLIENT routing (verb 11/12/13 encode + ok/error decode + the 1-byte status
/// flag) is the unit-tested half (``MetadataClient`` + `MetadataClientAgentHooksTests`), and the pure
/// install/uninstall/marker logic is tested in `AgentInstallerTests` / `AgentInstallerStatusTests`.
///
/// **Host-global, not pane-scoped.** Install/uninstall act on the host's single `~/.claude/settings.json`
/// regardless of which pane's mux channel carried the request, so this shim ignores the request payload
/// (the wire verbs carry an EMPTY payload). It resolves the target via ``AgentInstaller/defaultSettingsPath``
/// / ``AgentInstaller/defaultScriptPath`` (honoring `CLAUDE_CONFIG_DIR`).
///
/// **No exfiltration → no cwd confinement.** 11/12 return ONLY a status byte + empty payload; 13 returns
/// a single 1-byte flag (`1` installed / `0` not) — no host FILE contents ever cross the wire, so (like
/// 9/10) they are not an exfiltration vector. The host ALWAYS replies for 11/12/13 so the client's
/// pending-request registry never hangs; a thrown install/uninstall maps to ``MetadataStatus/error``
/// (validate-then-drop — never force-unwraps, never traps on a hostile verb).
///
/// `#if os(macOS)` — the host daemon is macOS-only; this is NEVER compiled into the iOS slice (the iOS
/// client routes install/uninstall/status TO the host over this same wire, it never performs them locally).
enum HostAgentActionPerformer {
    /// Routes one `metadataRequest`. If `verb` is an agent-hooks verb (11/12/13), actuates it against the
    /// host's default Claude config and returns the `metadataResponse`. Returns `nil` for EVERY other
    /// verb (incl. an unknown future byte) so the caller falls through to the read-only
    /// ``MetadataResponseBuilder`` unchanged — keeping this shim's responsibility to ONLY the three
    /// agent-hooks verbs. The request `payload` is intentionally ignored (host-global, empty by contract).
    static func response(requestID: UInt32, verb: UInt8, payload _: Data) -> WireMessage? {
        switch MetadataVerb(rawValue: verb) {
        case .installAgentHooks:
            return statusResponse(requestID: requestID, status: installHooks())
        case .uninstallAgentHooks:
            return statusResponse(requestID: requestID, status: uninstallHooks())
        case .agentHookStatus:
            let installed = AgentInstaller.isInstalled(settingsPath: AgentInstaller.defaultSettingsPath())
            return .metadataResponse(
                requestID: requestID,
                status: MetadataStatus.ok.rawValue,
                payload: Data([installed ? 1 : 0]),
            )
        default:
            return nil // not an agent-hooks verb → caller uses the read-only builder
        }
    }

    /// Installs the aislopdesk Claude Code hooks (script + `settings.json` merge) on the host. `.ok` on a
    /// successful write, `.error` if the install threw (a disk / permission failure). Named `installHooks`,
    /// NOT `install`, to keep the shim's surface self-describing alongside `uninstallHooks`.
    static func installHooks() -> MetadataStatus {
        do {
            try AgentInstaller.install(
                settingsPath: AgentInstaller.defaultSettingsPath(),
                scriptPath: AgentInstaller.defaultScriptPath(),
            )
            return .ok
        } catch {
            return .error
        }
    }

    /// Uninstalls the aislopdesk Claude Code hooks (strips exactly our `settings.json` entries) on the
    /// host. `.ok` on success, `.error` if the uninstall threw.
    static func uninstallHooks() -> MetadataStatus {
        do {
            try AgentInstaller.uninstall(settingsPath: AgentInstaller.defaultSettingsPath())
            return .ok
        } catch {
            return .error
        }
    }

    /// Builds an empty-payload `metadataResponse` carrying `status` (the 11/12 reply shape).
    private static func statusResponse(requestID: UInt32, status: MetadataStatus) -> WireMessage {
        .metadataResponse(requestID: requestID, status: status.rawValue, payload: Data())
    }
}
#endif
