import AislopdeskAgentDetect
import AislopdeskInspector
import AislopdeskProtocol
import Foundation

/// W10/P1 — the SINGLE per-pane Claude-Code detector: ONE ``ClaudeStatusMachine`` fed by ALL the
/// host's detection inputs, so the host is the **single source of truth** and the client is a passive
/// display (adversarial-review findings #1–#4, #9).
///
/// ## Why one detector (the architectural fix)
/// The pre-P1 host ran TWO independent machines — ``ForegroundProcessDetector`` (foreground watch) and
/// ``AgentHookHandler`` (hook socket) — that BOTH emitted type-27 with no reconciliation, so they fought
/// (a hook `.working` and a foreground-poll `.idle` clobbered each other down the one CONTROL stream).
/// And NOBODY drove `.tick(at:)`, so the `.done → .idle` decay never fired (a finished turn stayed 🔵
/// forever). This type fuses every input into ONE machine, with ONE type-27 dedupe anchor and ONE
/// type-26 edge anchor → one machine, one type-27 stream.
///
/// ## Inputs (folded through the ONE machine, in the W7 precedence order)
/// - ``sample(name:at:)`` — the ~1 Hz foreground poll: `.processPresent(isClaude)` (exact-basename
///   classified via ``ClaudeManifestMatcher``) drives the presence FLOOR, and emits type-26 on a
///   basename EDGE (a coarse process-name hint for display, NOT a status source).
/// - ``hook(bytes:at:)`` — the hook socket: parsed via the W8 ``HookParser`` and folded as `.hook(event)`.
/// - ``tick(at:)`` — the per-poll clock tick (~1 Hz) that drives the `.done → .idle` decay.
/// - ``manifestVerdict(_:at:)`` — the no-hooks screen-text/title fallback (Decision #5 signal 3).
///
/// After each fold, type-27 is emitted ONLY when the `(state, kind, label)` triple changes (dedupe);
/// type-26 only on a basename edge. PURE + total: every input (empty/huge/hostile bytes, any name) is
/// tolerated — validate-then-drop, never traps, never force-unwraps. The clock is injected (a plain
/// `Double` seconds); the machine never reads a wall clock.
public struct ClaudePaneDetector: Sendable {
    /// The matcher used to classify a foreground basename as `claude` (exact basename — no
    /// `claudefoo` false positive). One classifier, reused from W7.
    private let matcher: ClaudeManifestMatcher

    /// The ONE per-pane state machine — every signal folds through this single instance (the fix).
    private var machine: ClaudeStatusMachine

    /// The last foreground basename a type-26 was emitted for (`nil` before the first sample). A new
    /// sample emits type-26 iff its basename differs from this.
    private var lastEmittedName: String?

    /// The last `(state, kind, label)` triple a type-27 was emitted for (`nil` before the first emit).
    /// A new machine verdict emits type-27 iff this triple changed (dedupe).
    private var lastEmittedStatus: ForegroundProcessDetector.StatusTriple?

    /// The wire `kind` byte for the LAST hook Notification class (`0` until a Notification arrives;
    /// carried so a type-27 emitted by a subsequent tick/presence fold still reports the live block
    /// class). Reset to `0` by any non-Notification transition through the machine that leaves the
    /// blocked state — modelled here as: a Notification sets it, anything that takes the machine off
    /// `.needsPermission` clears it back to `0`.
    private var lastNotificationKind: UInt8 = 0

    public init(doneToIdleTimeout: TimeInterval = 8) {
        matcher = ClaudeManifestMatcher()
        machine = ClaudeStatusMachine(doneToIdleTimeout: doneToIdleTimeout)
        lastEmittedName = nil
        lastEmittedStatus = nil
    }

    /// One decision: the (possibly empty) CONTROL messages to enqueue for this fold. Identical shape to
    /// ``ForegroundProcessDetector/Emission`` so the live wiring is unchanged.
    public struct Emission: Sendable, Equatable {
        /// The type-26 `foregroundProcess(name:)` to send, or `nil` (no basename edge).
        public var foreground: WireMessage?
        /// The type-27 `claudeStatus(...)` to send, or `nil` (status unchanged).
        public var status: WireMessage?

        public var isEmpty: Bool { foreground == nil && status == nil }

        /// Flattened for the caller's `enqueueControl([WireMessage])` — foreground first (presence
        /// floor), then the richer status, mirroring the machine's precedence.
        public var messages: [WireMessage] {
            var out: [WireMessage] = []
            if let foreground { out.append(foreground) }
            if let status { out.append(status) }
            return out
        }
    }

    /// The current rolled-up status (diagnostics / the live wiring's per-pane rollup).
    public var status: ClaudeStatus { machine.status }

    // MARK: - Inputs (all fold through the ONE machine)

