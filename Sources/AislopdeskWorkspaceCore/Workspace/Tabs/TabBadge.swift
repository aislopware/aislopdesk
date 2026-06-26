import AislopdeskAgentDetect
import Foundation

/// The single status badge a sidebar tab row carries — one icon, right-aligned (otty
/// `terminal-features__progress-state.md`, "Tab badges reflect the current progress state per tab").
///
/// PURE value type, **no SwiftUI**: the SF-symbol + tint mapping lives in the view layer
/// (`AislopdeskClientUI` `TabBadgeView`, WI-4) so this resolver unit-tests headless. There is
/// deliberately **no `.none` case** — the absence of a badge is `TabBadgeKind?` `nil`, not a sentinel.
///
/// Each case maps to a badge described in `progress-state.md` → "The full badge set".
public enum TabBadgeKind: Equatable, Sendable {
    /// **Running** — a spinner. `OSC 9;4;1`/`3` in progress, `otty watch` running, or a busy shell /
    /// a working agent. Rendered as an indeterminate spinner in the view layer.
    case running
    /// **Completed** — the green checkmark. The brief success flash a command shows on a clean exit
    /// (`OSC 133;D` exit 0) before it settles to ``finished``. This pure resolver emits ``completed``
    /// for a stored `.success` completion / an agent that just finished its turn; the decay to the
    /// settled accent dot (``finished``) is a time/unread concern handled by the view, not modeled here
    /// (the four inputs carry no timestamp).
    case completed
    /// **Finished** — the small accent dot, the "unread output" marker for a command that exited 0 and
    /// has settled past the ``completed`` flash. Kept in the kind set for the view's decay rendering;
    /// not produced by this timestamp-free resolver.
    case finished
    /// **Error** — the alert triangle. A command exited non-zero (`OSC 9;4;2` / a `.failure`
    /// completion) or an agent reported an error.
    case error
    /// **Awaiting input** — the hand icon. A code agent is blocked on approval/input
    /// (`ClaudeStatus.needsPermission`) or a plain command is stopped at an interactive prompt. The
    /// most-urgent state — it wins the precedence.
    case awaitingInput
    /// **Caffeinate** — the coffee cup. A sleep-blocking session (`caffeinate` foreground). Surfaces
    /// only when the shell is otherwise at rest (below the active states).
    case caffeinate
    /// **Sudo** — the shield. A privileged session (`sudo`/`su` foreground). Surfaces only when the
    /// shell is otherwise at rest (below the active states, above ``caffeinate``).
    case sudo
}

/// The PURE fusion policy that collapses the four per-pane badge signals into the single
/// ``TabBadgeKind`` a tab row shows. One badge per row; most-urgent wins.
///
/// **Fixed precedence** (E6 plan Design #5, distilled from `progress-state.md` + `parallel-tasks.md`):
///
/// ```
/// awaitingInput  >  error  >  running  >  sudo  >  caffeinate  >  completed/finished  >  nil
/// ```
///
/// Caffeinate/sudo deliberately sit **below** the active states so a *running* privileged command still
/// spins; the privilege badge only surfaces when the shell is at rest (otty's "session is active"
/// semantics).
///
/// Headless + deterministic: no SwiftUI, no clock, no I/O. The only inputs are the agent verdict, the
/// stored completion badge, the busy bit, and the (untrusted) foreground-process string — which is
/// classified by an **allow-set on its lowercased basename**, never `contains`, and defaults to "no
/// privilege badge" for anything unknown / `nil` (validate-then-default; no force-unwrap).
public enum TabBadgeResolver {
    /// Basenames that mark a **privileged** session (the shield). A small allow-set; matched exactly
    /// against the lowercased basename of the foreground process.
    private static let sudoBasenames: Set<String> = ["sudo", "su"]
    /// Basenames that mark a **sleep-blocking** session (the coffee cup).
    private static let caffeinateBasenames: Set<String> = ["caffeinate"]

    /// Resolve the one badge for a row, by fixed precedence (most-urgent wins).
    ///
    /// - Parameters:
    ///   - agent: the rolled-up `ClaudeStatus` for the pane (`needsPermission` ⇒ awaiting input,
    ///     `working` ⇒ running, `done` ⇒ completed; `idle`/`none` contribute nothing).
    ///   - completion: the stored OSC-133 exit-code badge (`.failure` ⇒ error, `.success` ⇒ completed),
    ///     or `nil` for none.
    ///   - isBusy: the live "command running" bit (`PaneSessionHandle.isShellBusy`) ⇒ running.
    ///   - foregroundProcess: the last foreground-process string the host reported (wire type 26),
    ///     possibly a bare name or a full path; UNTRUSTED. Classified by lowercased basename into
    ///     `sudo`/`caffeinate`, else ignored.
    /// - Returns: the badge to render, or `nil` when the row is all-clear.
    public static func badge(
        agent: ClaudeStatus,
        completion: PaneCompletionBadge?,
        isBusy: Bool,
        foregroundProcess: String?,
    ) -> TabBadgeKind? {
        // 1. Awaiting input — a blocked agent demands a human; highest urgency.
        if agent == .needsPermission { return .awaitingInput }

        // 2. Error — a failed command (non-zero exit / OSC 9;4;2).
        if completion == .failure { return .error }

        // 3. Running — a busy shell or a working agent spins.
        if isBusy || agent == .working { return .running }

        // 4 + 5. Privilege badges, only when the shell is at rest: sudo (shield) > caffeinate (coffee).
        if let privilege = privilegeBadge(forProcess: foregroundProcess) { return privilege }

        // 6. Completed/finished — a clean exit, or an agent that just finished its turn. This pure
        // resolver emits the immediate `.completed` (checkmark); the decay to the settled `.finished`
        // accent dot is a view-side concern (no timestamp here).
        if completion == .success || agent == .done { return .completed }

        // 7. All-clear.
        return nil
    }

    /// Classify the (untrusted) foreground-process string into a privilege badge by its **lowercased
    /// basename** against the allow-sets. `nil`/empty/unknown ⇒ no badge (validate-then-default). Never
    /// uses `contains` (which would misfire on e.g. `sudoedit-helper`), never force-unwraps.
    private static func privilegeBadge(forProcess process: String?) -> TabBadgeKind? {
        guard let name = basename(of: process) else { return nil }
        if sudoBasenames.contains(name) { return .sudo }
        if caffeinateBasenames.contains(name) { return .caffeinate }
        return nil
    }

    /// The lowercased last path component of `process`, or `nil` when there is nothing to classify.
    /// `"/usr/bin/sudo"` → `"sudo"`, `"caffeinate"` → `"caffeinate"`, `""`/`"/"`/`nil` → `nil`.
    private static func basename(of process: String?) -> String? {
        guard let process else { return nil }
        let trimmed = process.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Last non-empty `/`-delimited component. An all-slashes string yields no component → nil.
        guard let component = trimmed.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        return component.lowercased()
    }
}
