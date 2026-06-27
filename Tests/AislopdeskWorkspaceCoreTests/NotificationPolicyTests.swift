import XCTest
@testable import AislopdeskWorkspaceCore

/// E14/K9: the PURE notification-delivery decision — the Notify-While-Foreground tri-state gate + the
/// per-event toggles. `UN`-free + headless (the macOS poster is the thin actuator), so the whole truth
/// table is asserted against an INDEPENDENT expectation, never the output's own derivation. This is the
/// carryover "the foreground gate must ACTUALLY gate" requirement, made a pure unit.
final class NotificationPolicyTests: XCTestCase {
    /// The shipped baseline (`NotificationSettings()`) matches the notification-setting.png defaults.
    /// Revert-to-confirm-fail: flipping any default below breaks this pin.
    func testDefaultSettingsMatchSpec() {
        let s = NotificationSettings()
        XCTAssertTrue(s.appNotificationsEnabled, "Allow App Notifications default ON")
        XCTAssertFalse(s.notifyOnFinish, "Notify on Command Finish default OFF")
        XCTAssertTrue(s.notifyOnError, "Notify on Error Exit default ON")
        XCTAssertTrue(s.notifyOnWatchFinish, "Notify on Watch Finish default ON")
        XCTAssertEqual(s.notifyWhileForeground, .off, "Notify While Foreground default Off")
        XCTAssertTrue(s.agentNotifyTaskComplete, "Agent task-complete default ON")
        XCTAssertTrue(s.agentNotifyAwaitInput, "Agent await-input default ON")
    }

    /// The picker label spec — notification-setting.png renders the long human form for `tabUnfocused`,
    /// and the raw tokens round-trip as the otty config values.
    func testNotifyWhileForegroundLabelsAndRawValues() {
        XCTAssertEqual(NotifyWhileForeground.off.displayLabel, "Off")
        XCTAssertEqual(NotifyWhileForeground.always.displayLabel, "Always")
        XCTAssertEqual(NotifyWhileForeground.tabUnfocused.displayLabel, "Only when source tab is unfocused")
        XCTAssertEqual(NotifyWhileForeground.tabUnfocused.rawValue, "tab-unfocused")
        XCTAssertEqual(NotifyWhileForeground.allCases.count, 3)
    }

    // MARK: - Per-event toggle gate (app backgrounded → the foreground gate is a pass-through, isolating it)

    /// Each event maps to exactly ONE toggle; with the app NOT active the foreground gate always passes, so
    /// these assertions isolate the per-event toggle. explicitOSC rides the master "Allow App Notifications".
    func testExplicitOSCRidesMasterSwitch() {
        let on = NotificationSettings(appNotificationsEnabled: true)
        let off = NotificationSettings(appNotificationsEnabled: false)
        XCTAssertTrue(deliver(.explicitOSC, appActive: false, focused: false, settings: on))
        XCTAssertFalse(deliver(.explicitOSC, appActive: false, focused: false, settings: off))
    }

    /// A clean exit (0 / nil) rides Notify-on-Finish; a non-zero exit rides Notify-on-Error — independent.
    func testCommandFinishSplitsCleanVsError() {
        // Defaults: finish OFF, error ON.
        let d = NotificationSettings()
        XCTAssertFalse(
            deliver(.commandFinish(exit: 0), appActive: false, focused: false, settings: d),
            "a clean exit does not notify by default (Notify on Finish OFF)",
        )
        XCTAssertFalse(
            deliver(.commandFinish(exit: nil), appActive: false, focused: false, settings: d),
            "a nil exit is treated as a clean exit → Notify on Finish OFF",
        )
        XCTAssertTrue(
            deliver(.commandFinish(exit: 1), appActive: false, focused: false, settings: d),
            "a non-zero exit notifies by default (Notify on Error ON)",
        )
        // Flip both toggles → the split inverts.
        let flipped = NotificationSettings(notifyOnFinish: true, notifyOnError: false)
        XCTAssertTrue(deliver(.commandFinish(exit: 0), appActive: false, focused: false, settings: flipped))
        XCTAssertFalse(deliver(.commandFinish(exit: 1), appActive: false, focused: false, settings: flipped))
    }

