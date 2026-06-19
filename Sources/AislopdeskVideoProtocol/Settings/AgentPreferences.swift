import Foundation

/// Claude-Code / agent detection preferences (decision #5 / §7.5). Maps to the two agent-detection
/// flags the host reads — foreground-process watch (`AISLOPDESK_AGENT_DETECT`) and the opt-in Claude
/// hooks (`AISLOPDESK_AGENT_HOOKS`). The detection core (`AislopdeskAgentDetect`, W7) is env-free and
/// pure; these prefs gate whether the HOST emits the type-26/27 signals at all.
///
/// Like ``VideoPreferences``, these gate host-daemon behaviour read at launch, so they ride the same
/// `video-prefs.json` sidecar → ``EnvConfig/overlay`` mechanism (decision #10, "applies on reconnect").
/// Default = `nil` (unset) ⇒ EMPTY env overlay ⇒ today's compile-time-default behaviour.
public struct AgentPreferences: Codable, Sendable, Equatable {
    /// Host foreground-process watch (the primary, zero-config Claude signal, wire type 26) →
    /// `AISLOPDESK_AGENT_DETECT`. `nil` ⇒ unset (the daemon default).
    public var agentDetect: Bool?
    /// Claude Code hooks (the richest, opt-in signal, wire type 27) → `AISLOPDESK_AGENT_HOOKS`.
    public var agentHooks: Bool?

    public init(agentDetect: Bool? = nil, agentHooks: Bool? = nil) {
        self.agentDetect = agentDetect
        self.agentHooks = agentHooks
    }
}
