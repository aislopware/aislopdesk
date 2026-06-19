import XCTest
@testable import AislopdeskHost

/// W10 — the host env wiring for agent detection: the default idiom of the two flags
/// (`AISLOPDESK_AGENT_DETECT` default-ON, `AISLOPDESK_AGENT_HOOKS` default-OFF) and the
/// `AISLOPDESK_SOCKET_PATH` / `AISLOPDESK_PANE_ID` PTY-env injection.
final class AgentEnvironmentTests: XCTestCase {
    // MARK: AISLOPDESK_AGENT_DETECT — DEFAULT-ON (`!= "0"`)

    func testAgentDetectDefaultsOn() {
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: [:]), "unset → enabled (default-ON)")
        XCTAssertTrue(HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "1"]))
        XCTAssertTrue(
            HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "anything"]),
            "any value other than exactly \"0\" enables",
        )
    }

    func testAgentDetectOnlyZeroDisables() {
        XCTAssertFalse(
            HostEnvironment.agentDetectEnabled(environment: ["AISLOPDESK_AGENT_DETECT": "0"]),
            "only the exact string \"0\" disables",
        )
    }

    // MARK: AISLOPDESK_AGENT_HOOKS — DEFAULT-OFF (`== "1"`)

    func testAgentHooksDefaultsOff() {
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: [:]), "unset → disabled (default-OFF)")
        XCTAssertFalse(HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "0"]))
        XCTAssertFalse(
            HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "yes"]),
            "only the exact string \"1\" enables",
        )
    }

    func testAgentHooksOnlyOneEnables() {
        XCTAssertTrue(HostEnvironment.agentHooksEnabled(environment: ["AISLOPDESK_AGENT_HOOKS": "1"]))
    }

    // MARK: socket / pane env injection

    func testCuratedOmitsAgentVarsByDefault() {
        let env = HostEnvironment.curated(parent: [:])
        XCTAssertNil(env["AISLOPDESK_SOCKET_PATH"], "no socket exported unless the listener is bound")
        XCTAssertNil(env["AISLOPDESK_PANE_ID"])
    }

    func testCuratedExportsSocketAndPaneWhenProvided() {
        let env = HostEnvironment.curated(
            parent: [:],
            agentSocketPath: "/tmp/aislopdesk-agent.sock",
            paneID: "conn:7",
        )
        XCTAssertEqual(env["AISLOPDESK_SOCKET_PATH"], "/tmp/aislopdesk-agent.sock")
        XCTAssertEqual(env["AISLOPDESK_PANE_ID"], "conn:7")
    }

    func testPaneIDIsTheCompositeKey() {
        let conn = UUID()
        let id = HostServer.paneID(connectionID: conn, channelID: 4)
        XCTAssertEqual(id, "\(conn.uuidString):4", "the pane id is the (connectionID, channelID) composite")
    }
}
