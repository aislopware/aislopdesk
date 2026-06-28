import AislopdeskCLICore
import XCTest

// Hang-safe tests for the `aislopdesk config path | validate` PURE helpers (otty-clone E20, WI-4). No
// file I/O: the path resolver takes its environment as a parameter, and the validator takes the file
// contents as a string. The malformed-line assertions are genuine behavioral contracts (the validator
// must reject them) — not tautologies against the validator's own output.

final class CLIConfigTests: XCTestCase {
    // MARK: - Path resolution

    func testResolvePathPrefersExplicitOverride() {
        XCTAssertEqual(CLIConfig.resolvePath(override: "/x.toml", environment: [:]), "/x.toml")
    }

    func testResolvePathEmptyOverrideFallsThrough() {
        let env = [CLIConfig.configFileEnvKey: "/from-env.toml"]
        XCTAssertEqual(CLIConfig.resolvePath(override: "", environment: env), "/from-env.toml")
    }

    func testResolvePathUsesEnvWhenNoOverride() {
        let env = [CLIConfig.configFileEnvKey: "/e.toml"]
        XCTAssertEqual(CLIConfig.resolvePath(override: nil, environment: env), "/e.toml")
    }

    func testDefaultPathHonorsXDG() {
        let env = ["XDG_CONFIG_HOME": "/cfg", "HOME": "/Users/me"]
        XCTAssertEqual(CLIConfig.resolvePath(override: nil, environment: env), "/cfg/aislopdesk/config.toml")
    }

    func testDefaultPathFallsBackToHomeDotConfig() {
        let env = ["HOME": "/Users/me"]
        XCTAssertEqual(CLIConfig.defaultPath(environment: env), "/Users/me/.config/aislopdesk/config.toml")
    }

    // MARK: - Validation

    func testValidateAcceptsWellFormedConfig() {
        let contents = """
        # a comment
        ; another comment
        theme = Monokai
        font-size=14

        [ui]
        accent = green
        """
        XCTAssertTrue(CLIConfig.validate(contents).isEmpty)
    }

    func testValidateRejectsLineMissingEquals() {
        let errors = CLIConfig.validate("theme Monokai")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 1)
        XCTAssertTrue(errors.first?.message.contains("missing") ?? false)
    }

    func testValidateRejectsEmptyKey() {
        let errors = CLIConfig.validate("= 14")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 1)
        XCTAssertTrue(errors.first?.message.contains("empty key") ?? false)
    }

    func testValidateReportsEachBadLineNumber() {
        let errors = CLIConfig.validate("ok = 1\nbad line\n= 2")
        XCTAssertEqual(errors.map(\.line), [2, 3])
    }
}
