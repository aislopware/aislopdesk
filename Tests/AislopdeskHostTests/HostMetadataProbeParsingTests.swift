#if os(macOS)
import AislopdeskProtocol
import XCTest
@testable import AislopdeskHost

/// E9 / WI-1 — the PURE `String → struct` parsers that feed the Details panel's Info-ports + Git data:
/// `parseLsof`, `parseBranchHeader`, `parseStatusLine`, `packStatus`, `statusNibble`. They take NO syscall
/// (no subprocess / PTY / proc query), so the hang-safety rule does NOT apply — they are unit-tested here
/// directly (the surrounding `HostMetadataProbe` I/O paths stay compiled-and-reviewed only).
///
/// Each assertion is written to FAIL on a regressed parser (revert-to-confirm-fail on each guard) and none
/// is tautological: every expected value is an INDEPENDENT literal of the documented porcelain / `lsof -F`
/// convention, never derived from the function under test.
///
/// `#if os(macOS)` — `HostMetadataProbe` is macOS-only (it spawns `git`/`lsof`); the parsers live inside it.
final class HostMetadataProbeParsingTests: XCTestCase {
    // MARK: - parseBranchHeader (porcelain v1 `-b` header, AFTER the `## ` prefix)

    /// `main...origin/main [ahead 2, behind 1]` → branch=main, ahead=2, behind=1.
    func testBranchHeaderAheadBehind() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "main...origin/main [ahead 2, behind 1]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 2)
        XCTAssertEqual(behind, 1)
    }

    /// A bare `main` (no upstream, no bracket) → branch=main, ahead/behind stay at the 0 default.
    func testBranchHeaderBareBranch() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader("main"[...], branch: &branch, ahead: &ahead, behind: &behind)
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 0)
        XCTAssertEqual(behind, 0)
    }

    /// Detached `HEAD (no branch)` → empty branch (the `hasPrefix("HEAD")` collapse), 0/0.
    func testBranchHeaderDetached() {
        var branch = "stale"
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader("HEAD (no branch)"[...], branch: &branch, ahead: &ahead, behind: &behind)
        XCTAssertEqual(branch, "", "a detached HEAD must collapse to an empty branch name")
        XCTAssertEqual(ahead, 0)
        XCTAssertEqual(behind, 0)
    }

    /// `feature...origin/feature [ahead 5]` → only `ahead` is set; `behind` stays 0 (no `behind ` token).
    func testBranchHeaderAheadOnly() {
        var branch = ""
        var ahead: Int32 = 0
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "feature...origin/feature [ahead 5]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "feature")
        XCTAssertEqual(ahead, 5)
        XCTAssertEqual(behind, 0)
    }

    /// A garbage count `[ahead x]` falls back to 0 via the `Int32(...) ?? 0` guard (never a trap).
    func testBranchHeaderGarbageCountFallsBackToZero() {
        var branch = ""
        var ahead: Int32 = 99
        var behind: Int32 = 0
        HostMetadataProbe.parseBranchHeader(
            "main...origin/main [ahead x]"[...], branch: &branch, ahead: &ahead, behind: &behind,
        )
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(ahead, 0, "an unparseable ahead count must fall back to 0, overwriting the sentinel")
        XCTAssertEqual(behind, 0)
    }

    // MARK: - parseStatusLine (porcelain v1 `XY <path>`; rename keeps the NEW path)

    /// `MM f` (staged + worktree modified) → packed `0x11`, path `f`.
    func testStatusLineStagedAndWorktreeModified() {
        let change = HostMetadataProbe.parseStatusLine("MM f"[...])
        XCTAssertEqual(change?.statusCode, 0x11)
        XCTAssertEqual(change?.path, "f")
    }

    /// `?? new.txt` (untracked) → packed `0x77`, path `new.txt`.
    func testStatusLineUntracked() {
        let change = HostMetadataProbe.parseStatusLine("?? new.txt"[...])
        XCTAssertEqual(change?.statusCode, 0x77)
        XCTAssertEqual(change?.path, "new.txt")
    }

    /// `R  old -> new` (rename) → the ` -> ` split keeps the NEW path; X nibble = R (`0x4` high nibble).
    func testStatusLineRenameKeepsNewPath() {
        let change = HostMetadataProbe.parseStatusLine("R  old -> new"[...])
        XCTAssertEqual(change?.path, "new", "a rename row must keep the new path (what the worktree now holds)")
        // R in the index column (X), space in the worktree column (Y) → 0x40.
        XCTAssertEqual(change?.statusCode, 0x40)
        XCTAssertEqual((change?.statusCode ?? 0) >> 4, 0x4, "the renamed category lives in the X (index) nibble")
    }

    /// `A  added` (staged add) → X nibble = A (`0x2` high nibble), path `added`.
    func testStatusLineStagedAdd() {
        let change = HostMetadataProbe.parseStatusLine("A  added"[...])
        XCTAssertEqual(change?.statusCode, 0x20)
        XCTAssertEqual(change?.path, "added")
    }

    /// A too-short line (`" M"`, len < 3) is DROPPED (validate-then-drop, never a trap).
    func testStatusLineTooShortIsDropped() {
        XCTAssertNil(HostMetadataProbe.parseStatusLine(" M"[...]))
    }

    /// An `XY` pair with no path (len == 3 but the path slice is empty) is DROPPED.
    func testStatusLineEmptyPathIsDropped() {
        XCTAssertNil(HostMetadataProbe.parseStatusLine("MM "[...]))
    }

    // MARK: - packStatus / statusNibble (host packing; pinned to the client INVERSE)

    /// The documented porcelain-char → nibble convention (space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9).
    /// These are INDEPENDENT literals of the spec — not read back from `statusNibble`.
    private static let convention: [(char: Character, nibble: UInt8)] = [
        (" ", 0), ("M", 1), ("A", 2), ("D", 3), ("R", 4),
        ("C", 5), ("U", 6), ("?", 7), ("!", 8), ("T", 9),
    ]

    /// A verbatim copy of the CLIENT's `GitStatusPresentation.statusChar` inverse table (nibble → char).
    /// `packStatus`/`statusNibble` and this table must stay mutual inverses or host + client drift.
    private static func clientStatusChar(_ nibble: UInt8) -> Character {
        switch nibble {
        case 0: " "
        case 1: "M"
        case 2: "A"
        case 3: "D"
        case 4: "R"
        case 5: "C"
        case 6: "U"
        case 7: "?"
        case 8: "!"
        case 9: "T"
        default: " "
        }
    }

    /// `statusNibble` maps each convention char to its documented nibble; an unknown char → 15.
    func testStatusNibbleConvention() {
        for (char, nibble) in Self.convention {
            XCTAssertEqual(HostMetadataProbe.statusNibble(char), nibble, "statusNibble(\(char)) should be \(nibble)")
        }
        XCTAssertEqual(HostMetadataProbe.statusNibble("Z"), 15, "an unrecognised char must map to the 15 sentinel")
    }

    /// `packStatus` packs X into the high nibble and Y into the low nibble, against LITERAL expected bytes.
    func testPackStatusExplicitBytes() {
        XCTAssertEqual(HostMetadataProbe.packStatus("M", "M"), 0x11)
        XCTAssertEqual(HostMetadataProbe.packStatus("?", "?"), 0x77)
        XCTAssertEqual(HostMetadataProbe.packStatus("R", " "), 0x40)
        XCTAssertEqual(HostMetadataProbe.packStatus("A", " "), 0x20)
        XCTAssertEqual(HostMetadataProbe.packStatus(" ", "M"), 0x01, "X in the HIGH nibble, Y in the LOW nibble")
        XCTAssertEqual(HostMetadataProbe.packStatus("Z", "Z"), 0xFF, "unknown chars pack as 0xF in each nibble")
    }

    /// The host packing round-trips through the CLIENT inverse: for every (X, Y) over the convention,
    /// `clientStatusChar(packed >> 4) == X` and `clientStatusChar(packed & 0x0F) == Y`. This pins
    /// host + client in lockstep WITHOUT importing the UI module (the table above mirrors
    /// `GitStatusPresentation.xy(_:)`).
    func testPackStatusIsInverseOfClientUnpacking() {
        for (x, _) in Self.convention {
            for (y, _) in Self.convention {
                let packed = HostMetadataProbe.packStatus(x, y)
                XCTAssertEqual(Self.clientStatusChar(packed >> 4), x, "high nibble must unpack to X=\(x)")
                XCTAssertEqual(Self.clientStatusChar(packed & 0x0F), y, "low nibble must unpack to Y=\(y)")
            }
        }
    }

    // MARK: - parseLsof (`-F cn` field output; port after the LAST colon; malformed → drop)

    /// A `c<cmd>` command line then several `n<addr>` lines: each well-formed address yields one port (the
    /// integer after the LAST `:`, so IPv6 `[::1]:443` resolves to 443), malformed lines are SKIPPED, and
    /// the current command name is carried onto every port.
    func testLsofParsesAddressesAndSkipsMalformed() {
        let output = """
        cnode
        n*:8080
        n127.0.0.1:80
        n[::1]:443
        nfoo
        n*:notaport
        """
        let ports = HostMetadataProbe.parseLsof(output, proto: .tcp)
        // Three well-formed addresses; the two malformed lines (`nfoo` no colon, `n*:notaport` non-numeric)
        // are dropped — count == 3 proves the validate-then-drop, not 5.
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(
            ports[0],
            MetadataCodec.PortInfo(port: 8080, proto: MetadataCodec.PortProtocol.tcp.rawValue, procName: "node"),
        )
        XCTAssertEqual(ports[1].port, 80)
        XCTAssertEqual(ports[2].port, 443, "the port is the integer after the LAST colon (IPv6-safe)")
        XCTAssertTrue(ports.allSatisfy { $0.procName == "node" }, "the active `c` command name carries onto every port")
    }

    /// The `proto` argument is carried onto each parsed `PortInfo` (here `.udp` → raw byte 1).
    func testLsofCarriesProtocol() {
        let ports = HostMetadataProbe.parseLsof("cnode\nn*:9000", proto: .udp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].proto, MetadataCodec.PortProtocol.udp.rawValue)
        XCTAssertEqual(ports[0].port, 9000)
    }

    /// A `n<addr>` with no preceding `c<cmd>` still yields a port, with an empty command name (no trap).
    func testLsofAddressWithoutCommandHasEmptyName() {
        let ports = HostMetadataProbe.parseLsof("n*:5000", proto: .tcp)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 5000)
        XCTAssertEqual(ports[0].procName, "")
    }

    // MARK: - opaqueBudgetExceeded (WI-2 — the PURE byte-budget predicate behind the bounded reads)

    /// The source-side opaque-read budget (`readAgentSession` / `gitDiff` drain loop) is bounded at the
    /// builder's 15 MiB opaque cap: exactly `cap` bytes is WITHIN budget (false), `cap + 1` EXCEEDS it
    /// (true) so the drain stops one byte past the cap and `cappedOpaque()` trims an already-bounded tail.
    /// The cap value is the INDEPENDENT ``MetadataResponseBuilder/defaultMaxOpaquePayloadBytes`` source of
    /// truth that the probe's private `maxOpaqueReadBytes` mirrors — so this also pins the two in lockstep
    /// (a drift makes the boundary miss). Pure: no `Process` / `FileHandle` spun (the hang-safety rule).
    func testOpaqueBudgetBoundary() {
        let cap = MetadataResponseBuilder.defaultMaxOpaquePayloadBytes
        XCTAssertFalse(HostMetadataProbe.opaqueBudgetExceeded(0), "an empty capture is within budget")
        XCTAssertFalse(HostMetadataProbe.opaqueBudgetExceeded(cap), "exactly the cap is within budget (no trim)")
        XCTAssertTrue(
            HostMetadataProbe.opaqueBudgetExceeded(cap + 1),
            "cap + 1 exceeds the budget so the drain stops and the builder trims an already-bounded tail",
        )
    }
}
#endif
