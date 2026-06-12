import Foundation

/// The PURE decision policy for "should a finished command raise a desktop notification".
///
/// Split out from the platform-specific poster so the threshold rule is unit-tested WITHOUT
/// touching `UNUserNotificationCenter` (which needs an app bundle + entitlements + an auth
/// prompt). The threshold is a single named constant so the "~10s" requirement lives in one
/// place. `#if`-unguarded so it compiles + tests on every platform.
public enum CommandNotificationPolicy {
    /// Commands shorter than this never notify — only LONG-running commands are worth a
    /// desktop alert (matches the iTerm2/Warp "command finished" default of ~10 seconds).
    /// A quick `ls` (milliseconds) is far below this and stays silent.
    public static let longRunningThresholdMS: UInt32 = 10_000

    /// The pure decision: notify iff the host-measured C→D duration is at least the threshold.
    /// `>=` so a command that took exactly the threshold notifies (and `sleep 12` clearly does).
    public static func shouldNotify(durationMS: UInt32) -> Bool {
        durationMS >= longRunningThresholdMS
    }
}

/// The PURE content policy for an EXPLICIT (OSC 9 / OSC 777) child-requested notification — the
/// title-fallback rule, split out so it is unit-tested without `UNUserNotificationCenter`.
public enum ExplicitNotificationContent {
    /// Resolves the displayed `(title, body)` for an explicit notification:
    /// - OSC 777 carries its own title → use it.
    /// - OSC 9 carries only a body (`explicitTitle == ""`) → the pane title is the title and the OSC
    ///   body is the body; if the pane has no title either, the body becomes the title (so the alert
    ///   is never blank) and the body line is dropped.
    public static func resolve(paneTitle: String, explicitTitle: String, body: String) -> (title: String, body: String) {
        let pane = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = explicitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return (explicit, body)
        }
        if !pane.isEmpty {
            return (pane, body)
        }
        // No title anywhere: promote the body so the alert is never blank.
        return (body, "")
    }
}

#if os(macOS)
import UserNotifications

/// Posts a LOCAL macOS notification when a LONG-running command completes (OSC 133;D with a
/// duration ≥ ``CommandNotificationPolicy/longRunningThresholdMS``). Best-effort, lazy-auth:
///
/// - **Lazy authorization:** `requestAuthorization` is called on the FIRST long-command
///   completion, not at launch, so a user who never runs a long command is never prompted.
/// - **Best-effort:** if authorization is denied or unavailable we simply do nothing — the
///   in-app running indicator (the PRIMARY deliverable) is unaffected.
/// - **macOS-only:** the whole type is `#if os(macOS)` and its sole call site is guarded too,
///   so iOS still builds. (`UNUserNotificationCenter` exists on iOS, but this deliverable is
///   scoped to the macOS workspace; dropping the guard later makes it portable.)
///
/// `@MainActor final class` because it caches authorization state across calls and is invoked
/// from the `@MainActor` ``ConnectionViewModel`` events loop. (A class — not a struct — so the
/// authorization cache mutated from the async `requestAuthorization` callback survives.)
@MainActor
final class CommandCompletionNotifier {
    /// Cached authorization result so we do not re-`requestAuthorization` on every long command
    /// (the OS only prompts once, but caching avoids the repeated round-trip and lets a denied
    /// user fall straight through). `nil` until the first request resolves.
    private var granted: Bool?

    init() {}

    /// Posts a "command finished" notification IFF `durationMS` clears the long-running
    /// threshold. A no-op for quick commands. TODO(B3): gate on the app/pane being UNFOCUSED so
    /// a foreground long command does not spam — left off for now so WF11 acceptance (which
    /// expects the notification with the window up) can observe it.
    func notifyIfLong(paneTitle: String, exitCode: Int32?, durationMS: UInt32) {
        guard CommandNotificationPolicy.shouldNotify(durationMS: durationMS) else { return }

        if granted != nil {
            // Already resolved — post (or no-op if denied) without re-prompting.
            post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS)
        } else {
            // Lazy authorization on the first long command. The completion handler is nonisolated
            // (Network/UN callback queue); hop back to the main actor carrying only Sendable values
            // (the Bool + the notification's primitive fields) so there is no cross-actor capture
            // of self until we are back on the main actor.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.post(paneTitle: paneTitle, exitCode: exitCode, durationMS: durationMS)
                }
            }
        }
    }

    /// Builds + adds the notification request — a no-op unless authorization was granted.
    private func post(paneTitle: String, exitCode: Int32?, durationMS: UInt32) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        content.title = paneTitle.isEmpty ? "Command finished" : paneTitle
        let secs = Int((Double(durationMS) / 1000).rounded())
        content.body = "command finished (exit \(exitCode.map(String.init) ?? "?"), \(secs)s)"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Posts an EXPLICIT (OSC 9 / OSC 777) child-requested notification, carrying `paneIDKey` in
    /// `userInfo` so a click can focus the originating pane (see ``PaneNotificationRouter``). Lazy-auth
    /// + best-effort like the long-command path; resolves the title fallback via the pure
    /// ``ExplicitNotificationContent``.
    func notifyExplicit(paneIDKey: String, paneTitle: String, title: String, body: String) {
        let resolved = ExplicitNotificationContent.resolve(paneTitle: paneTitle, explicitTitle: title, body: body)
        if granted != nil {
            postExplicit(paneIDKey: paneIDKey, title: resolved.title, body: resolved.body)
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor [weak self] in
                    self?.granted = ok
                    self?.postExplicit(paneIDKey: paneIDKey, title: resolved.title, body: resolved.body)
                }
            }
        }
    }

    /// Adds the explicit-notification request — a no-op unless authorization was granted.
    private func postExplicit(paneIDKey: String, title: String, body: String) {
        guard granted == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [PaneNotificationRouter.paneIDUserInfoKey: paneIDKey]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Routes a clicked notification (its `userInfo` pane-id) to a reveal closure the app wires to the
/// store (focus + centre the originating pane). The app installs it as the
/// `UNUserNotificationCenterDelegate` at launch; the key + parsing live here so they are one source
/// of truth shared with ``CommandCompletionNotifier``.
@MainActor
public final class PaneNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// The `userInfo` key carrying the originating pane's id string. `nonisolated` so the
    /// `nonisolated` delegate methods (and the poster) can read it without a main-actor hop.
    public nonisolated static let paneIDUserInfoKey = "aislopdesk.paneID"

    /// Called with the clicked notification's pane-id string. The app sets this to
    /// `store.revealPane(byIDString:)`.
    public var onReveal: ((String) -> Void)?

    public override init() { super.init() }

    /// Show the banner even while the app is foreground (otherwise an explicit notification fired while
    /// the user is looking at a different pane would be silently dropped). `nonisolated` to satisfy the
    /// delegate conformance; it touches no main-actor state.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// A click on the notification → reveal the originating pane (hops to the main actor for the store).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo[Self.paneIDUserInfoKey] as? String
        Task { @MainActor [weak self] in
            if let key { self?.onReveal?(key) }
        }
        completionHandler()
    }
}
#endif
