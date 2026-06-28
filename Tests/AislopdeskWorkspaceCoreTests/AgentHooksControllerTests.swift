import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E13 WI-2 (ES-E13-1) — the Agents settings-card model ``AgentHooksController``: the install / uninstall /
/// status state machine driven through three injected async seams (the app wires them to the active
/// connection's first-pane ``MetadataClient``; here they are fakes). Each behavior has a test that FAILS on
/// the un-fixed code:
/// - `refresh()` folds the status tri-state — `true`→`.installed`, `false`→`.notInstalled`, `nil`→
///   `.disconnected` (the nil case is what keeps the card off a FALSE "Not Installed");
/// - `install()`/`uninstall()` transition THROUGH `.working` (captured inside the seam) then land on the
///   success state, and RE-PROBE on failure rather than getting stuck `.working`;
/// - `refresh()` is a no-op while a write owns `.working` (a concurrent appear-probe can't clobber it).
@MainActor
final class AgentHooksControllerTests: XCTestCase {
    // MARK: refresh() folds the status tri-state

    func testRefreshTrueGivesInstalled() async {
        let controller = AgentHooksController(refreshStatus: { true })
        await controller.refresh()
        XCTAssertEqual(controller.state, .installed)
        XCTAssertTrue(controller.isInstalled)
    }

    func testRefreshFalseGivesNotInstalled() async {
        let controller = AgentHooksController(refreshStatus: { false })
        await controller.refresh()
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertFalse(controller.isInstalled)
        XCTAssertTrue(controller.actionsEnabled, "a known, connected state ⇒ the buttons are actionable")
    }

    func testRefreshNilGivesDisconnected() async {
        let controller = AgentHooksController(refreshStatus: { nil })
        await controller.refresh()
        XCTAssertEqual(controller.state, .disconnected, "a nil status (no connected pane) ⇒ .disconnected")
        XCTAssertTrue(controller.isDisconnected)
        XCTAssertFalse(controller.actionsEnabled, "the buttons disable while no pane backs the card")
    }

    // MARK: install() / uninstall() success paths

    func testInstallSuccessGivesInstalled() async {
        let controller = AgentHooksController(install: { true }, refreshStatus: { false })
        await controller.refresh()
        XCTAssertEqual(controller.state, .notInstalled)
        await controller.install()
        XCTAssertEqual(controller.state, .installed)
    }

    func testUninstallSuccessGivesNotInstalled() async {
        let controller = AgentHooksController(uninstall: { true }, refreshStatus: { true })
        await controller.refresh()
        XCTAssertEqual(controller.state, .installed)
        await controller.uninstall()
        XCTAssertEqual(controller.state, .notInstalled)
    }

    func testUninstallReversesInstall() async {
        let controller = AgentHooksController(
            install: { true }, uninstall: { true }, refreshStatus: { false },
        )
        await controller.install()
        XCTAssertEqual(controller.state, .installed)
        await controller.uninstall()
        XCTAssertEqual(controller.state, .notInstalled, "uninstall reverses install")
    }

    // MARK: the transient .working state is real (not an instantaneous skip)

    func testInstallTransitionsThroughWorking() async {
        var controller: AgentHooksController!
        var stateInsideSeam: AgentHooksController.InstallState?
        controller = AgentHooksController(
            install: {
                // The seam runs AFTER install() has set `.working` and BEFORE it lands the success state.
                stateInsideSeam = controller.state
                return true
            },
            refreshStatus: { false },
        )
        await controller.install()
        XCTAssertEqual(stateInsideSeam, .working, "install() must enter .working before firing the seam")
        XCTAssertEqual(controller.state, .installed, "and land .installed after a successful seam")
    }

    // MARK: failure paths re-probe (never stuck .working)

    func testFailedInstallReProbesToNotInstalled() async {
        let controller = AgentHooksController(install: { false }, refreshStatus: { false })
        await controller.install()
        XCTAssertEqual(
            controller.state, .notInstalled,
            "a failed install must re-probe (here the host is still not-installed), not stay .working",
        )
    }

    func testFailedInstallReProbesToDisconnectedWhenStatusNil() async {
        let controller = AgentHooksController(install: { false }, refreshStatus: { nil })
        await controller.install()
        XCTAssertEqual(
            controller.state, .disconnected,
            "a failed install whose re-probe finds no pane lands .disconnected, never stuck .working",
        )
    }

    func testFailedUninstallReProbesToInstalled() async {
        let controller = AgentHooksController(uninstall: { false }, refreshStatus: { true })
        await controller.uninstall()
        XCTAssertEqual(
            controller.state, .installed,
            "a failed uninstall must re-probe (the host is still installed), not stay .working",
        )
    }

    // MARK: refresh() must not clobber an in-flight write

    func testRefreshIsNoOpWhileWriteInFlight() async {
        var resume: CheckedContinuation<Bool, Never>?
        let controller = AgentHooksController(
            // The install seam suspends until the test resumes it, holding the controller in `.working`.
            install: { await withCheckedContinuation { resume = $0 } },
            // Would flip the state to `.notInstalled` if refresh() were NOT guarded against `.working`.
            refreshStatus: { false },
        )

        let writing = Task { await controller.install() }
        // Let the install Task progress into the seam's suspension (state is `.working`).
        while resume == nil { await Task.yield() }
        XCTAssertEqual(controller.state, .working)

        await controller.refresh()
        XCTAssertEqual(controller.state, .working, "refresh() is a no-op while a write owns .working")

        resume?.resume(returning: true)
        await writing.value
        XCTAssertEqual(controller.state, .installed, "the resumed write still lands its success state")
    }

    // MARK: derived view flags

    func testDerivedFlagsForWorking() async {
        var resume: CheckedContinuation<Bool, Never>?
        let controller = AgentHooksController(install: { await withCheckedContinuation { resume = $0 } })
        let writing = Task { await controller.install() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(controller.isWorking)
        XCTAssertFalse(controller.actionsEnabled, "buttons disable while a write is in flight")
        resume?.resume(returning: true)
        await writing.value
    }

    func testUnknownIsTreatedAsDisconnectedForDisplay() {
        let controller = AgentHooksController()
        XCTAssertEqual(controller.state, .unknown, "the initial state before the first probe")
        XCTAssertTrue(controller.isDisconnected, "unknown renders like disconnected (the connect note shows)")
        XCTAssertFalse(controller.actionsEnabled)
    }
}