    /// Watch-finish and the two agent events each ride their own toggle.
    func testWatchAndAgentTogglesGateIndependently() {
        let allOff = NotificationSettings(
            notifyOnWatchFinish: false, agentNotifyTaskComplete: false, agentNotifyAwaitInput: false,
        )
        XCTAssertFalse(deliver(.watchFinish, appActive: false, focused: false, settings: allOff))
        XCTAssertFalse(deliver(.agentTaskComplete, appActive: false, focused: false, settings: allOff))
        XCTAssertFalse(deliver(.agentAwaitInput, appActive: false, focused: false, settings: allOff))

        let allOn = NotificationSettings() // watch + both agent toggles default ON
        XCTAssertTrue(deliver(.watchFinish, appActive: false, focused: false, settings: allOn))
        XCTAssertTrue(deliver(.agentTaskComplete, appActive: false, focused: false, settings: allOn))
        XCTAssertTrue(deliver(.agentAwaitInput, appActive: false, focused: false, settings: allOn))

        // The two agent toggles are NOT coupled: await-input ON while task-complete OFF.
        let split = NotificationSettings(agentNotifyTaskComplete: false, agentNotifyAwaitInput: true)
        XCTAssertFalse(deliver(.agentTaskComplete, appActive: false, focused: false, settings: split))
        XCTAssertTrue(deliver(.agentAwaitInput, appActive: false, focused: false, settings: split))
    }

    // MARK: - Notify-While-Foreground gate (event toggle held ON via explicitOSC + master ON)

    /// When the app is NOT active the OS shows the banner normally → always delivered, regardless of the
    /// tri-state or the source focus.
    func testBackgroundedAppAlwaysDelivers() {
        for policy in NotifyWhileForeground.allCases {
            for focused in [true, false] {
                let s = NotificationSettings(notifyWhileForeground: policy)
                XCTAssertTrue(
                    deliver(.explicitOSC, appActive: false, focused: focused, settings: s),
                    "backgrounded app delivers under \(policy)/focused=\(focused)",
                )
            }
        }
    }

    /// `.off` while frontmost suppresses — focused or not (the otty default; the system suppresses banners).
    func testForegroundOffSuppresses() {
        let s = NotificationSettings(notifyWhileForeground: .off)
        XCTAssertFalse(deliver(.explicitOSC, appActive: true, focused: true, settings: s))
        XCTAssertFalse(deliver(.explicitOSC, appActive: true, focused: false, settings: s))
    }

    /// `.always` while frontmost delivers — focused or not.
    func testForegroundAlwaysDelivers() {
        let s = NotificationSettings(notifyWhileForeground: .always)
        XCTAssertTrue(deliver(.explicitOSC, appActive: true, focused: true, settings: s))
        XCTAssertTrue(deliver(.explicitOSC, appActive: true, focused: false, settings: s))
    }

    /// `.tabUnfocused` while frontmost delivers ONLY when the source pane is not the focused one.
    func testForegroundTabUnfocusedGatesOnSourceFocus() {
        let s = NotificationSettings(notifyWhileForeground: .tabUnfocused)
        XCTAssertFalse(
            deliver(.explicitOSC, appActive: true, focused: true, settings: s),
            "the source tab IS focused → suppressed",
        )
        XCTAssertTrue(
            deliver(.explicitOSC, appActive: true, focused: false, settings: s),
            "the source tab is unfocused → delivered",
        )
    }

    /// BOTH stages must pass: a disabled per-event toggle suppresses even with `.always` (proves the gate
    /// is an AND of the toggle and the foreground policy, not just one or the other).
    func testDisabledToggleSuppressesEvenWithAlways() {
        let s = NotificationSettings(notifyOnFinish: false, notifyWhileForeground: .always)
        XCTAssertFalse(
            deliver(.commandFinish(exit: 0), appActive: true, focused: false, settings: s),
            "Notify on Finish OFF suppresses even when the foreground policy would allow",
        )
    }

    // MARK: helper

    private func deliver(
        _ event: NotificationEvent, appActive: Bool, focused: Bool, settings: NotificationSettings,
    ) -> Bool {
        NotificationPolicy.shouldDeliver(
            event: event, appActive: appActive, sourcePaneFocused: focused, settings: settings,
        )
    }
}
