import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins layout auto-switch on host app launch: the trigger save, the pure matcher, and the
/// switch-once-per-launch latch (with re-arm when the app leaves) the AppLaunchMonitor drives.
@MainActor
final class AppLaunchSwitchTests: XCTestCase {

    private func twoPaneStore() -> WorkspaceStore {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(id: a, spec: PaneSpec(kind: .terminal, title: "A"),
                       frame: CGRect(x: 0, y: 0, width: 480, height: 320), z: 0),
            CanvasItem(id: b, spec: PaneSpec(kind: .terminal, title: "B"),
                       frame: CGRect(x: 600, y: 0, width: 480, height: 320), z: 1),
        ]
        return WorkspaceStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: a),
                              makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    func testSaveWithTriggerStoresIt() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "monitoring", triggerAppName: "Grafana")
        XCTAssertEqual(store.workspace.layoutPresets.first?.triggerAppName, "Grafana")
        // Empty/whitespace trigger normalises to nil.
        store.saveLayoutPreset(name: "plain", triggerAppName: "   ")
        XCTAssertNil(store.workspace.layoutPresets.first(where: { $0.name == "plain" })?.triggerAppName)
    }

    func testMatcherIsCaseInsensitive() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        XCTAssertEqual(store.presetForLaunchedApp("grafana")?.name, "m")
        XCTAssertNil(store.presetForLaunchedApp("Safari"))
    }

    func testAutoSwitchFiresOncePerLaunchThenReArmsWhenAppLeaves() {
        let store = twoPaneStore()
        // Save "single" = a one-pane layout triggered by Grafana.
        store.closePane(store.workspace.canvas.allIDs().last!)   // one pane now
        store.saveLayoutPreset(name: "single", triggerAppName: "Grafana")
        // Restore a two-pane live canvas so a switch is observable.
        store.addPane(kind: .terminal)
        XCTAssertEqual(store.workspace.canvas.items.count, 2)

        XCTAssertTrue(store.autoSwitchForLaunchedApp("Grafana"), "first launch switches")
        XCTAssertEqual(store.workspace.canvas.items.count, 1, "switched to the 1-pane layout")
        XCTAssertFalse(store.autoSwitchForLaunchedApp("Grafana"), "same launch (still present) doesn't re-switch")

        // Grafana's windows all close → latch re-arms; a relaunch switches again.
        store.clearAutoSwitchLatch(forAbsentApps: ["Grafana"])
        store.addPane(kind: .terminal)   // mutate so a re-switch is observable
        XCTAssertTrue(store.autoSwitchForLaunchedApp("Grafana"), "relaunch after the app left switches again")
    }

    func testNoSwitchWithoutAMatchingTrigger() {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        XCTAssertFalse(store.autoSwitchForLaunchedApp("Safari"))
    }

    func testTriggerSurvivesCodableRoundTrip() throws {
        let store = twoPaneStore()
        store.saveLayoutPreset(name: "m", triggerAppName: "Grafana")
        let data = try JSONEncoder().encode(store.workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.layoutPresets.first?.triggerAppName, "Grafana")
    }
}
