import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pins broadcast / synchronized input (tmux `synchronize-panes`): the target resolver (multi-selection /
/// focused group / focused-alone, restricted to text-capable kinds), the fan-out that types one string
/// into every target exactly once with the video panes skipped, the arm toggle + apply() routing, and the
/// ⇧⌘B chord. The on-device feel (N libghostty echoes) is HW; the routing/targeting core is all here.
@MainActor
final class BroadcastInputTests: XCTestCase {

    private func store(_ items: [CanvasItem], focus: PaneID) -> WorkspaceStore {
        WorkspaceStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus),
                       makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    private func term(_ x: CGFloat) -> CanvasItem {
        CanvasItem(id: PaneID(), spec: PaneSpec(kind: .terminal, title: "t"),
                   frame: CGRect(x: x, y: 0, width: 300, height: 200), z: 0)
    }

    private func sent(_ store: WorkspaceStore, _ id: PaneID) -> [String] {
        (store.handle(for: id) as? FakePaneSession)?.sentText ?? []
    }

    func testBroadcastTextFansToEverySelectedTerminalExactlyOnce() {
        let a = term(0), b = term(400), c = term(800)
        let st = store([a, b, c], focus: a.id)
        st.setSelection([a.id, b.id])   // ≥2 selected → the selection is the target set
        let n = st.broadcastText("uptime\r")
        XCTAssertEqual(n, 2)
        XCTAssertEqual(sent(st, a.id), ["uptime\r"])
        XCTAssertEqual(sent(st, b.id), ["uptime\r"])
        XCTAssertEqual(sent(st, c.id), [], "an unselected pane receives nothing")
    }

    func testBroadcastSkipsVideoPanesWithNoTextFunnel() {
        let a = term(0)
        let v = CanvasItem(id: PaneID(),
                           spec: PaneSpec(kind: .remoteGUI, title: "v",
                                          video: VideoEndpoint(windowID: 1, title: "v", appName: "")),
                           frame: CGRect(x: 400, y: 0, width: 300, height: 200), z: 1)
        let st = store([a, v], focus: a.id)
        st.setSelection([a.id, v.id])
        let n = st.broadcastText("ls\r")
        XCTAssertEqual(n, 1, "only the text-capable pane is a target")
        XCTAssertEqual(sent(st, a.id), ["ls\r"])
        XCTAssertEqual(sent(st, v.id), [], "a video pane has no text funnel")
    }

    func testTargetsAreTheFocusedPanesWholeGroupWhenNothingSelected() {
        let a = term(0), b = term(400), c = term(800), d = term(1200)
        let st = store([a, b, c, d], focus: a.id)
        let g = st.addGroup(name: "G")
        st.assignPane(a.id, toGroup: g)
        st.assignPane(b.id, toGroup: g)
        st.assignPane(c.id, toGroup: g)
        st.focus(a.id)   // a grouped member is focused, no multi-selection
        XCTAssertEqual(Set(st.broadcastTargets()), Set([a.id, b.id, c.id]),
                       "the focused pane's whole group is the target set")
        XCTAssertFalse(st.broadcastTargets().contains(d.id), "a pane outside the group is excluded")
    }

    func testTargetsFallBackToTheFocusedPaneAloneWhenUngroupedAndUnselected() {
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        XCTAssertEqual(st.broadcastTargets(), [a.id])
    }

    func testToggleBroadcastFlipsAndApplyRoutesIt() {
        let a = term(0)
        let st = store([a], focus: a.id)
        XCTAssertFalse(st.broadcastActive, "disarmed by default (never persisted)")
        st.toggleBroadcast()
        XCTAssertTrue(st.broadcastActive)
        apply(.toggleBroadcast, to: st)   // the menu / keyboard / palette chokepoint
        XCTAssertFalse(st.broadcastActive, "apply(.toggleBroadcast) routes to toggleBroadcast()")
    }

    func testBroadcastChordIsBound() {
        let interp = CommandInterpreter()
        XCTAssertEqual(interp.feed(KeyChord(character: "b", [.command, .shift])), .toggleBroadcast)
    }
}