    /// Fold one foreground-process sample at `now`. Emits type-26 on a basename edge (display hint) and
    /// drives the presence FLOOR; a non-claude/empty name forces `.none`. The richer hook status is NOT
    /// overridden by presence (presence only lifts `.none` → `.idle`; absence forces termination).
    public mutating func sample(name rawName: String, at now: TimeInterval) -> Emission {
        let base = ForegroundProcessDetector.basename(of: rawName)
        var emission = Emission()
        if base != lastEmittedName {
            lastEmittedName = base
            emission.foreground = .foregroundProcess(name: base)
        }
        let present = matcher.isClaudeRunning(processName: base)
        machine.reduce(.processPresent(present), at: now)
        // Presence absence terminates → not blocked anymore → forget the stale notification kind.
        if !present { lastNotificationKind = 0 }
        emission.status = statusEmissionIfChanged()
        return emission
    }

    /// Fold one received hook record (raw POST body bytes) at `now`. Parses via the W8 ``HookParser``
    /// (validate-then-drop: malformed/short/non-JSON bytes change nothing) and folds the event through
    /// the SAME machine. Emits type-27 iff the status triple changed; never a type-26 (the foreground
    /// process did not change).
    public mutating func hook(bytes: Data, at now: TimeInterval) -> Emission {
        var emission = Emission()
        guard let payload = HookParser.parse(bytes) else { return emission } // validate-then-drop
        let (event, kindByte) = AgentHookHandler.mapToHookEvent(payload)
        machine.reduce(.hook(event), at: now)
        // Track the live block class: a Notification carries its kind; any transition that leaves the
        // blocked state forgets it (so a later tick/presence type-27 reports kind 0, not a stale class).
        lastNotificationKind = (machine.status == .needsPermission) ? kindByte : 0
        emission.status = statusEmissionIfChanged()
        return emission
    }

    /// A bare clock tick at `now` — drives the machine's `done → idle` decay. Emits type-27 iff the
    /// decay changed the status; never a type-26.
    public mutating func tick(at now: TimeInterval) -> Emission {
        machine.reduce(.tick, at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        var emission = Emission()
        emission.status = statusEmissionIfChanged()
        return emission
    }

    /// Fold the no-hooks manifest fallback's coarse verdict at `now` (Decision #5 signal 3). Conservative:
    /// `.none` is ignored; richer verdicts apply only while a genuine HOOK block is not in effect (the
    /// machine enforces the precedence). Emits type-27 iff the status triple changed.
    ///
    /// **P6 — available but not yet live-fed (documented deferral).** This seam folds a
    /// ``ClaudeManifestMatcher`` verdict into the ONE machine, so the no-hooks screen-text/title fallback
    /// is wired and unit-tested end-to-end. It is NOT driven by the live host yet: the host streams raw
    /// PTY bytes and keeps only a tiny OSC sniffer — it does NOT maintain a screen buffer, so running
    /// `ClaudeManifestMatcher.coarseStatus(screen:)` would require buffering a recent-output ring and
    /// scanning it per chunk on the latency-critical read-loop thread (NOT cheap/clean — it would tax
    /// input-to-photon). The cheap signal the host DOES sniff (the OSC 2 title) only yields PRESENCE, and
    /// the foreground-process watch already supplies presence with an EXACT-basename classification
    /// (strictly better than a substring title match) — so feeding the title here would add churn for no
    /// gain. P1 is correct without it (presence + hooks detect a `claude`); when a cheap screen-text
    /// source lands (e.g. a host-side libghostty surface), drive this seam from `MuxChannelSession`. See
    /// docs/DECISIONS.md "Coding-workspace redesign → Claude Code auto-detection (P6)".
    public mutating func manifestVerdict(_ verdict: ClaudeStatus, at now: TimeInterval) -> Emission {
        machine.reduce(.manifestVerdict(verdict), at: now)
        if machine.status != .needsPermission { lastNotificationKind = 0 }
        var emission = Emission()
        emission.status = statusEmissionIfChanged()
        return emission
    }

    // MARK: - Status dedupe (ONE anchor for the ONE type-27 stream)

    /// Returns a type-27 `claudeStatus` message iff the machine's `(state, kind, label)` triple changed
    /// since the last emit; `nil` when unchanged (dedupe). `kind` reflects the live block class.
    private mutating func statusEmissionIfChanged() -> WireMessage? {
        let triple = ForegroundProcessDetector.StatusTriple(
            state: UInt8(truncatingIfNeeded: machine.status.urgency),
            kind: lastNotificationKind,
            label: machine.displayLabel ?? "",
        )
        if triple == lastEmittedStatus { return nil }
        lastEmittedStatus = triple
        return .claudeStatus(state: triple.state, kind: triple.kind, label: triple.label)
    }
}
